<#
.SYNOPSIS
    Deploy infrastructure and benchmark VMs. Does NOT wait for results.

.DESCRIPTION
    Deploys shared infra (if needed) and one or more VMs in parallel.
    Each VM runs benchmarks via cloud-init and uploads results to blob storage.
    Use Download-Results.ps1 separately to collect results.

    VM definitions, Azure settings, and SSH key path are read from a JSON config
    file (default: benchmark.json in the project root). Copy benchmark.example.json
    to benchmark.json and edit it before first use.

.PARAMETER ConfigFile
    Path to JSON config file. Default: <project-root>/benchmark.json

.PARAMETER VmNames
    Comma-separated VM keys to deploy. Keys must exist in config file.
    Default: all VMs defined in config.

.PARAMETER Suites
    Comma-separated benchmark suites. Default: from config file.

.PARAMETER GithubRef
    Git branch/tag/commit for benchmark scripts. Default: from config file.

.PARAMETER SkipInfra
    If set, skip infra deployment (assume already deployed).

.EXAMPLE
    .\Deploy-Benchmark.ps1
    .\Deploy-Benchmark.ps1 -VmNames "e8asv5"
    .\Deploy-Benchmark.ps1 -VmNames "e8asv5,e8sv5" -Suites "cpu,memory"
    .\Deploy-Benchmark.ps1 -ConfigFile "./my-config.json"
#>
param(
    [string]$ConfigFile = "",
    [string]$VmNames = "",
    [string]$Suites = "",
    [string]$GithubRef = "",
    [switch]$SkipInfra
)

$ErrorActionPreference = "Stop"
$ProjectDir = Split-Path -Parent $PSScriptRoot
$InfraDir = Join-Path $ProjectDir "infra"
$VmDir = Join-Path $ProjectDir "vm"
$StatesDir = Join-Path $ProjectDir "states"

# --- Load config ---
if ($ConfigFile -eq "") { $ConfigFile = Join-Path $ProjectDir "benchmark.json" }
if (-not (Test-Path $ConfigFile)) {
    Write-Host "ERROR: Config file not found: $ConfigFile" -ForegroundColor Red
    Write-Host "Copy benchmark.example.json to benchmark.json and edit it." -ForegroundColor Yellow
    exit 1
}
$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
if ($Suites -eq "")    { $Suites = $config.benchmark_suites }
if ($GithubRef -eq "") { $GithubRef = $config.github_ref }

# Build VM config from config file
$allVmConfigs = [ordered]@{}
foreach ($prop in $config.vms.PSObject.Properties) {
    $allVmConfigs[$prop.Name] = @{ vm_size = $prop.Value.vm_size }
}

# Determine which VMs to deploy
if ($VmNames -eq "") {
    $vmKeys = @($allVmConfigs.Keys)
} else {
    $vmKeys = @($VmNames -split ',' | ForEach-Object { $_.Trim() })
    foreach ($k in $vmKeys) {
        if (-not $allVmConfigs.Contains($k)) {
            Write-Host "ERROR: Unknown VM key '$k'. Valid keys: $($allVmConfigs.Keys -join ', ')" -ForegroundColor Red
            exit 1
        }
    }
}

# --- Helpers ---

function Write-Step($msg) { Write-Host ">>> $msg" -ForegroundColor Green }
function Write-SubStep($msg) { Write-Host "    $msg" -ForegroundColor Gray }

function Invoke-Terraform {
    param([string]$WorkDir, [string[]]$Arguments, [string]$Description = "terraform")
    Push-Location $WorkDir
    try {
        Write-SubStep "Running: terraform $($Arguments -join ' ')"
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $output = & terraform @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        $output | ForEach-Object { Write-Host "  $_" }
        if ($exitCode -ne 0) { throw "$Description failed (exit code $exitCode)" }
        return $output
    }
    finally { Pop-Location }
}

function Get-InfraOutput {
    param([string]$Name)
    Push-Location $InfraDir
    try {
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $val = terraform output -raw $Name 2>$null
        $ErrorActionPreference = $prevEAP
        return $val
    }
    finally { Pop-Location }
}

function Get-TerraformVarArgs {
    param([string]$VmKey, [string]$VmSize, [hashtable]$InfraOutputs)
    return @(
        "-var", "subscription_id=$($InfraOutputs.subscription_id)",
        "-var", "resource_group_name=$($InfraOutputs.resource_group_name)",
        "-var", "location=$($InfraOutputs.location)",
        "-var", "subnet_id=$($InfraOutputs.subnet_id)",
        "-var", "storage_account_id=$($InfraOutputs.storage_account_id)",
        "-var", "storage_account_name=$($InfraOutputs.storage_account_name)",
        "-var", "storage_container_name=$($InfraOutputs.storage_container_name)",
        "-var", "vm_name=$VmKey",
        "-var", "vm_size=$VmSize",
        "-var", "ssh_public_key_path=$($InfraOutputs.ssh_public_key_path)",
        "-var", "benchmark_suites=$Suites",
        "-var", "github_ref=$GithubRef"
    )
}

