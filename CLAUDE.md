# qbitstatic

PowerShell tool that syncs ProtonVPN's port forwarding port to qBittorrent on Windows.

## Architecture

### Modular Structure (v2.0)

```
qbitstatic/
├── qbitstatic.ps1           # Main entry point (-Install, -Status, -Uninstall)
├── config.json              # Configuration file
├── modules/
│   ├── Config.psm1          # Configuration loading
│   ├── Logging.psm1         # Log file management
│   ├── Credentials.psm1     # Windows Credential Manager
│   ├── PortDetector.psm1    # ProtonVPN port detection
│   └── QBittorrentApi.psm1  # qBittorrent Web API
└── tests/
    ├── Run-Tests.ps1        # Test runner
    ├── syntax-check.ps1     # Quick syntax validation
    ├── Config.Tests.ps1
    ├── Logging.Tests.ps1
    ├── PortDetector.Tests.ps1
    └── QBittorrentApi.Tests.ps1
```

### Module Responsibilities

- **Config.psm1**: Loads `config.json`, expands environment variables, caches config
- **Logging.psm1**: Timestamped logging with rotation (1MB default)
- **Credentials.psm1**: P/Invoke to Windows Credential Manager (advapi32.dll)
- **PortDetector.psm1**: Reads ProtonVPN logs, extracts port, caches results
- **QBittorrentApi.psm1**: HTTP client with retry logic, session management

### Key Features

- **Configuration file**: All settings in `config.json` (no code editing)
- **Retry logic**: Configurable retries with delay for API failures
- **Error resilience**: Consecutive error tracking, graceful exit after threshold
- **Status command**: `-Status` flag shows current state at a glance

## Commands

```powershell
# Install (prompts for credentials, creates scheduled task)
.\qbitstatic.ps1 -Install

# Show status
.\qbitstatic.ps1 -Status

# Start monitoring (runs in foreground)
.\qbitstatic.ps1

# Uninstall
.\qbitstatic.ps1 -Uninstall
```

## Configuration

Edit `config.json` to customize:

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
  }
}
```

## Testing

```powershell
# Quick syntax check
.\tests\syntax-check.ps1

# Full test suite (requires Pester 5+)
.\tests\Run-Tests.ps1

# With coverage
.\tests\Run-Tests.ps1 -Coverage
```

## Development Notes

- Target: PowerShell 5.1+ (Windows 10/11 built-in)
- No external dependencies (uses Windows built-ins)
- Credentials stored in Windows Credential Manager
- Logs to `%LOCALAPPDATA%\qbitstatic\qbitstatic.log`
- Runs as scheduled task triggered at logon
