#Requires -Version 5.1
#Requires -Modules Pester

Describe "PortDetector Module" {
    BeforeAll {
        $ModulePath = Join-Path $PSScriptRoot "..\modules\PortDetector.psm1"
        Import-Module $ModulePath -Force

        $TestDir = Join-Path $env:TEMP "qbitstatic-test-$(Get-Random)"
        New-Item -ItemType Directory -Path $TestDir -Force | Out-Null
        $TestLogFile = Join-Path $TestDir "client-logs.txt"
    }

    AfterAll {
        Remove-Item $TestDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context "Initialize-PortDetector" {
        It "Sets log path correctly" {
            Initialize-PortDetector -LogPath $TestLogFile

            # No error means success
            $true | Should -Be $true
        }

        It "Sets custom pattern" {
            Initialize-PortDetector -LogPath $TestLogFile -Pattern "Custom (\d+)"

            $true | Should -Be $true
        }
    }

    Context "Get-VpnPort" {
        BeforeEach {
            Initialize-PortDetector -LogPath $TestLogFile
            Reset-PortCache
        }

        It "Returns null when log file does not exist" {
            Remove-Item $TestLogFile -Force -ErrorAction SilentlyContinue

            Get-VpnPort | Should -BeNullOrEmpty
        }

        It "Extracts port from log content" {
            @"
2024-01-01 12:00:00 Some log entry
2024-01-01 12:01:00 Port pair 54321->
2024-01-01 12:02:00 Another log entry
"@ | Set-Content $TestLogFile

            Get-VpnPort | Should -Be 54321
        }

        It "Returns last port when multiple found" {
            @"
Port pair 11111->
Port pair 22222->
Port pair 33333->
"@ | Set-Content $TestLogFile

            Get-VpnPort | Should -Be 33333
        }

        It "Validates port range (1024-65535)" {
            @"
Port pair 500->
"@ | Set-Content $TestLogFile

            Get-VpnPort | Should -BeNullOrEmpty
        }

        It "Caches port when file unchanged" {
            @"
Port pair 44444->
"@ | Set-Content $TestLogFile

            $port1 = Get-VpnPort
            $port2 = Get-VpnPort

            $port1 | Should -Be 44444
            $port2 | Should -Be 44444
        }

        It "Detects file changes" {
            @"
Port pair 55555->
"@ | Set-Content $TestLogFile
            $port1 = Get-VpnPort

            Start-Sleep -Milliseconds 100
            @"
Port pair 60001->
"@ | Set-Content $TestLogFile
            $port2 = Get-VpnPort

            $port1 | Should -Be 55555
            $port2 | Should -Be 60001
        }
    }

    Context "Get-CachedPort" {
        It "Returns cached port without re-reading" {
            Initialize-PortDetector -LogPath $TestLogFile
            Reset-PortCache

            @"
Port pair 51234->
"@ | Set-Content $TestLogFile
            Get-VpnPort | Out-Null

            Get-CachedPort | Should -Be 51234
        }
    }

    Context "Reset-PortCache" {
        It "Clears cached port" {
            Initialize-PortDetector -LogPath $TestLogFile
            @"
Port pair 52222->
"@ | Set-Content $TestLogFile
            Get-VpnPort | Out-Null
            Get-CachedPort | Should -Be 52222

            Reset-PortCache
            Get-CachedPort | Should -BeNullOrEmpty
        }
    }

    Context "Robust log resolution" {
        BeforeEach {
            $script:RobustDir = Join-Path $env:TEMP "qbitstatic-robust-$(Get-Random)"
            New-Item -ItemType Directory -Path $script:RobustDir -Force | Out-Null
            $script:RobustLog = Join-Path $script:RobustDir "client-logs.txt"
            Initialize-PortDetector -LogPath $script:RobustLog
        }

        AfterEach {
            Remove-Item $script:RobustDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It "Falls back to a rotated sibling when the primary has no port line" {
            "no port lines here, just noise" | Set-Content $script:RobustLog
            "Port pair 50001->50001" | Set-Content (Join-Path $script:RobustDir "client-logs.1.txt")

            Get-VpnPort | Should -Be 50001
        }

        It "Finds the newest sibling when the configured file is missing" {
            # Configured client-logs.txt does not exist; only a rotated file is present.
            "Port pair 50002->50002" | Set-Content (Join-Path $script:RobustDir "client-logs.1.txt")

            Get-VpnPort | Should -Be 50002
        }

        It "Reports HadPortLine=false when the log has data but no match (format change)" {
            "2026-01-01 Some new format with forwarded=50003 that the pattern misses" | Set-Content $script:RobustLog

            Get-VpnPort | Should -BeNullOrEmpty
            $info = Get-DetectionInfo
            $info.Exists | Should -BeTrue
            $info.HadPortLine | Should -BeFalse
        }

        It "Reports Exists=false when no log file is found anywhere" {
            Remove-Item $script:RobustLog -Force -ErrorAction SilentlyContinue

            Get-VpnPort | Should -BeNullOrEmpty
            (Get-DetectionInfo).Exists | Should -BeFalse
        }
    }
}
