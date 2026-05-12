#Requires -Version 5.1
<#
.SYNOPSIS
    Configuration management for qbitstatic.
#>

$script:Config = $null
$script:ConfigPath = $null

function Get-QbitstaticConfig {
    <#
    .SYNOPSIS
        Loads and returns the configuration.
    .PARAMETER Path
        Path to config.json. Defaults to script directory.
    .PARAMETER Force
        Force reload from disk.
    #>
    param(
        [string]$Path,
        [switch]$Force
    )

    if ($script:Config -and -not $Force) {
        return $script:Config
    }

    if (-not $Path) {
        $Path = Join-Path (Split-Path $PSScriptRoot -Parent) "config.json"
    }

    if (-not (Test-Path $Path)) {
        throw "Configuration file not found: $Path"
    }

    $script:ConfigPath = $Path
    $raw = Get-Content $Path -Raw | ConvertFrom-Json

    # Expand environment variables in paths
    $script:Config = @{
        QbtExePath = [Environment]::ExpandEnvironmentVariables($raw.qbittorrent.exePath)
        QbtWebUrl = $raw.qbittorrent.webUrl
        CredentialTarget = $raw.qbittorrent.credentialTarget
        VpnLogPath = [Environment]::ExpandEnvironmentVariables($raw.protonvpn.logPath)
        PortPattern = $raw.protonvpn.portPattern
        PollInterval = $raw.monitoring.pollIntervalSeconds
        MaxRetries = $raw.monitoring.maxRetries
        RetryDelay = $raw.monitoring.retryDelaySeconds
        LogDir = [Environment]::ExpandEnvironmentVariables($raw.logging.directory)
        LogFile = $raw.logging.fileName
        LogMaxSizeMB = $raw.logging.maxSizeMB
        LogCheckInterval = $raw.logging.checkInterval
    }

    return $script:Config
}

function Get-ConfigPath {
    return $script:ConfigPath
}

Export-ModuleMember -Function Get-QbitstaticConfig, Get-ConfigPath
