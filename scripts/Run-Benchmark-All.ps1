<#
.SYNOPSIS
    Full end-to-end benchmark: deploy VMs, wait for results, collect and score.

.DESCRIPTION
    Convenience wrapper that calls Deploy-Benchmark.ps1 then Download-Results.ps1.
    All settings are read from a JSON config file (default: benchmark.json).

    For more control, use the individual scripts:
      - Deploy-Benchmark.ps1 : deploy infra + VMs (fire and forget)
      - Download-Results.ps1 : poll, download, optionally destroy, score
      - Collect-Results.ps1  : score local results only

.PARAMETER ConfigFile
    Path to JSON config file. Default: <project-root>/benchmark.json

.PARAMETER VmNames
    Comma-separated VM keys to deploy. Default: all VMs in config.

.PARAMETER Suites
    Comma-separated benchmark suites. Default: from config file.

.PARAMETER GithubRef
    Git branch/tag/commit for benchmark scripts. Default: from config file.

.PARAMETER MaxWaitMinutes
    Maximum minutes to wait for benchmarks. Default: from config file.

.PARAMETER SkipDestroy
    If set, skips destroying VMs and infrastructure after completion.

.EXAMPLE
    .\Run-Benchmark-All.ps1
    .\Run-Benchmark-All.ps1 -VmNames "e8asv5" -SkipDestroy
    .\Run-Benchmark-All.ps1 -ConfigFile "./my-config.json"
#>
param(
    [string]$ConfigFile = "",
    [string]$VmNames = "",
    [string]$Suites = "",
    [string]$GithubRef = "",
    [int]$MaxWaitMinutes = -1,
    [switch]$SkipDestroy
)

$ErrorActionPreference = "Stop"
$ScriptsDir = $PSScriptRoot
$ProjectDir = Split-Path -Parent $PSScriptRoot

# Resolve config file path
if ($ConfigFile -eq "") { $ConfigFile = Join-Path $ProjectDir "benchmark.json" }
if (-not (Test-Path $ConfigFile)) {
    Write-Host "ERROR: Config file not found: $ConfigFile" -ForegroundColor Red
    Write-Host "Copy benchmark.example.json to benchmark.json and edit it." -ForegroundColor Yellow
    exit 1
}

Write-Host "=============================================="  -ForegroundColor Cyan
Write-Host " Azure VM Benchmark (full run)"                 -ForegroundColor Cyan
Write-Host " Config: $ConfigFile"                           -ForegroundColor Cyan
Write-Host "=============================================="  -ForegroundColor Cyan
Write-Host ""

# --- 1. Deploy ---
$deployArgs = @{
    ConfigFile = $ConfigFile
}
if ($VmNames -ne "")   { $deployArgs.VmNames = $VmNames }
if ($Suites -ne "")    { $deployArgs.Suites = $Suites }
if ($GithubRef -ne "") { $deployArgs.GithubRef = $GithubRef }

& "$ScriptsDir\Deploy-Benchmark.ps1" @deployArgs

# --- 2. Download results ---
$downloadArgs = @{
    ConfigFile = $ConfigFile
}
if ($VmNames -ne "")       { $downloadArgs.VmNames = $VmNames }
if ($Suites -ne "")        { $downloadArgs.Suites = $Suites }
if ($GithubRef -ne "")     { $downloadArgs.GithubRef = $GithubRef }
if ($MaxWaitMinutes -ne -1){ $downloadArgs.MaxWaitMinutes = $MaxWaitMinutes }
if (-not $SkipDestroy) {
    $downloadArgs.DestroyVms = $true
    $downloadArgs.DestroyInfra = $true
}

& "$ScriptsDir\Download-Results.ps1" @downloadArgs
