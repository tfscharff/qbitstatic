#Requires -Version 5.1
<#
.SYNOPSIS
    Syncs ProtonVPN port forwarding port to qBittorrent.
.PARAMETER Install
    Run installation: prompt for credentials, create scheduled task.
.PARAMETER Uninstall
    Remove scheduled task and credentials.
.PARAMETER Status
    Show current status (VPN port, qBittorrent port, connection state).
#>
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Import modules
Import-Module "$ScriptDir\modules\Config.psm1" -Force
Import-Module "$ScriptDir\modules\Logging.psm1" -Force
Import-Module "$ScriptDir\modules\Credentials.psm1" -Force
Import-Module "$ScriptDir\modules\PortDetector.psm1" -Force
Import-Module "$ScriptDir\modules\QBittorrentApi.psm1" -Force

# Load configuration
$Config = Get-QbitstaticConfig -Path "$ScriptDir\config.json"

# Initialize modules
Initialize-Logging -LogDir $Config.LogDir -LogFile $Config.LogFile -MaxSizeMB $Config.LogMaxSizeMB -CheckInterval $Config.LogCheckInterval
Initialize-CredentialApi -Target $Config.CredentialTarget
Initialize-PortDetector -LogPath $Config.VpnLogPath -Pattern $Config.PortPattern
Initialize-QBittorrentApi -WebUrl $Config.QbtWebUrl -ExePath $Config.QbtExePath -MaxRetries $Config.MaxRetries -RetryDelaySeconds $Config.RetryDelay

# === MAIN FUNCTIONS ===

function Ensure-QBittorrentSession {
    param([Parameter(Mandatory)][PSCredential]$Credential)

    if (Test-QBittorrentConnection) { return $true }
    Write-Log "Connecting to qBittorrent..."
    return Connect-QBittorrent -Credential $Credential
}

function Sync-QBittorrentInterface {
    <#
    .SYNOPSIS
        Reconcile qBittorrent's bound interface GUID with the current Windows adapter GUID
        for the same friendly name. Returns $true if a restart was performed.
    #>
    $iface = Get-QBittorrentInterface
    if (-not $iface -or -not $iface.Name) { return $false }

    $currentGuid = Get-AdapterGuidByName -Name $iface.Name
    if (-not $currentGuid) {
        # Adapter not present (e.g., VPN disconnected). Skip silently.
        return $false
    }

    if ($iface.Guid -eq $currentGuid) { return $false }

    Write-Log "Interface GUID drift for '$($iface.Name)': qBittorrent=$($iface.Guid), Windows=$currentGuid. Updating..."
    if (Set-QBittorrentInterface -Guid $currentGuid -Name $iface.Name) {
        Write-Log "Interface GUID updated. Restarting qBittorrent..."
        Restart-QBittorrent
        Disconnect-QBittorrent
        Start-Sleep -Seconds 5
        return $true
    }

    Write-Log "Failed to update interface GUID" -Level ERROR
    return $false
}

