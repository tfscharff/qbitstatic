# qbitstatic Design Spec

Automatically sync ProtonVPN's port forwarding port to qBittorrent.

## Problem

ProtonVPN's port forwarding assigns dynamic ports that can change. qBittorrent needs to use the correct port for optimal torrent connectivity. Manually updating the port is tedious and easy to forget.

## Solution

A PowerShell background service that:
1. Monitors ProtonVPN's current port via Windows notifications database
2. Detects when the port changes
3. Updates qBittorrent's listening port via Web UI API
4. Restarts qBittorrent to apply the change

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     qbitstatic Service                       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐   │
│  │    Port      │    │    Port      │    │  qBittorrent │   │
│  │  Detector    │───▶│  Comparator  │───▶│   Updater    │   │
│  └──────────────┘    └──────────────┘    └──────────────┘   │
│         │                                        │           │
│         ▼                                        ▼           │
│  ┌──────────────┐                       ┌──────────────┐    │
│  │   Windows    │                       │  qBittorrent │    │
│  │ Notifications│                       │   Web API    │    │
│  │   Database   │                       │              │    │
│  └──────────────┘                       └──────────────┘    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Components

### Port Detector

Reads ProtonVPN's forwarded port from the Windows Notifications database.

**Source:** `%LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db`

**Method:**
1. Copy database to temp location (avoids file locks)
2. Query SQLite for ProtonVPN notifications containing "Active port number:"
3. Extract port number via regex
4. Return most recent port found

**Edge cases:**
- No port notification found: log warning, skip cycle
- Database locked: retry after short delay
- ProtonVPN not running: continue polling silently

### qBittorrent Updater

Updates qBittorrent's listening port via Web UI API and restarts the application.

**API Endpoints:**
| Action | Endpoint | Method |
|--------|----------|--------|
| Login | `/api/v2/auth/login` | POST |
| Get current port | `/api/v2/app/preferences` | GET |
| Set new port | `/api/v2/app/setPreferences` | POST |
| Shutdown app | `/api/v2/app/shutdown` | POST |

**Update flow:**
1. Authenticate with Web UI (get session cookie)
2. Fetch current listening port from preferences
3. If port differs from ProtonVPN port:
   - Update port via `setPreferences`
   - Shutdown qBittorrent via API
   - Wait 2 seconds
   - Restart qBittorrent process

### Background Service

Runs as a Windows scheduled task triggered at user logon.

**Main loop:**
```
while ($true) {
    1. Get ProtonVPN port from notifications
    2. Get qBittorrent current port via API
    3. If different → update port, restart qBittorrent
    4. Sleep 30 seconds
}
```

**Polling interval:** 30 seconds (hardcoded, reasonable default)

## Configuration

**Non-sensitive (in script):**
- qBittorrent executable path (default: `C:\Program Files\qBittorrent\qbittorrent.exe`)
- Web UI address (default: `http://localhost:8080`)

**Sensitive (Windows Credential Manager):**
- qBittorrent Web UI username
- qBittorrent Web UI password
- Stored under target name: `qbitstatic-qbittorrent`

Credentials are stored securely and retrieved at runtime. No sensitive data in code.

## File Structure

```
qbitstatic/
├── README.md
├── qbitstatic.ps1      # All-in-one: config, install, and run
└── uninstall.ps1       # Removes scheduled task
```

## Installation

**Prerequisites:**
- ProtonVPN Windows app with port forwarding enabled
- qBittorrent installed

**Setup (5 steps):**
1. Enable qBittorrent Web UI (Tools → Options → Web UI → Enable)
2. Set Web UI username and password in qBittorrent
3. Clone/download the repo
4. Run `.\qbitstatic.ps1 -Install` (prompts for credentials)
5. Done - runs automatically on login

**Uninstall:**
- Run `.\uninstall.ps1`

## Script Flags

| Flag | Action |
|------|--------|
| `-Install` | Prompt for credentials, store in Credential Manager, create scheduled task |
| (none) | Run the monitoring loop (used by scheduled task) |

## Logging

**Location:** `%LOCALAPPDATA%\qbitstatic\qbitstatic.log`

**Events logged:**
- Port changes detected
- qBittorrent updates and restarts
- Errors (API failures, database access issues)

**Rotation:** Auto-rotate when file exceeds 1MB

## Error Handling

| Scenario | Behavior |
|----------|----------|
| ProtonVPN not running | Silent continue, keep polling |
| qBittorrent not running | Log warning, skip cycle |
| Web UI unreachable | Log error, retry next cycle |
| Port update fails | Log error, retry next cycle |
| Script crashes | Task scheduler auto-restarts |

## Security

- No credentials stored in code or plain text files
- Windows Credential Manager for secure credential storage
- Repo is safe to commit to GitHub
- Web UI should only listen on localhost (default)

## Dependencies

- PowerShell 5.1+ (included in Windows 10/11)
- .NET Framework (for SQLite access, included in Windows)
- No external tools required
