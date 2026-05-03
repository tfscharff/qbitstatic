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
