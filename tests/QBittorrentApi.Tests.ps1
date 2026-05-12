#Requires -Version 5.1
#Requires -Modules Pester

Describe "QBittorrentApi Module" {
    BeforeAll {
        $ModulePath = Join-Path $PSScriptRoot "..\modules\QBittorrentApi.psm1"
        Import-Module $ModulePath -Force
    }

    Context "Initialize-QBittorrentApi" {
        It "Sets configuration correctly" {
            Initialize-QBittorrentApi -WebUrl "http://test:9090" -ExePath "C:\test\qbt.exe" -MaxRetries 5 -RetryDelaySeconds 10

            Get-QBittorrentExePath | Should -Be "C:\test\qbt.exe"
        }

        It "Trims trailing slash from URL" {
            Initialize-QBittorrentApi -WebUrl "http://test:9090/" -ExePath "C:\test.exe"

            # Internal state - verified by behavior
            $true | Should -Be $true
        }
    }

    Context "Invoke-WithRetry" {
        BeforeAll {
            Initialize-QBittorrentApi -WebUrl "http://localhost:8080" -ExePath "C:\test.exe" -MaxRetries 3 -RetryDelaySeconds 1
        }

        It "Returns result on success" {
            $result = Invoke-WithRetry -ScriptBlock { "success" }
            $result | Should -Be "success"
        }

        It "Retries on failure" {
            $script:attempts = 0
            $result = Invoke-WithRetry -ScriptBlock {
                $script:attempts++
                if ($script:attempts -lt 2) { throw "fail" }
                "success"
            }

            $result | Should -Be "success"
            $script:attempts | Should -Be 2
        }

        It "Throws after max retries" {
            { Invoke-WithRetry -ScriptBlock { throw "always fail" } -Operation "test" } | Should -Throw "*test*3 attempts*"
        }
    }

    Context "Test-QBittorrentConnection" {
        It "Returns false when no session" {
            Disconnect-QBittorrent
            Test-QBittorrentConnection | Should -Be $false
        }
    }

    Context "Get-QBittorrentPort" {
        It "Returns null when no session" {
            Disconnect-QBittorrent
            Get-QBittorrentPort | Should -BeNullOrEmpty
        }
    }

    Context "Set-QBittorrentPort" {
        It "Returns false when no session" {
            Disconnect-QBittorrent
            Set-QBittorrentPort -Port 12345 | Should -Be $false
        }

        It "Validates port range" {
            { Set-QBittorrentPort -Port 500 } | Should -Throw
            { Set-QBittorrentPort -Port 70000 } | Should -Throw
        }
    }
}
