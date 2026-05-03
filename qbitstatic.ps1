#Requires -Version 5.1

<#
.SYNOPSIS
    Syncs ProtonVPN port forwarding port to qBittorrent.
.DESCRIPTION
    Monitors ProtonVPN's forwarded port and updates qBittorrent's listening port automatically.
.PARAMETER Install
    Run installation: prompt for credentials, create scheduled task.
#>

param(
    [switch]$Install
)

# ============================================================================
# CONFIGURATION - Edit these values to match your setup
# ============================================================================

$QBT_EXE_PATH = "C:\Program Files\qBittorrent\qbittorrent.exe"
$QBT_WEB_URL = "http://localhost:8080"
$POLL_INTERVAL_SECONDS = 30
$CREDENTIAL_TARGET = "qbitstatic-qbittorrent"
$LOG_DIR = "$env:LOCALAPPDATA\qbitstatic"
$LOG_FILE = "$LOG_DIR\qbitstatic.log"
$LOG_MAX_SIZE_MB = 1

# ============================================================================
# END CONFIGURATION
# ============================================================================

# ============================================================================
# LOGGING
# ============================================================================

function Initialize-LogDirectory {
    if (-not (Test-Path $LOG_DIR)) {
        New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    # Rotate log if too large
    if (Test-Path $LOG_FILE) {
        $logSize = (Get-Item $LOG_FILE).Length / 1MB
        if ($logSize -gt $LOG_MAX_SIZE_MB) {
            $backupPath = "$LOG_FILE.old"
            if (Test-Path $backupPath) {
                Remove-Item $backupPath -Force
            }
            Rename-Item $LOG_FILE $backupPath
        }
    }

    Add-Content -Path $LOG_FILE -Value $logEntry
}
