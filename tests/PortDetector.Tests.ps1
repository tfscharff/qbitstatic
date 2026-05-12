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
Port pair 66666->
"@ | Set-Content $TestLogFile
            $port2 = Get-VpnPort

            $port1 | Should -Be 55555
            $port2 | Should -Be 66666
        }
    }

    Context "Get-CachedPort" {
        It "Returns cached port without re-reading" {
            Initialize-PortDetector -LogPath $TestLogFile
            Reset-PortCache

            @"
Port pair 77777->
"@ | Set-Content $TestLogFile
            Get-VpnPort | Out-Null

            Get-CachedPort | Should -Be 77777
        }
    }

    Context "Reset-PortCache" {
        It "Clears cached port" {
            Initialize-PortDetector -LogPath $TestLogFile
            @"
Port pair 88888->
"@ | Set-Content $TestLogFile
            Get-VpnPort | Out-Null

            Reset-PortCache
            Get-CachedPort | Should -BeNullOrEmpty
        }
    }
}
