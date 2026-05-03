#Requires -Version 5.1
# Uninstalls qbitstatic: removes scheduled task and credentials

Write-Host "`nqbitstatic Uninstall`n" -ForegroundColor Cyan

# Remove scheduled task
if (Get-ScheduledTask -TaskName qbitstatic -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName qbitstatic -Confirm:$false
    Write-Host "Scheduled task removed." -ForegroundColor Green
} else {
    Write-Host "Scheduled task not found." -ForegroundColor Yellow
}

# Remove credentials
if ((cmdkey /delete:qbitstatic-qbittorrent 2>&1) -match "deleted") {
    Write-Host "Credentials removed." -ForegroundColor Green
} else {
    Write-Host "Credentials not found." -ForegroundColor Yellow
}

Write-Host "`nDone. Logs at %LOCALAPPDATA%\qbitstatic\ not removed.`n" -ForegroundColor Gray
