# qbitstatic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a PowerShell background service that syncs ProtonVPN's port forwarding port to qBittorrent automatically.

**Architecture:** Single PowerShell script polls Windows notifications database for ProtonVPN port, compares to qBittorrent's current port via Web UI API, and updates/restarts qBittorrent when they differ. Credentials stored in Windows Credential Manager.

**Tech Stack:** PowerShell 5.1+, Windows Credential Manager, SQLite (via .NET), qBittorrent Web API

---

## File Structure

```
qbitstatic/
├── README.md           # Update with installation instructions
├── qbitstatic.ps1      # All-in-one: config, logging, install, and run
└── uninstall.ps1       # Removes scheduled task and credentials
```

**qbitstatic.ps1 structure:**
- Configuration section (paths, URLs)
- Logging functions
- Credential functions (store/retrieve)
- Port detector (notifications DB)
- qBittorrent API functions
- Main loop
- Install mode handler

---

### Task 1: Script Skeleton and Configuration

**Files:**
- Create: `qbitstatic.ps1`

- [ ] **Step 1: Create script with configuration section and parameter handling**

```powershell
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
```

- [ ] **Step 2: Run script to verify no syntax errors**

Run: `powershell -ExecutionPolicy Bypass -File .\qbitstatic.ps1`
Expected: No output, no errors (script does nothing yet)

- [ ] **Step 3: Commit**

```bash
git add qbitstatic.ps1
git commit -m "feat: add script skeleton with configuration"
```

---

### Task 2: Logging Functions

**Files:**
- Modify: `qbitstatic.ps1`

- [ ] **Step 1: Add logging functions after configuration section**

```powershell
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
```

- [ ] **Step 2: Add test code at end of script to verify logging works**

```powershell
# Temporary test - remove after verification
Initialize-LogDirectory
Write-Log "Test log entry" -Level INFO
Write-Host "Check log at: $LOG_FILE"
```

- [ ] **Step 3: Run script and verify log file created**

Run: `powershell -ExecutionPolicy Bypass -File .\qbitstatic.ps1`
Expected: Output shows log path, file exists with test entry

- [ ] **Step 4: Remove test code from end of script**

Remove the temporary test lines added in Step 2.

- [ ] **Step 5: Commit**

```bash
git add qbitstatic.ps1
git commit -m "feat: add logging functions with rotation"
```

---

### Task 3: Credential Management

**Files:**
- Modify: `qbitstatic.ps1`

- [ ] **Step 1: Add credential functions after logging section**

```powershell
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
```

- [ ] **Step 2: Commit**

```bash
git add qbitstatic.ps1
git commit -m "feat: add credential management via Windows Credential Manager"
```

---

### Task 4: Port Detector (ProtonVPN Notifications)

**Files:**
- Modify: `qbitstatic.ps1`

- [ ] **Step 1: Add port detector function after credential section**

```powershell
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
        Remove-Item $TempDb -Force -ErrorAction SilentlyContinue
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add qbitstatic.ps1
git commit -m "feat: add ProtonVPN port detector via notifications database"
```

---

### Task 5: qBittorrent API Client

**Files:**
- Modify: `qbitstatic.ps1`

- [ ] **Step 1: Add qBittorrent API functions after port detector section**

