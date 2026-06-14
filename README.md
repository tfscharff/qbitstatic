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

1. Reads ProtonVPN's forwarded port from client logs — checks the configured log file plus any rotated siblings (e.g. `client-logs.1.txt`), newest-first, so log rotation or a momentarily stale file doesn't block detection
2. Compares with qBittorrent's actual listening port **on every poll**, not just when the detected VPN port changes — this self-corrects if a transition was missed (e.g. during a Proton VPN update)
3. If different, updates qBittorrent via Web API and restarts it
4. Each poll, also compares qBittorrent's bound interface GUID with the current Windows GUID for the same adapter name; if drifted, updates and restarts
5. Polls every 30 seconds (configurable)
6. Logs a heartbeat every 10 minutes while everything is in sync, and a throttled warning if no port can be detected (log file missing, or the log format no longer matches the expected pattern)

The Proton VPN client logs the forwarded port as `Port pair <internal>-><external>` in `client-logs.txt`. This format has been stable across client updates, so no configuration change is needed after a Proton VPN update.

### Scheduled task resilience

The scheduled task runs the monitor with a single **AtLogon** trigger, delayed by 1 minute — it starts shortly after you sign in and keeps running in the background. `-ExecutionTimeLimit 0` removes the default 72-hour kill, and `-RestartCount 999 -RestartInterval 1min` restarts the task if the process exits, for any reason, almost indefinitely.

The 1-minute delay exists because, on a cold boot (e.g. after a power outage), a task started at the instant of logon can be killed within seconds by Windows with exit code `0xC000013A` (`STATUS_CONTROL_C_EXIT`) while the session/shell is still being set up. Delaying the start avoids that specific window.

However, the same `0xC000013A` exit code has also been observed **mid-session**, minutes after a normal start, with nothing logged beforehand — the cause isn't fully root-caused yet (it doesn't appear to be Windows Update, Defender, or another scheduled task on this machine). Because each occurrence counts against `-RestartCount`, the original value of 3 was getting exhausted within minutes, leaving the task `Ready` (idle) for the rest of the session. `-RestartCount 999` makes the task recover within ~1 minute every time this happens, so the monitor stays effectively "always on" regardless of cause. A `PowerShell.Exiting` engine-event handler logs a `WARN` line if the engine itself sees the termination signal, to help root-cause this further if it recurs.

An earlier version also added a 15-minute repeating "watchdog" trigger to re-launch the monitor in case `AtLogon` doesn't fire on resume-from-sleep. That trigger was removed: the monitor process is only *suspended* during sleep, not killed, so it wasn't fixing a real problem — and it flashed a console window every 15 minutes. The actual "port doesn't update" issue is a detection bug (see below), not a dead monitor.

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

If it shows `Ready` (idle), start it with `Start-ScheduledTask -TaskName qbitstatic`, or just sign out and back in.

> **Note:** A default 72-hour execution limit used to cause Windows to kill the task after 3 days, silently stopping the monitor. Fixed: the install passes `-ExecutionTimeLimit 0` so the task runs indefinitely. Re-run `.\qbitstatic.ps1 -Install` to pick up this setting if your task predates it.

**Port doesn't update after a reboot/power outage, and `-Status` shows `Scheduled Task: Ready`**

`Ready` means the monitor isn't running at all — the AtLogon-triggered run died right after this boot (check `qbitstatic.log` for a `qbitstatic v2.0 starting...` line with nothing after it, and `(Get-ScheduledTask qbitstatic | Get-ScheduledTaskInfo).LastTaskResult` for `3221225786` / `0xC000013A`). This is the cold-boot timing issue described above. To recover immediately:

```powershell
Start-ScheduledTask -TaskName qbitstatic
```

Re-run `.\qbitstatic.ps1 -Install` (elevated) to pick up the 1-minute startup delay if your task predates it — this prevents the issue on future reboots.

**Port doesn't update in qBittorrent after a Proton VPN update**

A running monitor can miss the port change that happens during/around a Proton VPN client update (the update can briefly disconnect/rotate the log file). To make this self-healing:

- Detection now falls back to rotated log siblings (`client-logs.1.txt`, etc.) if the primary log has no current port line or is missing.
- The monitor now reconciles the VPN port against qBittorrent's actual port **every poll**, regardless of whether the in-memory port value changed — so a missed update is corrected on the next poll instead of staying stuck.
- If detection still fails (e.g. Proton changed the log format), a throttled `WARN` line is written to `qbitstatic.log` every 10 minutes explaining why (file not found vs. no matching pattern vs. out-of-range value), so the cause is visible instead of qBittorrent silently sitting on a stale port.

If you still see a stale port after a Proton VPN update, check `%LOCALAPPDATA%\qbitstatic\qbitstatic.log` for `WARN`/`ERROR` lines around the time of the update.

## Testing

```powershell
# Syntax check
.\tests\syntax-check.ps1

# Full tests (requires Pester 5+)
.\tests\Run-Tests.ps1
```

## License

MIT
