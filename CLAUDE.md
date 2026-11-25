# qbitstatic

PowerShell tool that syncs ProtonVPN's port forwarding port **and network interface GUID** to qBittorrent on Windows. The interface sync prevents the "configured network interface is invalid" error that occurs when ProtonVPN's WireGuard adapter is reassigned a GUID on reconnect, which otherwise causes qBittorrent to listen on no port until manually reconfigured.

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

## Releasing

A release is a version bump and a tag. There is no package: the tool runs from this folder.
Release after a change to the scripts, modules or `config.json`. A change to docs or tests alone
needs no release.

1. Run the checks in "Testing"; do not release if any fails.
2. Pick the new version by Semantic Versioning 2.0.0: a fix is a patch, a new feature or option
   is a minor, and a change that breaks an existing `config.json` or command is a major.
3. Set `$Script:QbitstaticVersion` in `qbitstatic.ps1` to it. That line is the only place the version is written.
4. Commit that one file as `chore(release): vX.Y.Z`.
5. Tag the commit with an annotated tag: `git tag -a vX.Y.Z -m "qbitstatic X.Y.Z"`.
6. Push the commit and the tag together: `git push --follow-tags`.
7. Check `.\qbitstatic.ps1 -Version` prints the new version.

The scheduled task keeps running the code it loaded at start. After a release, the new code
takes effect when the monitor next restarts (sign-in, or ending and starting the `qbitstatic`
task); say so to the user and leave the restart to them.
