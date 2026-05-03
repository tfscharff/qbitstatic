# qbitstatic

Automatically sync ProtonVPN's port forwarding port to qBittorrent on Windows.

## Requirements

- Windows 10/11
- ProtonVPN with port forwarding enabled
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
| `.\qbitstatic.ps1` | Start manually |
| `.\qbitstatic.ps1 -Install` | Re-run installation |
| `.\uninstall.ps1` | Remove scheduled task and credentials |

## Configuration

Edit variables at the top of `qbitstatic.ps1`:

| Variable | Default |
|----------|---------|
| `$QBT_EXE_PATH` | `C:\Program Files\qBittorrent\qbittorrent.exe` |
| `$QBT_WEB_URL` | `http://localhost:8080` |
| `$POLL_INTERVAL_SECONDS` | `30` |

## Logs

`%LOCALAPPDATA%\qbitstatic\qbitstatic.log`

## How It Works

1. Reads ProtonVPN's forwarded port from client logs
2. Compares with qBittorrent's current listening port
3. If different, updates qBittorrent via Web API and restarts it
4. Polls every 30 seconds

## License

MIT
