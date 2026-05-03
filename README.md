# qbitstatic

Automatically sync ProtonVPN's port forwarding port to qBittorrent on Windows.

## Setup

1. **Enable qBittorrent Web UI**: Tools → Options → Web UI → Enable, set username/password

2. **Install**:
   ```powershell
   git clone https://github.com/tfscharff/qbitstatic.git
   cd qbitstatic
   .\qbitstatic.ps1 -Install
   ```

3. **Done** — runs automatically at login

## Usage

| Command | Description |
|---------|-------------|
| `.\qbitstatic.ps1` | Start manually |
| `.\uninstall.ps1` | Remove scheduled task and credentials |

Logs: `%LOCALAPPDATA%\qbitstatic\qbitstatic.log`

## Configuration

Edit variables at the top of `qbitstatic.ps1`:

| Variable | Default |
|----------|---------|
| `$QBT_EXE_PATH` | `C:\Program Files\qBittorrent\qbittorrent.exe` |
| `$QBT_WEB_URL` | `http://localhost:8080` |
| `$POLL_INTERVAL_SECONDS` | `30` |

## Requirements

- Windows 10/11
- ProtonVPN with port forwarding enabled
- qBittorrent

## License

MIT
