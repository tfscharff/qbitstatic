# qbitstatic

PowerShell tool that syncs ProtonVPN's port forwarding port to qBittorrent on Windows.

## Architecture

Single script (`qbitstatic.ps1`) with these components:
- **Port Detector**: Reads ProtonVPN port from client logs (`%LOCALAPPDATA%\Proton\Proton VPN\Logs\client-logs.txt`), reads only last 50KB for efficiency, caches file modification time to skip unchanged reads
- **Credential Manager**: Stores/retrieves qBittorrent credentials via Windows Credential Manager (P/Invoke to advapi32.dll with CRED_TYPE_GENERIC)
- **qBittorrent API**: Connects to Web UI, gets/sets listening port, triggers restart with graceful shutdown
- **Main Loop**: Polls every 30s, reuses session when valid, updates qBittorrent when VPN port changes

## Key Files

- `qbitstatic.ps1` - Main script (run with `-Install` for setup, no args for monitoring)
- `uninstall.ps1` - Removes scheduled task and credentials

## Development Notes

- Target: PowerShell 5.1+ (Windows 10/11 built-in)
- No external dependencies
- Credentials stored in Windows Credential Manager (target: `qbitstatic-qbittorrent`)
- Logs to `%LOCALAPPDATA%\qbitstatic\qbitstatic.log` (1MB rotation)
- Runs as scheduled task triggered at logon

## Testing

```powershell
# Syntax check
powershell -Command "[scriptblock]::Create((Get-Content .\qbitstatic.ps1 -Raw))"

# Manual run
.\qbitstatic.ps1

# Install
.\qbitstatic.ps1 -Install
```