```powershell
# ============================================================================
# QBITTORRENT API
# ============================================================================

$script:QbtSession = $null

function Connect-QBittorrent {
    param(
        [Parameter(Mandatory)]
        [PSCredential]$Credential
    )

    $loginUrl = "$QBT_WEB_URL/api/v2/auth/login"
    $username = $Credential.UserName
    $password = $Credential.GetNetworkCredential().Password

    try {
        $body = @{
            username = $username
            password = $password
        }

        $response = Invoke-WebRequest -Uri $loginUrl -Method POST -Body $body -SessionVariable session -UseBasicParsing -TimeoutSec 10

        if ($response.Content -eq "Ok.") {
            $script:QbtSession = $session
            return $true
        } else {
            Write-Log "qBittorrent login failed: $($response.Content)" -Level ERROR
            return $false
        }
    } catch {
        Write-Log "qBittorrent connection failed: $_" -Level ERROR
        return $false
    }
}

function Get-QBittorrentPort {
    if (-not $script:QbtSession) {
        Write-Log "Not connected to qBittorrent" -Level ERROR
        return $null
    }

    $prefsUrl = "$QBT_WEB_URL/api/v2/app/preferences"

    try {
        $response = Invoke-WebRequest -Uri $prefsUrl -Method GET -WebSession $script:QbtSession -UseBasicParsing -TimeoutSec 10
        $prefs = $response.Content | ConvertFrom-Json
        return $prefs.listen_port
    } catch {
        Write-Log "Failed to get qBittorrent port: $_" -Level ERROR
        return $null
    }
}

function Set-QBittorrentPort {
    param(
        [Parameter(Mandatory)]
        [int]$Port
    )

    if (-not $script:QbtSession) {
        Write-Log "Not connected to qBittorrent" -Level ERROR
        return $false
    }

    $prefsUrl = "$QBT_WEB_URL/api/v2/app/setPreferences"

    try {
        $prefs = @{ listen_port = $Port } | ConvertTo-Json -Compress
        $body = @{ json = $prefs }

        $response = Invoke-WebRequest -Uri $prefsUrl -Method POST -Body $body -WebSession $script:QbtSession -UseBasicParsing -TimeoutSec 10

        Write-Log "qBittorrent port updated to $Port" -Level INFO
        return $true
    } catch {
        Write-Log "Failed to set qBittorrent port: $_" -Level ERROR
        return $false
    }
}

function Stop-QBittorrent {
    if (-not $script:QbtSession) {
        Write-Log "Not connected to qBittorrent" -Level ERROR
        return $false
    }

    $shutdownUrl = "$QBT_WEB_URL/api/v2/app/shutdown"

    try {
        Invoke-WebRequest -Uri $shutdownUrl -Method POST -WebSession $script:QbtSession -UseBasicParsing -TimeoutSec 10 | Out-Null
        Write-Log "qBittorrent shutdown requested" -Level INFO
        return $true
    } catch {
        Write-Log "Failed to shutdown qBittorrent: $_" -Level WARN
        return $false
    }
}

function Start-QBittorrent {
    if (-not (Test-Path $QBT_EXE_PATH)) {
        Write-Log "qBittorrent executable not found at: $QBT_EXE_PATH" -Level ERROR
        return $false
    }

    try {
        Start-Process -FilePath $QBT_EXE_PATH
        Write-Log "qBittorrent started" -Level INFO
        return $true
    } catch {
        Write-Log "Failed to start qBittorrent: $_" -Level ERROR
        return $false
    }
}

function Restart-QBittorrent {
    Write-Log "Restarting qBittorrent..." -Level INFO

    # Try graceful shutdown via API
    $stopped = Stop-QBittorrent

    if (-not $stopped) {
        # Force kill if API shutdown failed
        Write-Log "Forcing qBittorrent shutdown..." -Level WARN
        Get-Process -Name "qbittorrent" -ErrorAction SilentlyContinue | Stop-Process -Force
    }

    # Wait for process to exit
    Start-Sleep -Seconds 2

    # Start qBittorrent
    return Start-QBittorrent
}
```

- [ ] **Step 2: Commit**

```bash
git add qbitstatic.ps1
git commit -m "feat: add qBittorrent API client functions"
```

---

### Task 6: Main Monitoring Loop

**Files:**
- Modify: `qbitstatic.ps1`

- [ ] **Step 1: Add main loop function after qBittorrent API section**

```powershell
# ============================================================================
# MAIN LOOP
# ============================================================================

function Start-PortMonitor {
    Initialize-LogDirectory
    Write-Log "qbitstatic starting..." -Level INFO

    # Get stored credentials
    $credential = Get-QbtCredentials
    if (-not $credential) {
        Write-Log "No credentials found. Run with -Install to configure." -Level ERROR
        exit 1
    }

    $lastPort = $null

    while ($true) {
        try {
            # Get ProtonVPN port
            $vpnPort = Get-ProtonVpnPort

            if (-not $vpnPort) {
                # No port found, wait and retry
                Start-Sleep -Seconds $POLL_INTERVAL_SECONDS
                continue
            }

            # Check if port changed
            if ($vpnPort -eq $lastPort) {
                Start-Sleep -Seconds $POLL_INTERVAL_SECONDS
                continue
            }

            Write-Log "ProtonVPN port detected: $vpnPort" -Level INFO

            # Connect to qBittorrent
            $connected = Connect-QBittorrent -Credential $credential
            if (-not $connected) {
                Write-Log "qBittorrent not available, will retry" -Level WARN
                Start-Sleep -Seconds $POLL_INTERVAL_SECONDS
                continue
            }

            # Get current qBittorrent port
            $qbtPort = Get-QBittorrentPort
            if (-not $qbtPort) {
                Start-Sleep -Seconds $POLL_INTERVAL_SECONDS
                continue
            }

            # Update if different
            if ($vpnPort -ne $qbtPort) {
                Write-Log "Port mismatch: VPN=$vpnPort, qBittorrent=$qbtPort. Updating..." -Level INFO

                $updated = Set-QBittorrentPort -Port $vpnPort
                if ($updated) {
                    Restart-QBittorrent
                    $lastPort = $vpnPort

                    # Wait extra time for qBittorrent to restart
                    Start-Sleep -Seconds 5
                }
            } else {
                $lastPort = $vpnPort
            }

        } catch {
            Write-Log "Error in monitoring loop: $_" -Level ERROR
        }

        Start-Sleep -Seconds $POLL_INTERVAL_SECONDS
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add qbitstatic.ps1
git commit -m "feat: add main monitoring loop"
```

