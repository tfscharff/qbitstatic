# qbitstatic

Automatically sync ProtonVPN's port forwarding port **and network interface GUID** to qBittorrent on Windows. The interface sync fixes the "configured network interface is invalid" error that occurs when ProtonVPN's WireGuard adapter is reassigned a new GUID on reconnect.

## Requirements

- Windows 10/11
- ProtonVPN (Proton VPN Windows client) with port forwarding enabled — the `Port pair <internal>-><external>` log format is unchanged across client updates, so no reconfiguration is needed when Proton VPN updates
- qBittorrent with Web UI enabled

## Setup

1. **Enable qBittorrent Web UI**: Tools > Options > Web UI > Enable, set username/password

2. **Install**:
   ```powershell
   git clone https://github.com/tfscharff/qbitstatic.git
   cd qbitstatic
   .\qbitstatic.ps1 -Install
   ```

3. **Done** - runs automatically at login

## Usage

| Command | Description |
|---------|-------------|
| `.\qbitstatic.ps1` | Start monitoring manually |
| `.\qbitstatic.ps1 -Install` | Install (prompt for credentials, create task) |
| `.\qbitstatic.ps1 -Status` | Show current status |
| `.\qbitstatic.ps1 -Uninstall` | Remove scheduled task and credentials |

## Configuration

Edit `config.json` to customize settings:

```json
{
  "qbittorrent": {
    "exePath": "C:\\Program Files\\qBittorrent\\qbittorrent.exe",
    "webUrl": "http://localhost:8080"
  },
  "monitoring": {
    "pollIntervalSeconds": 30,
    "maxRetries": 3,
    "retryDelaySeconds": 5
  },
  "logging": {
    "maxSizeMB": 1
  }
}
```

## Features

- **Zero dependencies** - Uses only Windows built-ins
- **Secure credentials** - Stored in Windows Credential Manager
- **Auto-retry** - Configurable retry logic for API failures
- **Status command** - Check current state with `-Status`
- **Log rotation** - Automatic log file rotation at 1MB
- **Modular design** - Separate modules for easy maintenance

## Architecture

```
qbitstatic/
├── qbitstatic.ps1      # Main script
├── config.json         # Configuration
├── modules/            # PowerShell modules
│   ├── Config.psm1
│   ├── Logging.psm1
│   ├── Credentials.psm1
│   ├── PortDetector.psm1
│   └── QBittorrentApi.psm1
└── tests/              # Pester tests
```

## Logs

`%LOCALAPPDATA%\qbitstatic\qbitstatic.log`

## How It Works

1. Reads ProtonVPN's forwarded port from client logs
2. Compares with qBittorrent's current listening port
3. If different, updates qBittorrent via Web API and restarts it
4. Each poll, also compares qBittorrent's bound interface GUID with the current Windows GUID for the same adapter name; if drifted, updates and restarts
5. Polls every 30 seconds (configurable)

The Proton VPN client logs the forwarded port as `Port pair <internal>-><external>` in `client-logs.txt`. This format has been stable across client updates, so no configuration change is needed after a Proton VPN update.

### Scheduled task resilience

The monitor is a long-running process. The scheduled task uses **two triggers**:

- **AtLogon** — starts the monitor when you sign in.
- **Watchdog** — a repeating trigger (every 15 minutes, indefinitely) that re-launches the monitor if its process has died. Combined with the task's `IgnoreNew` multiple-instances policy, the watchdog is a no-op while the monitor is already running, so it never spawns duplicates.

The watchdog exists because `AtLogon` does **not** fire on resume-from-sleep. Without it, if the monitor process is terminated (e.g. at shutdown/sleep) and the machine resumes without a full logon, the monitor would stay dead and qBittorrent's port would silently drift out of sync until the next sign-in.

## Troubleshooting

**`-Status` shows "VPN Port: Not detected"**

This means ProtonVPN is not currently forwarding a port, so there is nothing for qbitstatic to read. The client only writes a `Port pair` line while port forwarding is active; when forwarding fails it logs `PortForwarding Status 'Error'` instead. To fix:

- Ensure **Port forwarding** is enabled in Proton VPN settings
- Connect to a **P2P server that supports port forwarding** (reconnect if the current session shows a port-forwarding error)

Once Proton VPN is actively forwarding a port, qbitstatic detects it on the next poll and syncs qBittorrent automatically. The network-interface GUID sync runs independently and works whenever the `ProtonVPN` adapter is up.

**`-Status` detects the VPN port but qBittorrent never syncs**

Syncing happens only in the background monitor, not in `-Status` (which just reports). Check that the monitor is actually running:

```powershell
.\qbitstatic.ps1 -Status   # "Scheduled Task: Running" means the monitor is active
```

If it shows `Ready` (idle), start it with `Start-ScheduledTask -TaskName qbitstatic`. The task is triggered at logon and by a 15-minute watchdog, so it normally revives itself within 15 minutes of dying.

> **Note:** Two historical issues caused the monitor to silently stop and the port to drift out of sync:
> - A default 72-hour execution limit (Windows killed the task after 3 days). Fixed: the install now passes `-ExecutionTimeLimit 0`.
> - Only an `AtLogon` trigger, which does not fire on resume-from-sleep, so a process killed at shutdown/sleep stayed dead until the next sign-in. Fixed: the install now adds a 15-minute watchdog trigger with an `IgnoreNew` instances policy (see *Scheduled task resilience* above).
>
> Re-run `.\qbitstatic.ps1 -Install` to recreate the task with both fixes applied.

## Testing

```powershell
# Syntax check
.\tests\syntax-check.ps1

# Full tests (requires Pester 5+)
.\tests\Run-Tests.ps1
```

## License

MIT
