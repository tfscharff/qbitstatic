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
}
