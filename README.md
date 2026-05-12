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
4. Polls every 30 seconds (configurable)

## Testing

```powershell
# Syntax check
.\tests\syntax-check.ps1

# Full tests (requires Pester 5+)
.\tests\Run-Tests.ps1
```

## License

MIT
