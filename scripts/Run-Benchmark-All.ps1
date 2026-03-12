<#
.SYNOPSIS
    Orchestrate VM benchmarks: deploy infra, deploy VMs in batches, poll for
    completion, collect results, destroy.

.DESCRIPTION
    Uses a split Terraform layout:
      - infra/  : shared resources (RG, VNet, storage) - deployed once
      - vm/     : single VM (NIC, VM, extension) - one state file per VM

    Each VM automatically runs benchmarks via CustomScript extension and uploads
    results + a DONE marker to blob storage. The orchestrator just polls for
    completion, downloads results, and tears down.

.PARAMETER BatchSize
    Max VMs to deploy simultaneously. Default: 2

.PARAMETER Suites
    Comma-separated benchmark suites. Default: cpu,memory,disk,network,system

.PARAMETER SkipDestroy
    If set, skips the final infrastructure destroy.

.PARAMETER GithubRef
    Git branch/tag/commit for benchmark scripts. Default: main

.EXAMPLE
    .\Run-Benchmark-All.ps1
    .\Run-Benchmark-All.ps1 -BatchSize 1 -Suites "cpu,memory"
    .\Run-Benchmark-All.ps1 -SkipDestroy
#>
param(
    [int]$BatchSize = 2,
    [string]$Suites = "cpu,memory,disk,network,system",
    [string]$GithubRef = "main",
    [switch]$SkipDestroy
)

$ErrorActionPreference = "Stop"
$ProjectDir = Split-Path -Parent $PSScriptRoot
$InfraDir = Join-Path $ProjectDir "infra"
$VmDir = Join-Path $ProjectDir "vm"
$StatesDir = Join-Path $ProjectDir "states"
$ResultsDir = Join-Path $ProjectDir "results"
$ScriptsDir = $PSScriptRoot

# --- VM configurations ---
$allVms = [ordered]@{
    "e64asv5" = @{ vm_size = "Standard_E64as_v5" }
    "e64sv5"  = @{ vm_size = "Standard_E64s_v5" }
    "e96asv5" = @{ vm_size = "Standard_E96as_v5" }
}

$vmNames = @($allVms.Keys)
$totalVms = $vmNames.Count
$totalBatches = [math]::Ceiling($totalVms / $BatchSize)

Write-Host "=============================================="  -ForegroundColor Cyan
Write-Host " Azure VM Benchmark - Split Orchestrator"       -ForegroundColor Cyan
Write-Host " VMs to benchmark: $totalVms"                   -ForegroundColor Cyan
Write-Host " Batch size: $BatchSize"                        -ForegroundColor Cyan
Write-Host " Total batches: $totalBatches"                  -ForegroundColor Cyan
Write-Host " Suites: $Suites"                               -ForegroundColor Cyan
Write-Host " Git ref: $GithubRef"                           -ForegroundColor Cyan
Write-Host "=============================================="  -ForegroundColor Cyan
Write-Host ""

# --- Helpers ---

function Write-Step($msg) {
    Write-Host ">>> $msg" -ForegroundColor Green
}

function Write-SubStep($msg) {
    Write-Host "    $msg" -ForegroundColor Gray
}

function Invoke-Terraform {
    param(
        [string]$WorkDir,
        [string[]]$Arguments,
        [string]$Description = "terraform"
    )

    Push-Location $WorkDir
    try {
        Write-SubStep "Running: terraform $($Arguments -join ' ')"
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $output = & terraform @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP

        # Always show output
        $output | ForEach-Object { Write-Host "  $_" }

        if ($exitCode -ne 0) {
            throw "$Description failed (exit code $exitCode)"
        }
        return $output
    }
    finally {
        Pop-Location
    }
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
    finally {
        Pop-Location
    }
}

