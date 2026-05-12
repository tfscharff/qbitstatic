#Requires -Version 5.1
<#
.SYNOPSIS
    Logging utilities for qbitstatic.
#>

$script:LogCheckCounter = 0
$script:LogFilePath = $null
$script:LogMaxSize = 1
$script:LogCheckInterval = 100

function Initialize-Logging {
    <#
    .SYNOPSIS
        Initialize logging with configuration.
    #>
    param(
        [string]$LogDir,
        [string]$LogFile,
        [int]$MaxSizeMB = 1,
        [int]$CheckInterval = 100
    )

    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    $script:LogFilePath = Join-Path $LogDir $LogFile
    $script:LogMaxSize = $MaxSizeMB
    $script:LogCheckInterval = $CheckInterval
    $script:LogCheckCounter = 0
}

function Write-Log {
    <#
    .SYNOPSIS
        Write a message to the log file.
    .PARAMETER Message
        The message to log.
    .PARAMETER Level
        Log level (INFO, WARN, ERROR).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    if (-not $script:LogFilePath) {
        throw "Logging not initialized. Call Initialize-Logging first."
    }

    # Check log size periodically
    if (++$script:LogCheckCounter -ge $script:LogCheckInterval) {
        $script:LogCheckCounter = 0
        if ((Test-Path $script:LogFilePath) -and ((Get-Item $script:LogFilePath).Length / 1MB) -gt $script:LogMaxSize) {
            $oldLog = "$script:LogFilePath.old"
            Remove-Item $oldLog -Force -ErrorAction SilentlyContinue
            Rename-Item $script:LogFilePath $oldLog -ErrorAction SilentlyContinue
        }
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $script:LogFilePath -Value "[$timestamp] [$Level] $Message"
}

function Get-LogPath {
    return $script:LogFilePath
}

Export-ModuleMember -Function Initialize-Logging, Write-Log, Get-LogPath
