#Requires -Version 5.1
<#
.SYNOPSIS
    Run all Pester tests for qbitstatic.
.PARAMETER Output
    Output verbosity: None, Normal, Detailed, Diagnostic
.PARAMETER Coverage
    Generate code coverage report.
#>
param(
    [ValidateSet("None", "Normal", "Detailed", "Diagnostic")]
    [string]$Output = "Normal",
    [switch]$Coverage
)

$ErrorActionPreference = "Stop"

# Check for Pester
$pester = Get-Module -Name Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester -or $pester.Version -lt [Version]"5.0.0") {
    Write-Host "Pester 5.0+ required. Installing..." -ForegroundColor Yellow
    Install-Module -Name Pester -MinimumVersion 5.0.0 -Force -SkipPublisherCheck -Scope CurrentUser
}

Import-Module Pester -MinimumVersion 5.0.0

$TestPath = $PSScriptRoot
$ModulesPath = Join-Path (Split-Path $PSScriptRoot -Parent) "modules"

$config = New-PesterConfiguration
$config.Run.Path = $TestPath
$config.Output.Verbosity = $Output

if ($Coverage) {
    $config.CodeCoverage.Enabled = $true
    $config.CodeCoverage.Path = "$ModulesPath\*.psm1"
    $config.CodeCoverage.OutputFormat = "JaCoCo"
    $config.CodeCoverage.OutputPath = Join-Path $TestPath "coverage.xml"
}

Invoke-Pester -Configuration $config
