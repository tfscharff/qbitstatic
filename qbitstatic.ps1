#Requires -Version 5.1
<#
.SYNOPSIS
    Syncs ProtonVPN port forwarding port to qBittorrent.
.PARAMETER Install
    Run installation: prompt for credentials, create scheduled task.
#>
param([switch]$Install)

# === CONFIGURATION ===
$QBT_EXE_PATH = "C:\Program Files\qBittorrent\qbittorrent.exe"
$QBT_WEB_URL = "http://localhost:8080"
$POLL_INTERVAL_SECONDS = 30
$CREDENTIAL_TARGET = "qbitstatic-qbittorrent"
$LOG_DIR = "$env:LOCALAPPDATA\qbitstatic"
$LOG_FILE = "$LOG_DIR\qbitstatic.log"
$LOG_MAX_SIZE_MB = 1

# === LOGGING ===
$script:LogCheckCounter = 0

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")

    # Check log size every 100 writes instead of every write
    if (++$script:LogCheckCounter -ge 100) {
        $script:LogCheckCounter = 0
        if ((Test-Path $LOG_FILE) -and ((Get-Item $LOG_FILE).Length / 1MB) -gt $LOG_MAX_SIZE_MB) {
            Remove-Item "$LOG_FILE.old" -Force -ErrorAction SilentlyContinue
            Rename-Item $LOG_FILE "$LOG_FILE.old" -ErrorAction SilentlyContinue
        }
    }
    Add-Content -Path $LOG_FILE -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
}

# === CREDENTIALS ===
$script:CredApiLoaded = $false

function Initialize-CredApi {
    if ($script:CredApiLoaded) { return }
    Add-Type -MemberDefinition @"
[DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern bool CredWrite(ref CREDENTIAL cred, int flags);
[DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern bool CredRead(string target, int type, int reserved, out IntPtr cred);
[DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
public static extern bool CredDelete(string target, int type, int reserved);
[DllImport("advapi32.dll")] public static extern void CredFree(IntPtr cred);
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
public struct CREDENTIAL {
    public int Flags, Type; public string TargetName, Comment;
    public long LastWritten;
    public int CredentialBlobSize; public IntPtr CredentialBlob;
    public int Persist, AttributeCount; public IntPtr Attributes;
    public string TargetAlias, UserName;
}
"@ -Namespace CredManager -Name Api -ErrorAction SilentlyContinue
    $script:CredApiLoaded = $true
}

function Save-QbtCredentials([PSCredential]$Credential) {
    Initialize-CredApi
    $pw = $Credential.GetNetworkCredential().Password
    $pwBytes = [Text.Encoding]::Unicode.GetBytes($pw)
    $blob = [Runtime.InteropServices.Marshal]::AllocHGlobal($pwBytes.Length)
    [Runtime.InteropServices.Marshal]::Copy($pwBytes, 0, $blob, $pwBytes.Length)

    $cred = New-Object CredManager.Api+CREDENTIAL
    $cred.Type = 1  # CRED_TYPE_GENERIC
    $cred.TargetName = $CREDENTIAL_TARGET
    $cred.UserName = $Credential.UserName
    $cred.CredentialBlob = $blob
    $cred.CredentialBlobSize = $pwBytes.Length
    $cred.Persist = 2  # CRED_PERSIST_LOCAL_MACHINE

    try {
        if (-not [CredManager.Api]::CredWrite([ref]$cred, 0)) {
            throw "CredWrite failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
        Write-Log "Credentials saved to Windows Credential Manager"
    } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($blob) }
}

function Get-QbtCredentials {
    Initialize-CredApi
    $ptr = [IntPtr]::Zero
    if (-not [CredManager.Api]::CredRead($CREDENTIAL_TARGET, 1, 0, [ref]$ptr)) { return $null }

    try {
        $c = [Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [Type][CredManager.Api+CREDENTIAL])
        if ($c.CredentialBlobSize -eq 0) { return $null }
        $pw = [Runtime.InteropServices.Marshal]::PtrToStringUni($c.CredentialBlob, $c.CredentialBlobSize/2)
        return [PSCredential]::new($c.UserName, (ConvertTo-SecureString $pw -AsPlainText -Force))
    } finally { [CredManager.Api]::CredFree($ptr) }
}

# === PORT DETECTOR ===
function Get-ProtonVpnPort {
    $logFile = "$env:LOCALAPPDATA\Proton\Proton VPN\Logs\client-logs.txt"
    if (-not (Test-Path $logFile)) { return $null }

    $tmp = "$env:TEMP\protonvpn_log_copy.txt"
    try { Copy-Item $logFile $tmp -Force -ErrorAction Stop } catch { return $null }

    try {
        $text = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
        $m = [regex]::Matches($text, "Port pair (\d+)->")
        if ($m.Count -gt 0) {
            $port = [int]$m[$m.Count-1].Groups[1].Value
            if ($port -ge 1024 -and $port -le 65535) { return $port }
        }
    } catch {} finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    return $null
}

# === QBITTORRENT API ===
$script:QbtSession = $null

function Connect-QBittorrent([PSCredential]$Credential) {
    try {
        $r = Invoke-WebRequest -Uri "$QBT_WEB_URL/api/v2/auth/login" -Method POST -Body @{
            username = $Credential.UserName
            password = $Credential.GetNetworkCredential().Password
        } -SessionVariable s -UseBasicParsing -TimeoutSec 10
        if ($r.Content -eq "Ok.") { $script:QbtSession = $s; return $true }
    } catch {}
    Write-Log "qBittorrent connection failed" -Level ERROR
    return $false
}

function Get-QBittorrentPort {
    if (-not $script:QbtSession) { return $null }
    try {
        $r = Invoke-WebRequest -Uri "$QBT_WEB_URL/api/v2/app/preferences" -WebSession $script:QbtSession -UseBasicParsing -TimeoutSec 10
        return ($r.Content | ConvertFrom-Json).listen_port
    } catch { return $null }
}

function Set-QBittorrentPort([int]$Port) {
    if (-not $script:QbtSession) { return $false }
    try {
        Invoke-WebRequest -Uri "$QBT_WEB_URL/api/v2/app/setPreferences" -Method POST -Body @{
            json = (@{listen_port=$Port} | ConvertTo-Json -Compress)
        } -WebSession $script:QbtSession -UseBasicParsing -TimeoutSec 10 | Out-Null
        Write-Log "Port updated to $Port"
        return $true
    } catch { Write-Log "Failed to set port" -Level ERROR; return $false }
}

function Restart-QBittorrent {
    Write-Log "Restarting qBittorrent..."
    try { Invoke-WebRequest -Uri "$QBT_WEB_URL/api/v2/app/shutdown" -Method POST -WebSession $script:QbtSession -UseBasicParsing -TimeoutSec 5 | Out-Null } catch {}

    # Wait for graceful shutdown, then force kill if still running
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Get-Process -Name qbittorrent -ErrorAction SilentlyContinue)) { break }
    }
    Get-Process -Name qbittorrent -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    if (Test-Path $QBT_EXE_PATH) { Start-Process $QBT_EXE_PATH; Write-Log "qBittorrent restarted" }
}