function Deploy-VM {
    param(
        [string]$VmKey,
        [string]$VmSize,
        [hashtable]$InfraOutputs
    )

    $stateFile = Join-Path $StatesDir "$VmKey.tfstate"

    $tfArgs = @(
        "apply", "-auto-approve",
        "-state", $stateFile,
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

    Invoke-Terraform -WorkDir $VmDir -Arguments $tfArgs -Description "Deploy VM $VmKey"
}

function Destroy-VM {
    param(
        [string]$VmKey,
        [hashtable]$InfraOutputs
    )

    $stateFile = Join-Path $StatesDir "$VmKey.tfstate"
    if (-not (Test-Path $stateFile)) {
        Write-SubStep "No state file for $VmKey, skipping destroy"
        return
    }

    $tfArgs = @(
        "destroy", "-auto-approve",
        "-state", $stateFile,
        "-var", "subscription_id=$($InfraOutputs.subscription_id)",
        "-var", "resource_group_name=$($InfraOutputs.resource_group_name)",
        "-var", "location=$($InfraOutputs.location)",
        "-var", "subnet_id=$($InfraOutputs.subnet_id)",
        "-var", "storage_account_id=$($InfraOutputs.storage_account_id)",
        "-var", "storage_account_name=$($InfraOutputs.storage_account_name)",
        "-var", "storage_container_name=$($InfraOutputs.storage_container_name)",
        "-var", "vm_name=$VmKey",
        "-var", "vm_size=Standard_D2s_v5",
        "-var", "ssh_public_key_path=$($InfraOutputs.ssh_public_key_path)"
    )

    Invoke-Terraform -WorkDir $VmDir -Arguments $tfArgs -Description "Destroy VM $VmKey"
}

function Wait-BenchmarkCompletion {
    param(
        [string[]]$VmKeys,
        [string]$StorageAccount,
        [string]$Container,
        [int]$MaxWaitMinutes = 120
    )

    Write-Step "Waiting for benchmarks to complete..."
    $pending = [System.Collections.Generic.List[string]]::new($VmKeys)
    $maxAttempts = $MaxWaitMinutes * 2  # check every 30s
    $attempt = 0

    while ($pending.Count -gt 0 -and $attempt -lt $maxAttempts) {
        $attempt++
        Start-Sleep -Seconds 30

        foreach ($key in @($pending)) {
            $blobName = "vm-bench-${key}/DONE"
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            $exists = az storage blob exists `
                --account-name $StorageAccount `
                --container-name $Container `
                --name $blobName `
                --auth-mode login `
                --query "exists" -o tsv 2>$null
            $ErrorActionPreference = $prevEAP

            if ($exists -eq "true") {
                Write-SubStep "VM ${key}: benchmark complete"
                $pending.Remove($key) | Out-Null
            }
        }

        if ($pending.Count -gt 0 -and ($attempt % 4 -eq 0)) {
            $elapsed = $attempt * 30
            Write-SubStep "Still waiting (${elapsed}s): $($pending -join ', ')"
        }
    }

    if ($pending.Count -gt 0) {
        Write-Host "WARNING: Benchmarks did not complete for: $($pending -join ', ')" -ForegroundColor Yellow
        return $false
    }
    return $true
}

function Download-Results {
    param(
        [string]$StorageAccount,
        [string]$Container,
        [string]$VmKey
    )

    $localDir = Join-Path $ResultsDir $VmKey
    New-Item -ItemType Directory -Path $localDir -Force | Out-Null
    $localTar = Join-Path $localDir "results.tar.gz"

    Write-SubStep "Downloading results for $VmKey..."

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    az storage blob download `
        --account-name $StorageAccount `
        --container-name $Container `
        --name "vm-bench-${VmKey}/results.tar.gz" `
        --file $localTar `
        --auth-mode login `
        --only-show-errors 2>$null | Out-Null
    $ErrorActionPreference = $prevEAP

    if (Test-Path $localTar) {
        tar -xzf $localTar -C $localDir
        Remove-Item $localTar -Force
        Write-SubStep "Results extracted to $localDir"
    }
    else {
        Write-Host "WARNING: Could not download results for $VmKey" -ForegroundColor Yellow
    }
}

# ══════════════════════════════════════════════
#  Main orchestration
# ══════════════════════════════════════════════

New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
New-Item -ItemType Directory -Path $StatesDir -Force | Out-Null

# --- 1. Deploy shared infrastructure ---
Write-Step "Deploying shared infrastructure..."
Invoke-Terraform -WorkDir $InfraDir -Arguments @("init", "-input=false") -Description "infra init"
Invoke-Terraform -WorkDir $InfraDir -Arguments @("apply", "-auto-approve") -Description "infra apply"

# Read infra outputs
$infraOutputs = @{
    subscription_id      = (Get-Content (Join-Path $InfraDir "terraform.tfvars") | Select-String 'subscription_id\s*=' | ForEach-Object { ($_ -split '"')[1] })
    resource_group_name  = Get-InfraOutput "resource_group_name"
    location             = Get-InfraOutput "location"
    subnet_id            = Get-InfraOutput "subnet_id"
    storage_account_id   = Get-InfraOutput "storage_account_id"
    storage_account_name = Get-InfraOutput "storage_account_name"
    storage_container_name = Get-InfraOutput "storage_container_name"
    ssh_public_key_path  = "~/.ssh/id_aldi_ed25519.pub"
}

Write-SubStep "Resource group: $($infraOutputs.resource_group_name)"
Write-SubStep "Storage account: $($infraOutputs.storage_account_name)"

# Init vm/ module once
Write-Step "Initializing VM module..."
Invoke-Terraform -WorkDir $VmDir -Arguments @("init", "-input=false") -Description "vm init"

# --- 2. Process batches ---
for ($batchIdx = 0; $batchIdx -lt $totalBatches; $batchIdx++) {
    $startIdx = $batchIdx * $BatchSize
    $endIdx = [math]::Min($startIdx + $BatchSize, $totalVms) - 1
    $batchKeys = $vmNames[$startIdx..$endIdx]
    $batchNum = $batchIdx + 1

    Write-Host ""
    Write-Host "=============================================="  -ForegroundColor Yellow
    Write-Host " Batch $batchNum / $totalBatches"               -ForegroundColor Yellow
    Write-Host " VMs: $($batchKeys -join ', ')"                 -ForegroundColor Yellow
    Write-Host "=============================================="  -ForegroundColor Yellow

    # Deploy all VMs in batch
    Write-Step "Deploying batch $batchNum VMs..."
    foreach ($key in $batchKeys) {
        Write-SubStep "--- Deploying: $key ($($allVms[$key].vm_size)) ---"
        Deploy-VM -VmKey $key -VmSize $allVms[$key].vm_size -InfraOutputs $infraOutputs
    }

    # Wait for all VMs in batch to complete benchmarks (polling DONE marker)
    Wait-BenchmarkCompletion `
        -VmKeys $batchKeys `
        -StorageAccount $infraOutputs.storage_account_name `
        -Container $infraOutputs.storage_container_name

    # Download results
    Write-Step "Downloading results for batch $batchNum..."
    foreach ($key in $batchKeys) {
        Download-Results `
            -StorageAccount $infraOutputs.storage_account_name `
            -Container $infraOutputs.storage_container_name `
            -VmKey $key
    }

    # Destroy batch VMs
    Write-Step "Destroying batch $batchNum VMs..."
    foreach ($key in $batchKeys) {
        Destroy-VM -VmKey $key -InfraOutputs $infraOutputs
    }

    Write-Host "Batch $batchNum complete." -ForegroundColor Green
}

# --- 3. Merge results ---
Write-Host ""
Write-Step "Collecting and scoring results..."
& "$ScriptsDir\Collect-Results.ps1" -ResultsDir $ResultsDir

# --- 4. Final cleanup ---
if (-not $SkipDestroy) {
    Write-Host ""
    Write-Step "Destroying shared infrastructure..."
    Invoke-Terraform -WorkDir $InfraDir -Arguments @("destroy", "-auto-approve") -Description "infra destroy"
}
else {
    Write-Host ""
    Write-Host "Skipping final destroy (--SkipDestroy). Run 'terraform -chdir=infra destroy' manually." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=============================================="  -ForegroundColor Green
Write-Host " Benchmarking complete!"                        -ForegroundColor Green
Write-Host " Results: $ResultsDir"                          -ForegroundColor Green
Write-Host " JSON:    $(Join-Path $ResultsDir 'results.json')" -ForegroundColor Green
Write-Host " CSV:     $(Join-Path $ResultsDir 'summary.csv')"  -ForegroundColor Green
Write-Host "=============================================="  -ForegroundColor Green