function Start-PortMonitor {
    Write-Log "qbitstatic v2.0 starting..."

    # Diagnostic: the process has been observed to die unexpectedly (Task Scheduler
    # LastTaskResult 0xC000013A / STATUS_CONTROL_C_EXIT - the exit code Windows uses
    # when a console process is force-terminated, e.g. on logoff/shutdown/console-close
    # or Ctrl+C) without any error being logged. Log if the engine sees this happen,
    # so a future occurrence shows the reason instead of the log just stopping.
    Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        Write-Log "Process exiting via PowerShell.Exiting event (console close/logoff/shutdown/Ctrl+C)" -Level WARN
    } | Out-Null

    $cred = Get-StoredCredential
    if (-not $cred) {
        Write-Log "No credentials found. Run with -Install" -Level ERROR
        exit 1
    }

    $lastPort = $null
    $consecutiveErrors = 0
    $maxConsecutiveErrors = 10
    $lastHeartbeat = [DateTime]::MinValue
    $heartbeatInterval = [TimeSpan]::FromMinutes(10)

    while ($true) {
        try {
            # Interface drift check (runs every poll; restart-and-continue if drift fixed)
            if (Ensure-QBittorrentSession -Credential $cred) {
                if (Sync-QBittorrentInterface) {
                    $consecutiveErrors = 0
                    Start-Sleep -Seconds $Config.PollInterval
                    continue
                }
            }

            $vpnPort = Get-VpnPort
            $heartbeatDue = (((Get-Date) - $lastHeartbeat) -ge $heartbeatInterval)

            if (-not $vpnPort) {
                # No port detected. Proton may not be forwarding yet, or an update changed
                # the log format/location. Log loudly (throttled) so the cause is visible
                # instead of qBittorrent silently sitting on a stale port.
                if ($heartbeatDue) {
                    $d = Get-DetectionInfo
                    if ($null -eq $d -or -not $d.Exists) {
                        Write-Log "No VPN port: log file not found (expected '$($Config.VpnLogPath)'). Proton may have moved its logs." -Level WARN
                    }
                    elseif (-not $d.HadPortLine) {
                        $kb = [math]::Round($d.SizeBytes / 1KB, 1)
                        Write-Log "No VPN port: log '$($d.LogPath)' (${kb}KB, modified $($d.LastWrite)) has no match for pattern '$($Config.PortPattern)'. Proton log format may have changed." -Level WARN
                    }
                    else {
                        Write-Log "No VPN port: a port line matched in '$($d.LogPath)' but the value was out of range." -Level WARN
                    }
                    $lastHeartbeat = Get-Date
                }
            }
            elseif (Ensure-QBittorrentSession -Credential $cred) {
                if ($vpnPort -ne $lastPort) {
                    Write-Log "VPN port detected: $vpnPort"
                    $lastPort = $vpnPort
                }

                # State-based reconcile: always compare the detected port to qBittorrent's
                # actual port, so a missed transition self-corrects on a later poll rather
                # than relying on an in-memory edge that an app update could cause us to miss.
                $qbtPort = Get-QBittorrentPort
                if ($qbtPort -and $vpnPort -ne $qbtPort) {
                    Write-Log "Port mismatch: VPN=$vpnPort, qBittorrent=$qbtPort. Updating..."
                    if (Set-QBittorrentPort -Port $vpnPort) {
                        Write-Log "Port updated successfully"
                        Restart-QBittorrent
                        Write-Log "qBittorrent restarted"
                        Disconnect-QBittorrent
                        Start-Sleep -Seconds 5
                    }
                    else {
                        Write-Log "Failed to update port" -Level ERROR
                    }
                }
                elseif ($heartbeatDue) {
                    Write-Log "Heartbeat: VPN port=$vpnPort, qBittorrent port=$qbtPort (in sync)"
                    $lastHeartbeat = Get-Date
                }

                $consecutiveErrors = 0
            }
            else {
                Write-Log "Failed to connect to qBittorrent" -Level ERROR
                $consecutiveErrors++
                if ($consecutiveErrors -ge $maxConsecutiveErrors) {
                    Write-Log "Too many consecutive errors, exiting" -Level ERROR
                    exit 1
                }
            }
        }
        catch {
            Write-Log "Error: $_" -Level ERROR
            $consecutiveErrors++
            if ($consecutiveErrors -ge $maxConsecutiveErrors) {
                Write-Log "Too many consecutive errors, exiting" -Level ERROR
                exit 1
            }
        }

        Start-Sleep -Seconds $Config.PollInterval
    }
}