# ══════════════════════════════════════════════
Write-Host "=============================================="  -ForegroundColor Cyan
Write-Host " Deploy Benchmark VMs"                          -ForegroundColor Cyan
Write-Host " VMs: $($vmKeys -join ', ')"                    -ForegroundColor Cyan
Write-Host " Suites: $Suites"                               -ForegroundColor Cyan
Write-Host "=============================================="  -ForegroundColor Cyan
Write-Host ""

New-Item -ItemType Directory -Path $StatesDir -Force | Out-Null

# --- 1. Deploy shared infrastructure ---
if (-not $SkipInfra) {
    Write-Step "Deploying shared infrastructure..."
    # Generate terraform.tfvars from config
    $tfvarsContent = @"
subscription_id     = "$($config.subscription_id)"
location            = "$($config.location)"
resource_group_name = "$($config.resource_group_name)"
address_space       = "$($config.address_space)"
"@
    $tfvarsContent | Out-File -FilePath (Join-Path $InfraDir "terraform.tfvars") -Encoding UTF8
    Invoke-Terraform -WorkDir $InfraDir -Arguments @("init", "-input=false") -Description "infra init"
    Invoke-Terraform -WorkDir $InfraDir -Arguments @("apply", "-auto-approve") -Description "infra apply"
} else {
    Write-Step "Skipping infra deployment (-SkipInfra)"
}

$infraOutputs = @{
    subscription_id        = $config.subscription_id
    resource_group_name    = Get-InfraOutput "resource_group_name"
    location               = Get-InfraOutput "location"
    subnet_id              = Get-InfraOutput "subnet_id"
    storage_account_id     = Get-InfraOutput "storage_account_id"
    storage_account_name   = Get-InfraOutput "storage_account_name"
    storage_container_name = Get-InfraOutput "storage_container_name"
    ssh_public_key_path    = $config.ssh_public_key_path
}

Write-SubStep "Resource group: $($infraOutputs.resource_group_name)"
Write-SubStep "Storage account: $($infraOutputs.storage_account_name)"

# Init vm/ module
Write-Step "Initializing VM module..."
Invoke-Terraform -WorkDir $VmDir -Arguments @("init", "-input=false") -Description "vm init"

# --- 2. Deploy VMs in parallel ---
Write-Step "Deploying VMs in parallel..."
$deployJobs = @{}

foreach ($key in $vmKeys) {
    $vmSize = $allVmConfigs[$key].vm_size
    $stateFile = Join-Path $StatesDir "$key.tfstate"
    $logFile = Join-Path $StatesDir "$key-deploy.log"
    $varArgs = Get-TerraformVarArgs -VmKey $key -VmSize $vmSize -InfraOutputs $infraOutputs

    Write-SubStep "Starting deploy: $key ($vmSize)"

    $job = Start-Job -ScriptBlock {
        param($vmDir, $stateFile, $varArgs, $logFile)
        Set-Location $vmDir
        $allArgs = @("apply", "-auto-approve", "-state", $stateFile, "-input=false") + $varArgs
        $output = & terraform @allArgs 2>&1
        $output | Tee-Object -FilePath $logFile
        if ($LASTEXITCODE -ne 0) {
            throw "terraform apply failed (exit code $LASTEXITCODE)"
        }
    } -ArgumentList $VmDir, $stateFile, $varArgs, $logFile

    $deployJobs[$key] = $job
}

# Wait for all deploy jobs
Write-Step "Waiting for deployments to complete..."
$deployedKeys = @()
foreach ($key in @($deployJobs.Keys)) {
    $job = $deployJobs[$key]
    try {
        Receive-Job -Job $job -Wait -ErrorAction Stop
        Write-SubStep "$key : deployed successfully"
        $deployedKeys += $key
    }
    catch {
        Write-Host "WARNING: $key deployment failed: $_" -ForegroundColor Yellow
        $logFile = Join-Path $StatesDir "$key-deploy.log"
        if (Test-Path $logFile) {
            Get-Content $logFile -Tail 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
        }
    }
    Remove-Job -Job $job -Force
}

# --- Summary ---
Write-Host ""
Write-Host "=============================================="  -ForegroundColor Green
Write-Host " Deployment complete"                           -ForegroundColor Green
Write-Host " Deployed: $($deployedKeys -join ', ')"         -ForegroundColor Green
if ($deployedKeys.Count -lt $vmKeys.Count) {
    $failedKeys = @($vmKeys | Where-Object { $_ -notin $deployedKeys })
    Write-Host " Failed:   $($failedKeys -join ', ')"      -ForegroundColor Yellow
}
Write-Host ""
Write-Host " Benchmarks are running via cloud-init."        -ForegroundColor Green
Write-Host " Use Download-Results.ps1 to collect results."  -ForegroundColor Green
Write-Host "=============================================="  -ForegroundColor Green
