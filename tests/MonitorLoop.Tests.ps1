#Requires -Version 5.1
#Requires -Modules Pester

# Tests for the decision logic in qbitstatic.ps1 (Ensure-QBittorrentSession,
# Sync-QBittorrentInterface, Start-PortMonitor).
#
# qbitstatic.ps1 loads config, modules and runs its entry point when executed, so it is
# never run here. Instead the three function definitions are pulled out of the script with
# the PowerShell parser (no code from the script runs) and defined in the test scope. Every
# module function they call is mocked: no qBittorrent API, network, Credential Manager,
# process, scheduler or log-file access happens.
#
# Start-PortMonitor loops forever. Start-Sleep for the poll interval is mocked to throw a
# sentinel, which ends the loop after the chosen number of polls.

Describe "Monitor loop (qbitstatic.ps1)" {
    BeforeAll {
        $modules = Join-Path $PSScriptRoot "..\modules"
        Import-Module (Join-Path $modules "Logging.psm1") -Force
        Import-Module (Join-Path $modules "Credentials.psm1") -Force
        Import-Module (Join-Path $modules "PortDetector.psm1") -Force
        Import-Module (Join-Path $modules "QBittorrentApi.psm1") -Force

        $scriptPath = (Resolve-Path (Join-Path $PSScriptRoot "..\qbitstatic.ps1")).Path
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
        $names = @('Ensure-QBittorrentSession', 'Sync-QBittorrentInterface', 'Start-PortMonitor')
        $defs = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $names -contains $n.Name
            }, $true)
        $defs.Count | Should -Be 3
        foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }

        # The script-level $Config the functions read
        $Config = @{
            PollInterval = 30
            VpnLogPath   = "C:\fake\Proton\client-logs.txt"
            PortPattern  = "Port pair (\d+)->"
        }

        $script:Cred = [PSCredential]::new("user", (New-Object System.Security.SecureString))
    }

    BeforeEach {
        # Safe defaults: connected, no interface binding, VPN and qBittorrent ports in sync.
        Mock Write-Log { }
        Mock Register-EngineEvent { $script:ExitAction = $Action }
        Mock Get-StoredCredential { $script:Cred }
        Mock Test-QBittorrentConnection { $true }
        Mock Connect-QBittorrent { $true }
        Mock Disconnect-QBittorrent { }
        Mock Get-QBittorrentInterface { $null }
        Mock Get-AdapterGuidByName { $null }
        Mock Set-QBittorrentInterface { $true }
        Mock Restart-QBittorrent { $true }
        Mock Get-VpnPort { 50000 }
        Mock Get-DetectionInfo { $null }
        Mock Get-QBittorrentPort { 50000 }
        Mock Set-QBittorrentPort { $true }

        # Poll-interval sleeps end the loop on the Nth one; other sleeps are no-ops.
        $script:PollsBeforeStop = 1
        $script:PollSleeps = 0
        Mock Start-Sleep { }
        Mock Start-Sleep -ParameterFilter { $Seconds -eq 30 } {
            $script:PollSleeps++
            if ($script:PollSleeps -ge $script:PollsBeforeStop) { throw "StopLoop" }
        }
    }

    Context "Ensure-QBittorrentSession" {
        It "Reuses a live session without logging in again" {
            Ensure-QBittorrentSession -Credential $script:Cred | Should -BeTrue
            Should -Invoke Connect-QBittorrent -Times 0 -Exactly
        }

        It "Logs in when the session is not valid and returns the login result" {
            Mock Test-QBittorrentConnection { $false }
            Mock Connect-QBittorrent { $false }

            Ensure-QBittorrentSession -Credential $script:Cred | Should -BeFalse
            Should -Invoke Connect-QBittorrent -Times 1 -Exactly
        }
    }

    Context "Sync-QBittorrentInterface" {
        It "Does nothing when the interface cannot be read" {
            Sync-QBittorrentInterface | Should -BeFalse
            Should -Invoke Get-AdapterGuidByName -Times 0 -Exactly
        }

        It "Does nothing when qBittorrent is not bound to a named interface" {
            Mock Get-QBittorrentInterface { @{ Guid = ""; Name = "" } }

            Sync-QBittorrentInterface | Should -BeFalse
            Should -Invoke Get-AdapterGuidByName -Times 0 -Exactly
        }

        It "Does nothing when the adapter is not Up (VPN disconnected)" {
            Mock Get-QBittorrentInterface { @{ Guid = "{OLD}"; Name = "ProtonVPN" } }
            Mock Get-AdapterGuidByName { $null }

            Sync-QBittorrentInterface | Should -BeFalse
            Should -Invoke Set-QBittorrentInterface -Times 0 -Exactly
        }

        It "Does nothing when the GUIDs match" {
            Mock Get-QBittorrentInterface { @{ Guid = "{SAME}"; Name = "ProtonVPN" } }
            Mock Get-AdapterGuidByName { "{SAME}" }

            Sync-QBittorrentInterface | Should -BeFalse
            Should -Invoke Set-QBittorrentInterface -Times 0 -Exactly
            Should -Invoke Restart-QBittorrent -Times 0 -Exactly
        }

        It "Sets the new GUID, restarts qBittorrent and drops the session on drift" {
            Mock Get-QBittorrentInterface { @{ Guid = "{OLD}"; Name = "ProtonVPN" } }
            Mock Get-AdapterGuidByName { "{NEW}" } -ParameterFilter { $Name -eq "ProtonVPN" }

            Sync-QBittorrentInterface | Should -BeTrue

            Should -Invoke Set-QBittorrentInterface -Times 1 -Exactly -ParameterFilter { $Guid -eq "{NEW}" -and $Name -eq "ProtonVPN" }
            Should -Invoke Restart-QBittorrent -Times 1 -Exactly
            Should -Invoke Disconnect-QBittorrent -Times 1 -Exactly
        }

        It "Logs an error and does not restart when setting the GUID fails" {
            Mock Get-QBittorrentInterface { @{ Guid = "{OLD}"; Name = "ProtonVPN" } }
            Mock Get-AdapterGuidByName { "{NEW}" }
            Mock Set-QBittorrentInterface { $false }

            Sync-QBittorrentInterface | Should -BeFalse

            Should -Invoke Restart-QBittorrent -Times 0 -Exactly
            Should -Invoke Write-Log -ParameterFilter { $Level -eq "ERROR" -and $Message -like "*Failed to update interface GUID*" }
        }
    }

    Context "Start-PortMonitor, one poll" {
        It "Registers a PowerShell.Exiting handler that logs a WARN line" {
            { Start-PortMonitor } | Should -Throw "*StopLoop*"

            Should -Invoke Register-EngineEvent -Times 1 -Exactly -ParameterFilter { $SourceIdentifier -eq "PowerShell.Exiting" }
            & $script:ExitAction
            Should -Invoke Write-Log -ParameterFilter { $Level -eq "WARN" -and $Message -like "*PowerShell.Exiting*" }
        }

        It "Leaves qBittorrent alone and logs a heartbeat when the ports match" {
            { Start-PortMonitor } | Should -Throw "*StopLoop*"

            Should -Invoke Set-QBittorrentPort -Times 0 -Exactly
            Should -Invoke Restart-QBittorrent -Times 0 -Exactly
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like "Heartbeat: VPN port=50000, qBittorrent port=50000*" }
        }

        It "Sets the VPN port, restarts qBittorrent and drops the session on a mismatch" {
            Mock Get-QBittorrentPort { 40000 }

            { Start-PortMonitor } | Should -Throw "*StopLoop*"

            Should -Invoke Set-QBittorrentPort -Times 1 -Exactly -ParameterFilter { $Port -eq 50000 }
            Should -Invoke Restart-QBittorrent -Times 1 -Exactly
            Should -Invoke Disconnect-QBittorrent -Times 1 -Exactly
        }

        It "Logs an error and does not restart when setting the port fails" {
            Mock Get-QBittorrentPort { 40000 }
            Mock Set-QBittorrentPort { $false }

            { Start-PortMonitor } | Should -Throw "*StopLoop*"

            Should -Invoke Restart-QBittorrent -Times 0 -Exactly
            Should -Invoke Write-Log -ParameterFilter { $Level -eq "ERROR" -and $Message -eq "Failed to update port" }
        }

        It "CURRENT BEHAVIOUR (suspected bug): logs an 'in sync' heartbeat when qBittorrent's port could not be read" {
            # Get-QBittorrentPort returns $null when the preferences request fails. The loop
            # then skips the update (correct) but falls through to the heartbeat branch and
            # reports the ports as in sync, with an empty qBittorrent port.
            Mock Get-QBittorrentPort { $null }

            { Start-PortMonitor } | Should -Throw "*StopLoop*"

            Should -Invoke Set-QBittorrentPort -Times 0 -Exactly
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -eq "Heartbeat: VPN port=50000, qBittorrent port= (in sync)" }
        }

        It "Logs an error and touches nothing when qBittorrent cannot be reached" {
            Mock Test-QBittorrentConnection { $false }
            Mock Connect-QBittorrent { $false }

            { Start-PortMonitor } | Should -Throw "*StopLoop*"

            Should -Invoke Get-QBittorrentInterface -Times 0 -Exactly
            Should -Invoke Get-QBittorrentPort -Times 0 -Exactly
            Should -Invoke Set-QBittorrentPort -Times 0 -Exactly
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Level -eq "ERROR" -and $Message -eq "Failed to connect to qBittorrent" }
        }

        It "Skips port sync for that poll after fixing interface drift" {
            Mock Get-QBittorrentInterface { @{ Guid = "{OLD}"; Name = "ProtonVPN" } }
            Mock Get-AdapterGuidByName { "{NEW}" }

            { Start-PortMonitor } | Should -Throw "*StopLoop*"

            Should -Invoke Set-QBittorrentInterface -Times 1 -Exactly
            Should -Invoke Get-VpnPort -Times 0 -Exactly
            Should -Invoke Set-QBittorrentPort -Times 0 -Exactly
        }

        It "Warns that the log file was not found when no port is detected and the log is missing" {
            Mock Get-VpnPort { $null }
            Mock Get-DetectionInfo { @{ Exists = $false } }

            { Start-PortMonitor } | Should -Throw "*StopLoop*"

            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Level -eq "WARN" -and $Message -like "No VPN port: log file not found*C:\fake\Proton\client-logs.txt*" }
            Should -Invoke Get-QBittorrentPort -Times 0 -Exactly
        }

        It "Warns about a possible format change when the log has no matching line" {
            Mock Get-VpnPort { $null }
            Mock Get-DetectionInfo { @{ Exists = $true; HadPortLine = $false; LogPath = "C:\fake\Proton\client-logs.txt"; SizeBytes = 2048; LastWrite = (Get-Date) } }

            { Start-PortMonitor } | Should -Throw "*StopLoop*"

            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Level -eq "WARN" -and $Message -like "*(2KB*has no match for pattern*format may have changed*" }
        }

        It "Warns about an out-of-range value when a port line matched" {
            Mock Get-VpnPort { $null }
            Mock Get-DetectionInfo { @{ Exists = $true; HadPortLine = $true; LogPath = "C:\fake\Proton\client-logs.txt" } }

            { Start-PortMonitor } | Should -Throw "*StopLoop*"

            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Level -eq "WARN" -and $Message -like "*value was out of range*" }
        }

        It "Counts an unexpected error and keeps polling instead of exiting" {
            Mock Get-VpnPort { throw "disk error" }

            { Start-PortMonitor } | Should -Throw "*StopLoop*"

            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Level -eq "ERROR" -and $Message -like "Error: *disk error*" }
            Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter { $Message -like "Too many consecutive errors*" }
        }
    }

    Context "Start-PortMonitor, two polls" {
        BeforeEach {
            $script:PollsBeforeStop = 2
        }

        It "Logs the detected port and the heartbeat only once while nothing changes" {
            { Start-PortMonitor } | Should -Throw "*StopLoop*"

            Should -Invoke Get-VpnPort -Times 2 -Exactly
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -eq "VPN port detected: 50000" }
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like "Heartbeat:*" }
        }

        It "Corrects qBittorrent's port on a later poll even when the VPN port did not change" {
            $script:QbtPorts = @(50000, 40000)
            $script:QbtPortCall = 0
            Mock Get-QBittorrentPort { $script:QbtPorts[$script:QbtPortCall++] }

            { Start-PortMonitor } | Should -Throw "*StopLoop*"

            Should -Invoke Set-QBittorrentPort -Times 1 -Exactly -ParameterFilter { $Port -eq 50000 }
            Should -Invoke Restart-QBittorrent -Times 1 -Exactly
        }

        It "Throttles the no-port warning to one per heartbeat interval" {
            Mock Get-VpnPort { $null }
            Mock Get-DetectionInfo { @{ Exists = $false } }

            { Start-PortMonitor } | Should -Throw "*StopLoop*"

            Should -Invoke Get-VpnPort -Times 2 -Exactly
            Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Level -eq "WARN" -and $Message -like "No VPN port*" }
        }
    }
}
