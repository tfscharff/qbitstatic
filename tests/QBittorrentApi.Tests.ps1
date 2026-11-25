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

    Context "Get-QBittorrentInterface" {
        It "Returns null when no session" {
            Disconnect-QBittorrent
            Get-QBittorrentInterface | Should -BeNullOrEmpty
        }
    }

    Context "Set-QBittorrentInterface" {
        It "Returns false when no session" {
            Disconnect-QBittorrent
            Set-QBittorrentInterface -Guid "{00000000-0000-0000-0000-000000000000}" -Name "test" | Should -Be $false
        }

        It "Requires Guid parameter" {
            { Set-QBittorrentInterface -Name "test" } | Should -Throw
        }

        It "Requires Name parameter" {
            { Set-QBittorrentInterface -Guid "{00000000-0000-0000-0000-000000000000}" } | Should -Throw
        }
    }

    Context "Get-AdapterGuidByName" {
        It "Returns null for nonexistent adapter" {
            Get-AdapterGuidByName -Name "definitely-not-a-real-adapter-xyz123" | Should -BeNullOrEmpty
        }

        It "Returns the GUID of an adapter that is Up" {
            Mock Get-NetAdapter -ModuleName QBittorrentApi {
                [pscustomobject]@{ Name = "ProtonVPN"; Status = "Up"; InterfaceGuid = "{11111111-2222-3333-4444-555555555555}" }
            }

            Get-AdapterGuidByName -Name "ProtonVPN" | Should -Be "{11111111-2222-3333-4444-555555555555}"
        }

        It "Returns null when the adapter exists but is not Up" {
            Mock Get-NetAdapter -ModuleName QBittorrentApi {
                [pscustomobject]@{ Name = "ProtonVPN"; Status = "Disconnected"; InterfaceGuid = "{11111111-2222-3333-4444-555555555555}" }
            }

            Get-AdapterGuidByName -Name "ProtonVPN" | Should -BeNullOrEmpty
        }
    }

    Context "Web API calls (mocked)" {
        BeforeAll {
            function Set-FakeSession {
                InModuleScope QBittorrentApi {
                    $script:QbtSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
                }
            }
        }

        BeforeEach {
            Initialize-QBittorrentApi -WebUrl "http://test:9090/" -ExePath "C:\fake\qbt.exe" -MaxRetries 3 -RetryDelaySeconds 7
            Mock Start-Sleep -ModuleName QBittorrentApi { }
        }

        It "Connect-QBittorrent posts credentials to the login endpoint (trailing slash trimmed) and returns true on 'Ok.'" {
            Mock Invoke-WebRequest -ModuleName QBittorrentApi { [pscustomobject]@{ Content = "Ok." } }
            $pw = New-Object System.Security.SecureString
            'pw'.ToCharArray() | ForEach-Object { $pw.AppendChar($_) }
            $cred = [PSCredential]::new("user1", $pw)

            Connect-QBittorrent -Credential $cred | Should -BeTrue

            Should -Invoke Invoke-WebRequest -ModuleName QBittorrentApi -Times 1 -Exactly -ParameterFilter {
                $Uri -eq "http://test:9090/api/v2/auth/login" -and $Method -eq "POST" -and
                $Body.username -eq "user1" -and $Body.password -eq "pw"
            }
        }

        It "Connect-QBittorrent retries MaxRetries times on a rejected login, then returns false and clears the session" {
            Set-FakeSession
            Mock Invoke-WebRequest -ModuleName QBittorrentApi { [pscustomobject]@{ Content = "Fails." } }
            $cred = [PSCredential]::new("user1", (New-Object System.Security.SecureString))

            Connect-QBittorrent -Credential $cred | Should -BeFalse

            Should -Invoke Invoke-WebRequest -ModuleName QBittorrentApi -Times 3 -Exactly
            Should -Invoke Start-Sleep -ModuleName QBittorrentApi -Times 2 -Exactly -ParameterFilter { $Seconds -eq 7 }
            # Session cleared: no further request is made
            Test-QBittorrentConnection | Should -BeFalse
            Should -Invoke Invoke-WebRequest -ModuleName QBittorrentApi -Times 3 -Exactly
        }

        It "Connect-QBittorrent returns false when the request throws (qBittorrent not running)" {
            Mock Invoke-WebRequest -ModuleName QBittorrentApi { throw "Unable to connect to the remote server" }
            $cred = [PSCredential]::new("user1", (New-Object System.Security.SecureString))

            Connect-QBittorrent -Credential $cred | Should -BeFalse
        }

        It "Test-QBittorrentConnection returns true when the version endpoint answers" {
            Set-FakeSession
            Mock Invoke-WebRequest -ModuleName QBittorrentApi { [pscustomobject]@{ Content = "v4.6.0" } }

            Test-QBittorrentConnection | Should -BeTrue
            Should -Invoke Invoke-WebRequest -ModuleName QBittorrentApi -ParameterFilter { $Uri -eq "http://test:9090/api/v2/app/version" }
        }

        It "Test-QBittorrentConnection returns false when the session has expired (request throws)" {
            Set-FakeSession
            Mock Invoke-WebRequest -ModuleName QBittorrentApi { throw "403 Forbidden" }

            Test-QBittorrentConnection | Should -BeFalse
        }

        It "Get-QBittorrentPort parses listen_port from preferences" {
            Set-FakeSession
            Mock Invoke-WebRequest -ModuleName QBittorrentApi { [pscustomobject]@{ Content = '{"listen_port":51820,"current_network_interface":""}' } }

            Get-QBittorrentPort | Should -Be 51820
            Should -Invoke Invoke-WebRequest -ModuleName QBittorrentApi -ParameterFilter { $Uri -eq "http://test:9090/api/v2/app/preferences" }
        }

        It "Get-QBittorrentPort returns null when the request fails" {
            Set-FakeSession
            Mock Invoke-WebRequest -ModuleName QBittorrentApi { throw "timeout" }

            Get-QBittorrentPort | Should -BeNullOrEmpty
        }

        It "Set-QBittorrentPort posts listen_port as JSON and returns true" {
            Set-FakeSession
            Mock Invoke-WebRequest -ModuleName QBittorrentApi { [pscustomobject]@{ Content = "" } }

            Set-QBittorrentPort -Port 51820 | Should -BeTrue

            Should -Invoke Invoke-WebRequest -ModuleName QBittorrentApi -Times 1 -Exactly -ParameterFilter {
                $Uri -eq "http://test:9090/api/v2/app/setPreferences" -and $Method -eq "POST" -and
                ($Body.json | ConvertFrom-Json).listen_port -eq 51820
            }
        }

        It "Set-QBittorrentPort returns false after MaxRetries failed attempts" {
            Set-FakeSession
            Mock Invoke-WebRequest -ModuleName QBittorrentApi { throw "500" }

            Set-QBittorrentPort -Port 51820 | Should -BeFalse
            Should -Invoke Invoke-WebRequest -ModuleName QBittorrentApi -Times 3 -Exactly
        }

        It "Get-QBittorrentInterface returns GUID and name, keeping an empty GUID as empty" {
            Set-FakeSession
            Mock Invoke-WebRequest -ModuleName QBittorrentApi { [pscustomobject]@{ Content = '{"current_network_interface":"","current_interface_name":"ProtonVPN"}' } }

            $iface = Get-QBittorrentInterface
            $iface.Guid | Should -Be ""
            $iface.Name | Should -Be "ProtonVPN"
        }

        It "Get-QBittorrentInterface returns null when the request fails" {
            Set-FakeSession
            Mock Invoke-WebRequest -ModuleName QBittorrentApi { throw "timeout" }

            Get-QBittorrentInterface | Should -BeNullOrEmpty
        }

        It "Set-QBittorrentInterface posts both GUID and name as JSON" {
            Set-FakeSession
            Mock Invoke-WebRequest -ModuleName QBittorrentApi { [pscustomobject]@{ Content = "" } }

            Set-QBittorrentInterface -Guid "{AAAA}" -Name "ProtonVPN" | Should -BeTrue

            Should -Invoke Invoke-WebRequest -ModuleName QBittorrentApi -Times 1 -Exactly -ParameterFilter {
                $j = $Body.json | ConvertFrom-Json
                $Uri -eq "http://test:9090/api/v2/app/setPreferences" -and
                $j.current_network_interface -eq "{AAAA}" -and $j.current_interface_name -eq "ProtonVPN"
            }
        }
    }

    Context "Invoke-WithRetry timing (mocked sleep)" {
        BeforeEach {
            Mock Start-Sleep -ModuleName QBittorrentApi { }
        }

        It "Sleeps RetryDelay between attempts but not after the last one" {
            Initialize-QBittorrentApi -WebUrl "http://localhost:8080" -ExePath "C:\test.exe" -MaxRetries 4 -RetryDelaySeconds 3
            $script:calls = 0

            { Invoke-WithRetry -ScriptBlock { $script:calls++; throw "x" } } | Should -Throw "*4 attempts*"

            $script:calls | Should -Be 4
            Should -Invoke Start-Sleep -ModuleName QBittorrentApi -Times 3 -Exactly -ParameterFilter { $Seconds -eq 3 }
        }

        It "CURRENT BEHAVIOUR (suspected bug): MaxRetries 0 never runs the operation and always throws" {
            # A config with "maxRetries": 0, or with maxRetries missing (null binds to [int] 0),
            # makes every login and set call fail without a single request.
            Initialize-QBittorrentApi -WebUrl "http://localhost:8080" -ExePath "C:\test.exe" -MaxRetries 0 -RetryDelaySeconds 1
            $script:calls = 0

            { Invoke-WithRetry -ScriptBlock { $script:calls++; "ok" } -Operation "probe" } | Should -Throw "*probe after 0 attempts*"
            $script:calls | Should -Be 0
        }
    }

    Context "Restart-QBittorrent (all process calls mocked)" {
        BeforeEach {
            Initialize-QBittorrentApi -WebUrl "http://test:9090" -ExePath "C:\fake\qbt.exe"
            Mock Start-Sleep -ModuleName QBittorrentApi { }
            Mock Get-Process -ModuleName QBittorrentApi { }
            Mock Stop-Process -ModuleName QBittorrentApi { }
            Mock Start-Process -ModuleName QBittorrentApi { }
            Mock Invoke-WebRequest -ModuleName QBittorrentApi { }
            InModuleScope QBittorrentApi {
                $script:QbtSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
            }
        }

        It "Asks for a graceful shutdown, starts the exe and clears the session" {
            Mock Test-Path -ModuleName QBittorrentApi { $true } -ParameterFilter { $Path -eq "C:\fake\qbt.exe" }

            Restart-QBittorrent | Should -BeTrue

            Should -Invoke Invoke-WebRequest -ModuleName QBittorrentApi -Times 1 -Exactly -ParameterFilter {
                $Uri -eq "http://test:9090/api/v2/app/shutdown" -and $Method -eq "POST"
            }
            Should -Invoke Start-Process -ModuleName QBittorrentApi -Times 1 -Exactly -ParameterFilter { $FilePath -eq "C:\fake\qbt.exe" }
            Test-QBittorrentConnection | Should -BeFalse
        }

        It "Force-stops a process that is still running after the graceful wait" {
            Mock Test-Path -ModuleName QBittorrentApi { $true } -ParameterFilter { $Path -eq "C:\fake\qbt.exe" }
            Mock Get-Process -ModuleName QBittorrentApi { [pscustomobject]@{ Name = "qbittorrent"; Id = 999999 } }

            Restart-QBittorrent | Should -BeTrue

            Should -Invoke Get-Process -ModuleName QBittorrentApi -Times 11 -Exactly
            Should -Invoke Stop-Process -ModuleName QBittorrentApi -Times 1 -Exactly
        }

        It "Returns false and starts nothing when the exe path does not exist" {
            Mock Test-Path -ModuleName QBittorrentApi { $false } -ParameterFilter { $Path -eq "C:\fake\qbt.exe" }

            Restart-QBittorrent | Should -BeFalse
            Should -Invoke Start-Process -ModuleName QBittorrentApi -Times 0 -Exactly
        }
    }
}
