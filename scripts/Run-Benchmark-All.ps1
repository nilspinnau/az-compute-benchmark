<#
.SYNOPSIS
    Full end-to-end benchmark: deploy VMs, wait for results, collect and score.

.DESCRIPTION
    Convenience wrapper that calls Deploy-Benchmark.ps1 then Download-Results.ps1.

    For more control, use the individual scripts:
      - Deploy-Benchmark.ps1 : deploy infra + VMs (fire and forget)
      - Download-Results.ps1 : poll, download, optionally destroy, score
      - Collect-Results.ps1  : score local results only

.PARAMETER VmNames
    Comma-separated VM keys to deploy. Default: all configured VMs.

.PARAMETER Suites
    Comma-separated benchmark suites. Default: cpu,memory,disk,network,system

.PARAMETER GithubRef
    Git branch/tag/commit for benchmark scripts. Default: main

.PARAMETER MaxWaitMinutes
    Maximum minutes to wait for benchmarks. Default: 120

.PARAMETER SkipDestroy
    If set, skips destroying VMs and infrastructure after completion.

.EXAMPLE
    .\Run-Benchmark-All.ps1
    .\Run-Benchmark-All.ps1 -VmNames "e64asv5" -SkipDestroy
    .\Run-Benchmark-All.ps1 -Suites "cpu,memory" -MaxWaitMinutes 60
#>
param(
    [string]$VmNames = "",
    [string]$Suites = "cpu,memory,disk,network,system",
    [string]$GithubRef = "main",
    [int]$MaxWaitMinutes = 120,
    [switch]$SkipDestroy
)

$ErrorActionPreference = "Stop"
$ScriptsDir = $PSScriptRoot

Write-Host "=============================================="  -ForegroundColor Cyan
Write-Host " Azure VM Benchmark (full run)"                 -ForegroundColor Cyan
Write-Host "=============================================="  -ForegroundColor Cyan
Write-Host ""

# --- 1. Deploy ---
$deployArgs = @{
    Suites    = $Suites
    GithubRef = $GithubRef
}
if ($VmNames -ne "") { $deployArgs.VmNames = $VmNames }

& "$ScriptsDir\Deploy-Benchmark.ps1" @deployArgs

# --- 2. Download results ---
$downloadArgs = @{
    MaxWaitMinutes = $MaxWaitMinutes
    Suites         = $Suites
    GithubRef      = $GithubRef
}
if ($VmNames -ne "") { $downloadArgs.VmNames = $VmNames }
if (-not $SkipDestroy) {
    $downloadArgs.DestroyVms = $true
    $downloadArgs.DestroyInfra = $true
}

& "$ScriptsDir\Download-Results.ps1" @downloadArgs