---

### Task 7: Install Mode

**Files:**
- Modify: `qbitstatic.ps1`

- [ ] **Step 1: Add install function after main loop section**

```powershell
# ============================================================================
# INSTALLATION
# ============================================================================

function Install-QbitStatic {
    Write-Host "qbitstatic Installation" -ForegroundColor Cyan
    Write-Host "========================" -ForegroundColor Cyan
    Write-Host ""

    # Check if qBittorrent exists
    if (-not (Test-Path $QBT_EXE_PATH)) {
        Write-Host "WARNING: qBittorrent not found at: $QBT_EXE_PATH" -ForegroundColor Yellow
        Write-Host "Edit the QBT_EXE_PATH variable in this script if installed elsewhere." -ForegroundColor Yellow
        Write-Host ""
    }

    # Prompt for credentials
    Write-Host "Enter your qBittorrent Web UI credentials:" -ForegroundColor White
    $credential = Get-Credential -Message "qBittorrent Web UI Login"

    if (-not $credential) {
        Write-Host "Installation cancelled." -ForegroundColor Red
        exit 1
    }

    # Save credentials
    try {
        Save-QbtCredentials -Credential $credential
        Write-Host "Credentials saved to Windows Credential Manager." -ForegroundColor Green
    } catch {
        Write-Host "Failed to save credentials: $_" -ForegroundColor Red
        exit 1
    }

    # Create scheduled task
    $scriptPath = $MyInvocation.PSCommandPath
    if (-not $scriptPath) {
        $scriptPath = $PSCommandPath
    }

    $taskName = "qbitstatic"
    $taskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
    $taskTrigger = New-ScheduledTaskTrigger -AtLogon
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

    # Remove existing task if present
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    # Create new task
    try {
        Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $taskTrigger -Settings $taskSettings -Principal $taskPrincipal | Out-Null
        Write-Host "Scheduled task created: $taskName" -ForegroundColor Green
    } catch {
        Write-Host "Failed to create scheduled task: $_" -ForegroundColor Red
        exit 1
    }

    # Initialize log directory
    Initialize-LogDirectory

    Write-Host ""
    Write-Host "Installation complete!" -ForegroundColor Green
    Write-Host ""
    Write-Host "The service will start automatically at next login." -ForegroundColor White
    Write-Host "To start now, run: .\qbitstatic.ps1" -ForegroundColor White
    Write-Host "To uninstall, run: .\uninstall.ps1" -ForegroundColor White
    Write-Host ""
    Write-Host "Log file: $LOG_FILE" -ForegroundColor Gray
}
```

- [ ] **Step 2: Add entry point at end of script**

```powershell
# ============================================================================
# ENTRY POINT
# ============================================================================

if ($Install) {
    Install-QbitStatic
} else {
    Start-PortMonitor
}
```

- [ ] **Step 3: Commit**

```bash
git add qbitstatic.ps1
git commit -m "feat: add install mode with credential prompt and scheduled task"
```

---

### Task 8: Uninstall Script

**Files:**
- Create: `uninstall.ps1`

- [ ] **Step 1: Create uninstall script**

