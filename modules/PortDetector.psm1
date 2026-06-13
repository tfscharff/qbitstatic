#Requires -Version 5.1
<#
.SYNOPSIS
    ProtonVPN port forwarding detection.
#>

$script:LastLogTime = [DateTime]::MinValue
$script:LastVpnPort = $null
$script:VpnLogPath = $null
$script:PortPattern = "Port pair (\d+)->"
$script:LastDetectionInfo = $null

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
    $script:LastDetectionInfo = $null
}

function Get-VpnLogFile {
    <#
    .SYNOPSIS
        Resolve the ProtonVPN log file(s) to read, newest-first.
    .DESCRIPTION
        Returns the configured log plus any rotated/sibling logs (e.g. client-logs.1.txt)
        that exist, ordered most-recently-written first. If the configured file is missing
        (e.g. a Proton update moved the log folder) but the directory still has matching
        files, those are returned so detection keeps working.
    #>
    if (-not $script:VpnLogPath) {
        throw "Port detector not initialized. Call Initialize-PortDetector first."
    }

    $files = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $script:VpnLogPath) {
        $files.Add((Get-Item -LiteralPath $script:VpnLogPath))
    }

    $dir = Split-Path $script:VpnLogPath -Parent
    if ($dir -and (Test-Path -LiteralPath $dir)) {
        $leaf = Split-Path $script:VpnLogPath -Leaf
        $base = [IO.Path]::GetFileNameWithoutExtension($leaf)
        $ext = [IO.Path]::GetExtension($leaf)
        Get-ChildItem -LiteralPath $dir -Filter "$base*$ext" -File -ErrorAction SilentlyContinue |
            ForEach-Object { $files.Add($_) }
    }

    $files | Sort-Object -Property FullName -Unique | Sort-Object -Property LastWriteTime -Descending
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

    $files = @(Get-VpnLogFile)
    if ($files.Count -eq 0) {
        $script:LastDetectionInfo = @{
            LogPath = $script:VpnLogPath; Exists = $false
            SizeBytes = 0; LastWrite = $null; HadPortLine = $false; Port = $null
        }
        return $null
    }

    # Skip re-read if the newest candidate is unchanged since last successful read.
    $newest = $files[0]
    if ($newest.LastWriteTime -eq $script:LastLogTime -and $null -ne $script:LastVpnPort) {
        return $script:LastVpnPort
    }
    $script:LastLogTime = $newest.LastWriteTime

    $hadPortLine = $false
    foreach ($f in $files) {
        $text = $null
        try {
            $stream = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
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
        }
        catch {
            # File locked/unavailable; try the next candidate.
            continue
        }

        $matches = [regex]::Matches($text, $script:PortPattern)
        if ($matches.Count -gt 0) {
            $hadPortLine = $true
            $port = [int]$matches[$matches.Count - 1].Groups[1].Value
            if ($port -ge 1024 -and $port -le 65535) {
                $script:LastVpnPort = $port
                $script:LastDetectionInfo = @{
                    LogPath = $f.FullName; Exists = $true
                    SizeBytes = $f.Length; LastWrite = $f.LastWriteTime
                    HadPortLine = $true; Port = $port
                }
                return $port
            }
        }
    }

    # No usable port in any candidate. Record why, so the caller can log it.
    $script:LastDetectionInfo = @{
        LogPath = $newest.FullName; Exists = $true
        SizeBytes = $newest.Length; LastWrite = $newest.LastWriteTime
        HadPortLine = $hadPortLine; Port = $null
    }
    return $null
}

function Get-DetectionInfo {
    <#
    .SYNOPSIS
        Diagnostics from the most recent Get-VpnPort call (resolved log path, whether it
        existed, size, mtime, whether any port line matched, and the detected port).
        Lets the monitor explain *why* detection failed without re-reading the log.
    #>
    return $script:LastDetectionInfo
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

Export-ModuleMember -Function Initialize-PortDetector, Get-VpnPort, Get-VpnLogFile, Get-DetectionInfo, Get-CachedPort, Reset-PortCache
