#Requires -Version 5.1
#Requires -Modules Pester

Describe "Logging Module" {
    BeforeAll {
        $ModulePath = Join-Path $PSScriptRoot "..\modules\Logging.psm1"
        Import-Module $ModulePath -Force

        $TestLogDir = Join-Path $env:TEMP "qbitstatic-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $TestLogDir -Force | Out-Null
    }

    AfterAll {
        Remove-Item $TestLogDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context "Initialize-Logging" {
        It "Creates log directory if not exists" {
            $newDir = Join-Path $TestLogDir "subdir"
            Initialize-Logging -LogDir $newDir -LogFile "test.log"

            Test-Path $newDir | Should -Be $true
        }

        It "Sets log path correctly" {
            Initialize-Logging -LogDir $TestLogDir -LogFile "test.log"
            Get-LogPath | Should -Be (Join-Path $TestLogDir "test.log")
        }
    }

    Context "Write-Log" {
        BeforeEach {
            $logFile = "test-$(Get-Random).log"
            Initialize-Logging -LogDir $TestLogDir -LogFile $logFile -MaxSizeMB 1 -CheckInterval 100
        }

        It "Creates log file on first write" {
            Write-Log "Test message"

            Test-Path (Get-LogPath) | Should -Be $true
        }

        It "Writes message with timestamp and level" {
            Write-Log "Test message" -Level INFO

            $content = Get-Content (Get-LogPath) -Raw
            $content | Should -Match "\[\d{4}-\d{2}-\d{2}"
            $content | Should -Match "\[INFO\]"
            $content | Should -Match "Test message"
        }

        It "Supports ERROR level" {
            Write-Log "Error occurred" -Level ERROR

            $content = Get-Content (Get-LogPath) -Raw
            $content | Should -Match "\[ERROR\]"
        }

        It "Supports WARN level" {
            Write-Log "Warning message" -Level WARN

            $content = Get-Content (Get-LogPath) -Raw
            $content | Should -Match "\[WARN\]"
        }

        It "Throws when not initialized" {
            # Force uninitialized state by importing fresh
            Remove-Module Logging -Force -ErrorAction SilentlyContinue
            Import-Module $ModulePath -Force

            { Write-Log "Test" } | Should -Throw "*not initialized*"
        }
    }

    Context "Log rotation" {
        BeforeEach {
            $script:RotDir = Join-Path $TestLogDir "rot-$(Get-Random)"
            New-Item -ItemType Directory -Path $script:RotDir -Force | Out-Null
            $script:RotLog = Join-Path $script:RotDir "rot.log"
            # Just over 1MB of existing log content
            [IO.File]::WriteAllBytes($script:RotLog, (New-Object byte[] (1MB + 10)))
        }

        It "Rotates to .old when the log exceeds the size limit at a check" {
            Initialize-Logging -LogDir $script:RotDir -LogFile "rot.log" -MaxSizeMB 1 -CheckInterval 1

            Write-Log "after rotation"

            Test-Path "$script:RotLog.old" | Should -BeTrue
            (Get-Item "$script:RotLog.old").Length | Should -Be (1MB + 10)
            (Get-Item $script:RotLog).Length | Should -BeLessThan 1KB
            Get-Content $script:RotLog -Raw | Should -Match "after rotation"
        }

        It "Replaces an existing .old file on rotation" {
            "previous old log" | Set-Content "$script:RotLog.old"
            Initialize-Logging -LogDir $script:RotDir -LogFile "rot.log" -MaxSizeMB 1 -CheckInterval 1

            Write-Log "after rotation"

            (Get-Item "$script:RotLog.old").Length | Should -Be (1MB + 10)
        }

        It "Does not rotate when the log is under the size limit" {
            [IO.File]::WriteAllBytes($script:RotLog, (New-Object byte[] 1000))
            Initialize-Logging -LogDir $script:RotDir -LogFile "rot.log" -MaxSizeMB 1 -CheckInterval 1

            Write-Log "no rotation"

            Test-Path "$script:RotLog.old" | Should -BeFalse
            (Get-Item $script:RotLog).Length | Should -BeGreaterThan 1000
        }

        It "Checks the size only every CheckInterval writes" {
            Initialize-Logging -LogDir $script:RotDir -LogFile "rot.log" -MaxSizeMB 1 -CheckInterval 3

            Write-Log "one"
            Write-Log "two"
            Test-Path "$script:RotLog.old" | Should -BeFalse

            Write-Log "three"
            Test-Path "$script:RotLog.old" | Should -BeTrue
            Get-Content $script:RotLog -Raw | Should -Match "three"
            Get-Content $script:RotLog -Raw | Should -Not -Match "one"
        }
    }
}