```powershell
#Requires -Version 5.1

<#
.SYNOPSIS
    Uninstalls qbitstatic.
.DESCRIPTION
    Removes the scheduled task and stored credentials.
#>

$CREDENTIAL_TARGET = "qbitstatic-qbittorrent"
$TASK_NAME = "qbitstatic"

Write-Host "qbitstatic Uninstall" -ForegroundColor Cyan
Write-Host "====================" -ForegroundColor Cyan
Write-Host ""

# Remove scheduled task
try {
    $task = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false
        Write-Host "Scheduled task removed." -ForegroundColor Green
    } else {
        Write-Host "Scheduled task not found (already removed)." -ForegroundColor Yellow
    }
} catch {
    Write-Host "Failed to remove scheduled task: $_" -ForegroundColor Red
}

# Remove stored credentials
try {
    $result = cmdkey /delete:$CREDENTIAL_TARGET 2>&1
    if ($result -match "deleted") {
        Write-Host "Credentials removed from Windows Credential Manager." -ForegroundColor Green
    } else {
        Write-Host "Credentials not found (already removed)." -ForegroundColor Yellow
    }
} catch {
    Write-Host "Failed to remove credentials: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "Uninstall complete." -ForegroundColor Green
Write-Host ""
Write-Host "Note: Log files at %LOCALAPPDATA%\qbitstatic\ were not removed." -ForegroundColor Gray
Write-Host "Delete them manually if desired." -ForegroundColor Gray
```

- [ ] **Step 2: Run uninstall script to verify no syntax errors**

Run: `powershell -ExecutionPolicy Bypass -File .\uninstall.ps1`
Expected: Shows "not found" messages (nothing installed yet), completes without errors

- [ ] **Step 3: Commit**

```bash
git add uninstall.ps1
git commit -m "feat: add uninstall script"
```

---

### Task 9: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README with installation instructions**

```markdown
# qbitstatic

Automatically sync ProtonVPN's port forwarding port to qBittorrent.

When ProtonVPN's forwarded port changes, qbitstatic detects it and updates qBittorrent's listening port, then restarts qBittorrent to apply the change.

## Prerequisites

- Windows 10/11
- ProtonVPN Windows app with port forwarding enabled
- qBittorrent installed

## Setup

1. **Enable qBittorrent Web UI**
   - Open qBittorrent
   - Go to Tools → Options → Web UI
   - Check "Enable the Web User Interface"
   - Set a username and password
   - Click OK

2. **Clone this repository**
   ```powershell
   git clone https://github.com/tfscharff/qbitstatic.git
   cd qbitstatic
   ```

3. **Run the installer**
   ```powershell
   .\qbitstatic.ps1 -Install
   ```
   - Enter your qBittorrent Web UI username and password when prompted
   - Credentials are stored securely in Windows Credential Manager

4. **Done!** The service starts automatically when you log in.

## Usage

- **Start manually:** `.\qbitstatic.ps1`
- **View logs:** `%LOCALAPPDATA%\qbitstatic\qbitstatic.log`
- **Uninstall:** `.\uninstall.ps1`

## Configuration

Edit the variables at the top of `qbitstatic.ps1` if needed:

| Variable | Default | Description |
|----------|---------|-------------|
| `$QBT_EXE_PATH` | `C:\Program Files\qBittorrent\qbittorrent.exe` | Path to qBittorrent |
| `$QBT_WEB_URL` | `http://localhost:8080` | qBittorrent Web UI address |
| `$POLL_INTERVAL_SECONDS` | `30` | How often to check for port changes |

## How It Works

1. Reads ProtonVPN's forwarded port from Windows notifications
2. Compares it to qBittorrent's current listening port via Web API
3. If different, updates qBittorrent's port and restarts it

## License

MIT
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README with installation instructions"
```

---

### Task 10: Final Integration Test

**Files:**
- None (manual testing)

- [ ] **Step 1: Run syntax check on all scripts**

Run: `powershell -ExecutionPolicy Bypass -Command "& { $null = [scriptblock]::Create((Get-Content .\qbitstatic.ps1 -Raw)) }"`
Expected: No output (no syntax errors)

Run: `powershell -ExecutionPolicy Bypass -Command "& { $null = [scriptblock]::Create((Get-Content .\uninstall.ps1 -Raw)) }"`
Expected: No output (no syntax errors)

- [ ] **Step 2: Push all changes to GitHub**

```bash
git push
```

- [ ] **Step 3: Document completion**

The implementation is complete. User can now:
1. Enable qBittorrent Web UI
2. Run `.\qbitstatic.ps1 -Install`
3. Service runs automatically on login
