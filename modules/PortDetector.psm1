#Requires -Version 5.1
<#
.SYNOPSIS
    ProtonVPN port forwarding detection.
#>

$script:LastLogTime = [DateTime]::MinValue
$script:LastVpnPort = $null
$script:VpnLogPath = $null
$script:PortPattern = "Port pair (\d+)->"

function Initialize-PortDetector {
    <#
    .SYNOPSIS
        Initialize the port detector with configuration.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$LogPath,
        [string]$Pattern = "Port pair (\d+)->"
    )

    $script:VpnLogPath = $LogPath
    $script:PortPattern = $Pattern
    $script:LastLogTime = [DateTime]::MinValue
    $script:LastVpnPort = $null
}

function Get-VpnPort {
    <#
    .SYNOPSIS
        Get the current ProtonVPN forwarded port.
    .OUTPUTS
        Port number (int) or $null if not found.
    #>
    param(
        [int]$MaxReadBytes = 51200  # 50KB
    )

    if (-not $script:VpnLogPath) {
        throw "Port detector not initialized. Call Initialize-PortDetector first."
    }

    if (-not (Test-Path $script:VpnLogPath)) {
        return $null
    }

    # Skip read if file unchanged
    $modTime = (Get-Item $script:VpnLogPath).LastWriteTime
    if ($modTime -eq $script:LastLogTime -and $null -ne $script:LastVpnPort) {
        return $script:LastVpnPort
    }
    $script:LastLogTime = $modTime

    try {
        # Read only last portion for efficiency
        $stream = [IO.File]::Open($script:VpnLogPath, 'Open', 'Read', 'ReadWrite')
        try {
            $size = [Math]::Min($stream.Length, $MaxReadBytes)
            $stream.Seek(-$size, 'End') | Out-Null
            $reader = [IO.StreamReader]::new($stream)
            $text = $reader.ReadToEnd()
            $reader.Close()
        }
        finally {
            $stream.Close()
        }

        $matches = [regex]::Matches($text, $script:PortPattern)
        if ($matches.Count -gt 0) {
            $port = [int]$matches[$matches.Count - 1].Groups[1].Value
            if ($port -ge 1024 -and $port -le 65535) {
                $script:LastVpnPort = $port
                return $port
            }
        }
    }
    catch {
        # Silently fail - file may be locked
    }

    return $null
}

function Get-CachedPort {
    <#
    .SYNOPSIS
        Get the last cached port without re-reading the log.
    #>
    return $script:LastVpnPort
}

function Reset-PortCache {
    <#
    .SYNOPSIS
        Clear the port cache to force a fresh read.
    #>
    $script:LastLogTime = [DateTime]::MinValue
    $script:LastVpnPort = $null
}

Export-ModuleMember -Function Initialize-PortDetector, Get-VpnPort, Get-CachedPort, Reset-PortCache
