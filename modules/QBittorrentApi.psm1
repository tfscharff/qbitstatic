#Requires -Version 5.1
<#
.SYNOPSIS
    qBittorrent Web API integration with retry logic.
#>

$script:QbtSession = $null
$script:QbtWebUrl = "http://localhost:8080"
$script:QbtExePath = "C:\Program Files\qBittorrent\qbittorrent.exe"
$script:MaxRetries = 3
$script:RetryDelay = 5

function Initialize-QBittorrentApi {
    <#
    .SYNOPSIS
        Initialize the qBittorrent API with configuration.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$WebUrl,
        [Parameter(Mandatory)]
        [string]$ExePath,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 5
    )

    $script:QbtWebUrl = $WebUrl.TrimEnd('/')
    $script:QbtExePath = $ExePath
    $script:MaxRetries = $MaxRetries
    $script:RetryDelay = $RetryDelaySeconds
    $script:QbtSession = $null
}

function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Execute a script block with retry logic.
    #>
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        [string]$Operation = "operation"
    )

    $attempt = 0
    $lastError = $null

    while ($attempt -lt $script:MaxRetries) {
        $attempt++
        try {
            return & $ScriptBlock
        }
        catch {
            $lastError = $_
            if ($attempt -lt $script:MaxRetries) {
                Start-Sleep -Seconds $script:RetryDelay
            }
        }
    }

    throw "Failed $Operation after $script:MaxRetries attempts: $lastError"
}

function Connect-QBittorrent {
    <#
    .SYNOPSIS
        Authenticate with qBittorrent Web UI.
    .PARAMETER Credential
        PSCredential for qBittorrent Web UI.
    .OUTPUTS
        $true on success, $false on failure.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCredential]$Credential
    )

    try {
        $result = Invoke-WithRetry -Operation "qBittorrent login" -ScriptBlock {
            $r = Invoke-WebRequest -Uri "$script:QbtWebUrl/api/v2/auth/login" -Method POST -Body @{
                username = $Credential.UserName
                password = $Credential.GetNetworkCredential().Password
            } -SessionVariable session -UseBasicParsing -TimeoutSec 10

            if ($r.Content -eq "Ok.") {
                return $session
            }
            throw "Authentication failed: $($r.Content)"
        }

        $script:QbtSession = $result
        return $true
    }
    catch {
        $script:QbtSession = $null
        return $false
    }
}

function Disconnect-QBittorrent {
    <#
    .SYNOPSIS
        Clear the current session.
    #>
    $script:QbtSession = $null
}

function Test-QBittorrentConnection {
    <#
    .SYNOPSIS
        Test if the current session is valid.
    #>
    if (-not $script:QbtSession) { return $false }

    try {
        $null = Invoke-WebRequest -Uri "$script:QbtWebUrl/api/v2/app/version" -WebSession $script:QbtSession -UseBasicParsing -TimeoutSec 5
        return $true
    }
    catch {
        return $false
    }
}

function Get-QBittorrentPort {
    <#
    .SYNOPSIS
        Get the current listening port.
    .OUTPUTS
        Port number or $null.
    #>
    if (-not $script:QbtSession) { return $null }

    try {
        $r = Invoke-WebRequest -Uri "$script:QbtWebUrl/api/v2/app/preferences" -WebSession $script:QbtSession -UseBasicParsing -TimeoutSec 10
        return ($r.Content | ConvertFrom-Json).listen_port
    }
    catch {
        return $null
    }
}

function Set-QBittorrentPort {
    <#
    .SYNOPSIS
        Set the listening port.
    .PARAMETER Port
        The port number to set.
    .OUTPUTS
        $true on success, $false on failure.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1024, 65535)]
        [int]$Port
    )

    if (-not $script:QbtSession) { return $false }

    try {
        Invoke-WithRetry -Operation "set qBittorrent port" -ScriptBlock {
            Invoke-WebRequest -Uri "$script:QbtWebUrl/api/v2/app/setPreferences" -Method POST -Body @{
                json = (@{ listen_port = $Port } | ConvertTo-Json -Compress)
            } -WebSession $script:QbtSession -UseBasicParsing -TimeoutSec 10 | Out-Null
        }
        return $true
    }
    catch {
        return $false
    }
}

function Restart-QBittorrent {
    <#
    .SYNOPSIS
        Restart qBittorrent (graceful shutdown then start).
    .OUTPUTS
        $true on success, $false on failure.
    #>

    # Attempt graceful shutdown via API
    if ($script:QbtSession) {
        try {
            Invoke-WebRequest -Uri "$script:QbtWebUrl/api/v2/app/shutdown" -Method POST -WebSession $script:QbtSession -UseBasicParsing -TimeoutSec 5 | Out-Null
        }
        catch { }
    }

    # Wait for graceful shutdown
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Get-Process -Name qbittorrent -ErrorAction SilentlyContinue)) {
            break
        }
    }

    # Force kill if still running
    Get-Process -Name qbittorrent -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    # Start qBittorrent
    if (Test-Path $script:QbtExePath) {
        Start-Process $script:QbtExePath
        $script:QbtSession = $null
        return $true
    }

    return $false
}

function Get-QBittorrentExePath {
    return $script:QbtExePath
}

Export-ModuleMember -Function Initialize-QBittorrentApi, Connect-QBittorrent, Disconnect-QBittorrent, Test-QBittorrentConnection, Get-QBittorrentPort, Set-QBittorrentPort, Restart-QBittorrent, Get-QBittorrentExePath, Invoke-WithRetry