function Install-QbitStatic {
    Write-Host "`nqbitstatic Installation`n" -ForegroundColor Cyan

    if (-not (Test-Path $Config.QbtExePath)) {
        Write-Host "WARNING: qBittorrent not found at $($Config.QbtExePath)" -ForegroundColor Yellow
        Write-Host "Update config.json with correct path if needed.`n" -ForegroundColor Yellow
    }

    # Avoid Get-Credential: it lives in Microsoft.PowerShell.Security, which fails to
    # autoload under PowerShell 5.1 on this machine (see Credentials.psm1 for details).
    Write-Host "qBittorrent Web UI Login" -ForegroundColor Cyan
    $username = Read-Host "Username"
    if (-not $username) {
        Write-Host "Cancelled." -ForegroundColor Red
        exit 1
    }
    $securePassword = Read-Host "Password" -AsSecureString
    $cred = [PSCredential]::new($username, $securePassword)

    try {
        Save-Credential -Credential $cred | Out-Null
        Write-Host "Credentials saved to Windows Credential Manager." -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to save credentials: $_" -ForegroundColor Red
        exit 1
    }

    $vbsPath = Join-Path $ScriptDir "run-hidden.vbs"
    if (-not (Test-Path $vbsPath)) {
        Write-Host "ERROR: launcher not found at $vbsPath" -ForegroundColor Red
        exit 1
    }
    Unregister-ScheduledTask -TaskName qbitstatic -Confirm:$false -ErrorAction SilentlyContinue

    # Two triggers keep the monitor "always on":
    #
    #  - AtLogon (delayed 1 min): starts the monitor after you sign in. The 1-minute
    #    delay avoids a cold-boot race where a task started at the instant of logon is
    #    killed within seconds (exit 0xC000013A) while the session/shell is still being
    #    set up.
    #
    #  - Watchdog (Once + 2-minute repetition, effectively indefinite): the monitor
    #    process has been observed to be force-terminated mid-session (exit 0xC000013A /
    #    STATUS_CONTROL_C_EXIT) with nothing logged, and Task Scheduler's RestartOnFailure
    #    does NOT reliably restart it afterward. This trigger re-launches the monitor
    #    within ~2 minutes whenever it isn't running. MultipleInstances=IgnoreNew makes
    #    it a no-op while the monitor is already up.
    #
    # The action runs wscript.exe on run-hidden.vbs rather than powershell.exe directly:
    # launching "powershell.exe -WindowStyle Hidden" from Task Scheduler flashes a conhost
    # window every time the watchdog fires (even with IgnoreNew - confirmed in practice).
    # wscript.exe has no console of its own and starts PowerShell with window style 0, so
    # the watchdog never flashes. See run-hidden.vbs.
    #
    # RestartCount/-RestartInterval below are kept as a harmless backup layer; the
    # watchdog trigger is the mechanism actually relied on. The PowerShell.Exiting handler
    # in Start-PortMonitor logs the cause if the engine ever sees a clean exit signal.
    $logonTrigger = New-ScheduledTaskTrigger -AtLogon
    $logonTrigger.Delay = "PT1M"
    $watchdogTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 2) `
        -RepetitionDuration (New-TimeSpan -Days 3650)

    try {
        Register-ScheduledTask -TaskName qbitstatic `
            -Action (New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbsPath`"") `
            -Trigger @($logonTrigger, $watchdogTrigger) `
            -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew) `
            -Principal (New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited) | Out-Null
        Write-Host "Scheduled task created." -ForegroundColor Green
    }
    catch {
        Write-Host "Task creation failed: $_" -ForegroundColor Red
        exit 1
    }

    if (-not (Test-Path $Config.LogDir)) {
        New-Item -ItemType Directory -Path $Config.LogDir -Force | Out-Null
    }

    Write-Host "`nInstallation complete!" -ForegroundColor Green
    Write-Host "- Starts automatically at login" -ForegroundColor Gray
    Write-Host "- Run .\qbitstatic.ps1 to start now" -ForegroundColor Gray
    Write-Host "- Run .\qbitstatic.ps1 -Status to check status" -ForegroundColor Gray
    Write-Host "- Edit config.json to change settings`n" -ForegroundColor Gray
}