# === MAIN LOOP ===
function Start-PortMonitor {
    if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null }
    Write-Log "qbitstatic starting..."

    $cred = Get-QbtCredentials
    if (-not $cred) { Write-Log "No credentials. Run with -Install" -Level ERROR; exit 1 }

    $lastPort = $null
    while ($true) {
        try {
            $vpnPort = Get-ProtonVpnPort
            if ($vpnPort -and $vpnPort -ne $lastPort) {
                Write-Log "VPN port: $vpnPort"
                if ((Connect-QBittorrent $cred)) {
                    $qbtPort = Get-QBittorrentPort
                    if ($qbtPort -and $vpnPort -ne $qbtPort) {
                        Write-Log "Updating: VPN=$vpnPort, qBt=$qbtPort"
                        if (Set-QBittorrentPort $vpnPort) { Restart-QBittorrent; Start-Sleep 5 }
                    }
                    $lastPort = $vpnPort
                }
            }
        } catch { Write-Log "Error: $_" -Level ERROR }
        Start-Sleep -Seconds $POLL_INTERVAL_SECONDS
    }
}

# === INSTALLATION ===
function Install-QbitStatic {
    Write-Host "`nqbitstatic Installation`n" -ForegroundColor Cyan

    if (-not (Test-Path $QBT_EXE_PATH)) {
        Write-Host "WARNING: qBittorrent not found at $QBT_EXE_PATH" -ForegroundColor Yellow
    }

    $cred = Get-Credential -Message "qBittorrent Web UI Login"
    if (-not $cred) { Write-Host "Cancelled." -ForegroundColor Red; exit 1 }

    try { Save-QbtCredentials $cred; Write-Host "Credentials saved." -ForegroundColor Green }
    catch { Write-Host "Failed: $_" -ForegroundColor Red; exit 1 }

    $path = $PSCommandPath
    Unregister-ScheduledTask -TaskName qbitstatic -Confirm:$false -ErrorAction SilentlyContinue

    try {
        Register-ScheduledTask -TaskName qbitstatic `
            -Action (New-ScheduledTaskAction -Execute powershell.exe -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$path`"") `
            -Trigger (New-ScheduledTaskTrigger -AtLogon) `
            -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)) `
            -Principal (New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited) | Out-Null
        Write-Host "Scheduled task created." -ForegroundColor Green
    } catch { Write-Host "Task creation failed: $_" -ForegroundColor Red; exit 1 }

    if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null }
    Write-Host "`nDone! Starts at login. Run .\qbitstatic.ps1 to start now.`n" -ForegroundColor Green
}

# === ENTRY POINT ===
if ($Install) { Install-QbitStatic } else { Start-PortMonitor }
