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

function Get-QBittorrentInterface {
    <#
    .SYNOPSIS
        Get the current network interface binding.
    .OUTPUTS
        Hashtable with Guid and Name keys, or $null on failure.
        Guid may be empty string when no interface is configured.
    #>
    if (-not $script:QbtSession) { return $null }

    try {
        $r = Invoke-WebRequest -Uri "$script:QbtWebUrl/api/v2/app/preferences" -WebSession $script:QbtSession -UseBasicParsing -TimeoutSec 10
        $prefs = $r.Content | ConvertFrom-Json
        return @{
            Guid = $prefs.current_network_interface
            Name = $prefs.current_interface_name
        }
    }
    catch {
        return $null
    }
}

function Set-QBittorrentInterface {
    <#
    .SYNOPSIS
        Set the network interface binding by GUID and name.
    .PARAMETER Guid
        The Windows network adapter GUID (e.g. "{EAB2262D-9AB1-...}").
    .PARAMETER Name
        The friendly adapter name (e.g. "ProtonVPN").
    .OUTPUTS
        $true on success, $false on failure.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Guid,
        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not $script:QbtSession) { return $false }

    try {
        Invoke-WithRetry -Operation "set qBittorrent interface" -ScriptBlock {
            Invoke-WebRequest -Uri "$script:QbtWebUrl/api/v2/app/setPreferences" -Method POST -Body @{
                json = (@{
                    current_network_interface = $Guid
                    current_interface_name = $Name
                } | ConvertTo-Json -Compress)
            } -WebSession $script:QbtSession -UseBasicParsing -TimeoutSec 10 | Out-Null
        }
        return $true
    }
    catch {
        return $false
    }
}

function Get-AdapterGuidByName {
    <#
    .SYNOPSIS
        Look up a Windows network adapter's GUID by friendly name.
    .PARAMETER Name
        The adapter name to find (e.g. "ProtonVPN").
    .OUTPUTS
        GUID string in qBittorrent format (e.g. "{EAB2262D-...}"), or $null if not found
        or the adapter is not Up.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    try {
        $adapter = Get-NetAdapter -Name $Name -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
        if (-not $adapter) { return $null }
        return $adapter.InterfaceGuid
    }
    catch {
        return $null
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

Export-ModuleMember -Function Initialize-QBittorrentApi, Connect-QBittorrent, Disconnect-QBittorrent, Test-QBittorrentConnection, Get-QBittorrentPort, Set-QBittorrentPort, Get-QBittorrentInterface, Set-QBittorrentInterface, Get-AdapterGuidByName, Restart-QBittorrent, Get-QBittorrentExePath, Invoke-WithRetry
