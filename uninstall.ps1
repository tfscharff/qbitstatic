#Requires -Version 5.1

<#
.SYNOPSIS
    Uninstalls qbitstatic.
.DESCRIPTION
    Removes the scheduled task and stored credentials.
#>

$CREDENTIAL_TARGET = "qbitstatic-qbittorrent"
$TASK_NAME = "qbitstatic"

Write-Host "qbitstatic Uninstall" -ForegroundColor Cyan
Write-Host "====================" -ForegroundColor Cyan
Write-Host ""

# Remove scheduled task
try {
    $task = Get-ScheduledTask -TaskName $TASK_NAME -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $TASK_NAME -Confirm:$false
        Write-Host "Scheduled task removed." -ForegroundColor Green
    } else {
        Write-Host "Scheduled task not found (already removed)." -ForegroundColor Yellow
    }
} catch {
    Write-Host "Failed to remove scheduled task: $_" -ForegroundColor Red
}

# Remove stored credentials
try {
    $result = cmdkey /delete:$CREDENTIAL_TARGET 2>&1
    if ($result -match "deleted") {
        Write-Host "Credentials removed from Windows Credential Manager." -ForegroundColor Green
    } else {
        Write-Host "Credentials not found (already removed)." -ForegroundColor Yellow
    }
} catch {
    Write-Host "Failed to remove credentials: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "Uninstall complete." -ForegroundColor Green
Write-Host ""
Write-Host "Note: Log files at %LOCALAPPDATA%\qbitstatic\ were not removed." -ForegroundColor Gray
Write-Host "Delete them manually if desired." -ForegroundColor Gray