function Uninstall-QbitStatic {
    Write-Host "`nqbitstatic Uninstallation`n" -ForegroundColor Cyan

    # Remove scheduled task
    $task = Get-ScheduledTask -TaskName qbitstatic -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName qbitstatic -Confirm:$false
        Write-Host "Scheduled task removed." -ForegroundColor Green
    }
    else {
        Write-Host "Scheduled task not found (already removed)." -ForegroundColor Yellow
    }

    # Remove credentials
    if (Remove-StoredCredential) {
        Write-Host "Credentials removed." -ForegroundColor Green
    }
    else {
        Write-Host "Credentials not found (already removed)." -ForegroundColor Yellow
    }

    Write-Host "`nUninstallation complete!" -ForegroundColor Green
    Write-Host "- Logs retained at: $($Config.LogDir)" -ForegroundColor Gray
    Write-Host "- Config retained at: $ScriptDir\config.json`n" -ForegroundColor Gray
}

function Show-Status {
    Write-Host "`nqbitstatic Status`n" -ForegroundColor Cyan

    # VPN Port
    $vpnPort = Get-VpnPort
    if ($vpnPort) {
        Write-Host "VPN Port:        $vpnPort" -ForegroundColor Green
    }
    else {
        Write-Host "VPN Port:        Not detected" -ForegroundColor Yellow
    }

    # Credentials
    $cred = Get-StoredCredential
    if ($cred) {
        Write-Host "Credentials:     Stored (user: $($cred.UserName))" -ForegroundColor Green
    }
    else {
        Write-Host "Credentials:     Not found" -ForegroundColor Red
    }

    # qBittorrent connection
    if ($cred -and (Connect-QBittorrent -Credential $cred)) {
        Write-Host "qBittorrent:     Connected" -ForegroundColor Green
        $qbtPort = Get-QBittorrentPort
        if ($qbtPort) {
            if ($vpnPort -and $qbtPort -eq $vpnPort) {
                Write-Host "Listening Port:  $qbtPort (synced)" -ForegroundColor Green
            }
            elseif ($vpnPort) {
                Write-Host "Listening Port:  $qbtPort (needs sync to $vpnPort)" -ForegroundColor Yellow
            }
            else {
                Write-Host "Listening Port:  $qbtPort" -ForegroundColor Cyan
            }
        }

        $iface = Get-QBittorrentInterface
        if ($iface -and $iface.Name) {
            $currentGuid = Get-AdapterGuidByName -Name $iface.Name
            if (-not $currentGuid) {
                Write-Host "Interface:       $($iface.Name) (adapter not Up)" -ForegroundColor Yellow
            }
            elseif ($iface.Guid -eq $currentGuid) {
                Write-Host "Interface:       $($iface.Name) (synced)" -ForegroundColor Green
            }
            else {
                Write-Host "Interface:       $($iface.Name) (GUID drift: qBt=$($iface.Guid) Win=$currentGuid)" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "Interface:       not bound" -ForegroundColor Gray
        }

        Disconnect-QBittorrent
    }
    else {
        Write-Host "qBittorrent:     Not connected" -ForegroundColor Red
    }

    # Scheduled task
    $task = Get-ScheduledTask -TaskName qbitstatic -ErrorAction SilentlyContinue
    if ($task) {
        Write-Host "Scheduled Task:  $($task.State)" -ForegroundColor Green
    }
    else {
        Write-Host "Scheduled Task:  Not installed" -ForegroundColor Yellow
    }

    # Log file
    $logPath = Get-LogPath
    if (Test-Path $logPath) {
        $logSize = [math]::Round((Get-Item $logPath).Length / 1KB, 1)
        Write-Host "Log File:        $logPath (${logSize}KB)" -ForegroundColor Gray
    }
    else {
        Write-Host "Log File:        Not created yet" -ForegroundColor Gray
    }

    Write-Host ""
}

# === ENTRY POINT ===
if ($Install) {
    Install-QbitStatic
}
elseif ($Uninstall) {
    Uninstall-QbitStatic
}
elseif ($Status) {
    Show-Status
}
else {
    Start-PortMonitor
}
