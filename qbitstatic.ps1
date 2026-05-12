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

function Start-PortMonitor {
    Write-Log "qbitstatic v2.0 starting..."

    $cred = Get-StoredCredential
    if (-not $cred) {
        Write-Log "No credentials found. Run with -Install" -Level ERROR
        exit 1
    }

    $lastPort = $null
    $consecutiveErrors = 0
    $maxConsecutiveErrors = 10

    while ($true) {
        try {
            $vpnPort = Get-VpnPort
            if ($vpnPort -and $vpnPort -ne $lastPort) {
                Write-Log "VPN port detected: $vpnPort"

                # Reconnect if session invalid
                if (-not (Test-QBittorrentConnection)) {
                    Write-Log "Connecting to qBittorrent..."
                    if (-not (Connect-QBittorrent -Credential $cred)) {
                        Write-Log "Failed to connect to qBittorrent" -Level ERROR
                        $consecutiveErrors++
                        if ($consecutiveErrors -ge $maxConsecutiveErrors) {
                            Write-Log "Too many consecutive errors, exiting" -Level ERROR
                            exit 1
                        }
                        Start-Sleep -Seconds $Config.PollInterval
                        continue
                    }
                }

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

                $lastPort = $vpnPort
                $consecutiveErrors = 0
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

    $cred = Get-Credential -Message "qBittorrent Web UI Login"
    if (-not $cred) {
        Write-Host "Cancelled." -ForegroundColor Red
        exit 1
    }

    try {
        Save-Credential -Credential $cred
        Write-Host "Credentials saved to Windows Credential Manager." -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to save credentials: $_" -ForegroundColor Red
        exit 1
    }

    $scriptPath = $MyInvocation.PSCommandPath
    Unregister-ScheduledTask -TaskName qbitstatic -Confirm:$false -ErrorAction SilentlyContinue

    try {
        Register-ScheduledTask -TaskName qbitstatic `
            -Action (New-ScheduledTaskAction -Execute powershell.exe -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`"") `
            -Trigger (New-ScheduledTaskTrigger -AtLogon) `
            -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)) `
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
