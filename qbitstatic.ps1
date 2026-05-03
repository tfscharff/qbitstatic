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

# ============================================================================
# CREDENTIAL MANAGEMENT
# ============================================================================

function Save-QbtCredentials {
    param(
        [Parameter(Mandatory)]
        [PSCredential]$Credential
    )

    # Remove existing credential if present
    try {
        cmdkey /delete:$CREDENTIAL_TARGET 2>$null | Out-Null
    } catch {}

    # Store new credential
    $username = $Credential.UserName
    $password = $Credential.GetNetworkCredential().Password

    $result = cmdkey /add:$CREDENTIAL_TARGET /user:$username /pass:$password
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to save credentials to Windows Credential Manager"
    }

    Write-Log "Credentials saved to Windows Credential Manager" -Level INFO
}

function Get-QbtCredentials {
    # Query credential manager
    $cmdkeyOutput = cmdkey /list:$CREDENTIAL_TARGET 2>&1

    if ($cmdkeyOutput -match "not found") {
        return $null
    }

    # Parse the stored credential using VaultCmd approach
    # Unfortunately cmdkey doesn't return passwords, so we use .NET
    Add-Type -AssemblyName System.Runtime.WindowsRuntime

    # Use CredRead API via P/Invoke
    $signature = @"
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredRead(string target, int type, int reserved, out IntPtr credential);

    [DllImport("advapi32.dll")]
    public static extern void CredFree(IntPtr credential);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public int Flags;
        public int Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }
"@

    try {
        Add-Type -MemberDefinition $signature -Namespace "CredManager" -Name "Api" -ErrorAction Stop
    } catch {
        # Type already added
    }

    $credPtr = [IntPtr]::Zero
    $success = [CredManager.Api]::CredRead($CREDENTIAL_TARGET, 1, 0, [ref]$credPtr)

    if (-not $success) {
        return $null
    }

    try {
        $cred = [System.Runtime.InteropServices.Marshal]::PtrToStructure($credPtr, [Type][CredManager.Api+CREDENTIAL])
        $password = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($cred.CredentialBlob, $cred.CredentialBlobSize / 2)
        $username = $cred.UserName

        $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
        return New-Object PSCredential($username, $securePassword)
    } finally {
        [CredManager.Api]::CredFree($credPtr)
    }
}

function Remove-QbtCredentials {
    cmdkey /delete:$CREDENTIAL_TARGET 2>$null | Out-Null
    Write-Log "Credentials removed from Windows Credential Manager" -Level INFO
}

# ============================================================================
# PORT DETECTOR
# ============================================================================

function Get-ProtonVpnPort {
    $notificationsDb = "$env:LOCALAPPDATA\Microsoft\Windows\Notifications\wpndatabase.db"

    if (-not (Test-Path $notificationsDb)) {
        Write-Log "Notifications database not found" -Level WARN
        return $null
    }

    # Copy database to temp to avoid file locks
    $tempDb = "$env:TEMP\wpndatabase_copy.db"
    try {
        Copy-Item $notificationsDb $tempDb -Force -ErrorAction Stop
    } catch {
        Write-Log "Failed to copy notifications database: $_" -Level WARN
        return $null
    }

    try {
        # Load SQLite assembly
        Add-Type -Path "$env:windir\Microsoft.NET\Framework64\v4.0.30319\System.Data.dll" -ErrorAction SilentlyContinue

        $connectionString = "Data Source=$tempDb;Version=3;Read Only=True;"
        $connection = New-Object System.Data.SQLite.SQLiteConnection -ErrorAction Stop
    } catch {
        # Fall back to OleDb approach for SQLite
        try {
            $connectionString = "Provider=Microsoft.ACE.OLEDB.12.0;Data Source=$tempDb;"
            $connection = New-Object System.Data.OleDb.OleDbConnection($connectionString)
        } catch {
            # Use raw query via sqlite3 if available, otherwise parse with regex
            return Get-ProtonVpnPortFallback -TempDb $tempDb
        }
    }

    return Get-ProtonVpnPortFallback -TempDb $tempDb
}

function Get-ProtonVpnPortFallback {
    param([string]$TempDb)

    # Read database file as text and search for port pattern
    # ProtonVPN notifications contain "Active port number: XXXXX"
    try {
        $content = [System.IO.File]::ReadAllText($TempDb, [System.Text.Encoding]::UTF8)

        # Find all matches of the port pattern
        $pattern = "Active port number[:\s]+(\d{4,5})"
        $matches = [regex]::Matches($content, $pattern)

        if ($matches.Count -eq 0) {
            # Also try alternate patterns
            $pattern2 = "port\s*(?:number)?[:\s]+(\d{4,5})"
            $matches = [regex]::Matches($content, $pattern2, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }

        if ($matches.Count -gt 0) {
            # Return the last (most recent) port found
            $port = [int]$matches[$matches.Count - 1].Groups[1].Value
            if ($port -ge 1024 -and $port -le 65535) {
                return $port
            }
        }

        return $null
    } catch {
        Write-Log "Failed to parse notifications database: $_" -Level WARN
        return $null
    } finally {
        # Clean up temp file
        Remove-Item $tempDb -Force -ErrorAction SilentlyContinue
    }
}
