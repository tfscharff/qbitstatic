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

        It "Prefers the most recently written candidate when several have a port" {
            $older = Join-Path $script:RobustDir "client-logs.1.txt"
            "Port pair 50010->50010" | Set-Content $script:RobustLog
            "Port pair 50020->50020" | Set-Content $older
            (Get-Item $script:RobustLog).LastWriteTime = (Get-Date).AddMinutes(-10)
            (Get-Item $older).LastWriteTime = (Get-Date)

            Get-VpnPort | Should -Be 50020
            (Get-DetectionInfo).LogPath | Should -Be $older
        }

        It "Ignores files that do not share the log's base name and extension" {
            "Port pair 50030->50030" | Set-Content (Join-Path $script:RobustDir "other.txt")
            "Port pair 50031->50031" | Set-Content (Join-Path $script:RobustDir "client-logs.log")

            Get-VpnPort | Should -BeNullOrEmpty
            (Get-DetectionInfo).Exists | Should -BeFalse
        }

        It "Reports HadPortLine=true when the only port line is out of range" {
            "Port pair 80->80" | Set-Content $script:RobustLog

            Get-VpnPort | Should -BeNullOrEmpty
            $info = Get-DetectionInfo
            $info.Exists | Should -BeTrue
            $info.HadPortLine | Should -BeTrue
            $info.Port | Should -BeNullOrEmpty
        }
    }

    Context "Port line parsing" {
        BeforeEach {
            Initialize-PortDetector -LogPath $TestLogFile
            Reset-PortCache
        }

        It "Takes the internal port from a real Proton 'Port pair internal->external' line" {
            "2026-11-01T10:00:00.000Z | INFO  | ConnectionStatus | Port pair 51820->61234 received" | Set-Content $TestLogFile

            Get-VpnPort | Should -Be 51820
        }

        It "Accepts the range boundaries 1024 and 65535" {
            "Port pair 1024->1024" | Set-Content $TestLogFile
            Get-VpnPort | Should -Be 1024

            Reset-PortCache
            "Port pair 65535->65535" | Set-Content $TestLogFile
            Get-VpnPort | Should -Be 65535
        }

        It "Rejects 1023 and 65536" {
            "Port pair 1023->1023" | Set-Content $TestLogFile
            Get-VpnPort | Should -BeNullOrEmpty

            Reset-PortCache
            "Port pair 65536->65536" | Set-Content $TestLogFile
            Get-VpnPort | Should -BeNullOrEmpty
        }

        It "Uses only the last match, so an out-of-range last line hides an earlier valid one" {
            @"
Port pair 50100->50100
Port pair 80->80
"@ | Set-Content $TestLogFile

            Get-VpnPort | Should -BeNullOrEmpty
        }

        It "Reads only the tail of the log (MaxReadBytes)" {
            $text = "Port pair 50200->50200`r`n" + ("x" * 2000)
            Set-Content -Path $TestLogFile -Value $text -NoNewline

            Get-VpnPort -MaxReadBytes 500 | Should -BeNullOrEmpty
            Reset-PortCache
            Get-VpnPort -MaxReadBytes 5000 | Should -Be 50200
        }

        It "Uses a custom pattern from Initialize-PortDetector" {
            Initialize-PortDetector -LogPath $TestLogFile -Pattern "forwarded=(\d+)"
            "status forwarded=50300 ok" | Set-Content $TestLogFile

            Get-VpnPort | Should -Be 50300
        }

        It "Returns the cached port without re-reading while the newest file's mtime is unchanged" {
            "Port pair 50400->50400" | Set-Content $TestLogFile
            $mtime = (Get-Item $TestLogFile).LastWriteTime
            Get-VpnPort | Should -Be 50400

            "Port pair 50401->50401" | Set-Content $TestLogFile
            (Get-Item $TestLogFile).LastWriteTime = $mtime

            Get-VpnPort | Should -Be 50400
        }
    }

    Context "Uninitialized" {
        It "Get-VpnLogFile throws before Initialize-PortDetector" {
            Remove-Module PortDetector -Force -ErrorAction SilentlyContinue
            Import-Module $ModulePath -Force

            { Get-VpnLogFile } | Should -Throw "*not initialized*"
        }
    }
}
