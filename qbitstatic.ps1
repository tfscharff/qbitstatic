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
