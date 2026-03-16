<#
.SYNOPSIS
    Poll for benchmark completion, download results, optionally destroy VMs, and score.

.DESCRIPTION
    Opens the storage firewall, polls for DONE markers in blob storage,
    downloads results for completed VMs, optionally destroys VMs, closes
    the firewall, and runs scoring.

    Can target specific VMs or all VMs with results in blob storage.
    Works independently of Deploy-Benchmark.ps1 - you can run this at any time.

.PARAMETER VmNames
    Comma-separated VM keys to check (e.g. "e64asv5,e64sv5,e64asv6").
    Default: auto-detect from blob storage DONE markers.

.PARAMETER DestroyVms
    If set, destroy VMs after downloading their results.

.PARAMETER DestroyInfra
    If set, destroy shared infrastructure after all VMs are done.

.PARAMETER MaxWaitMinutes
    Maximum minutes to wait for benchmarks. Default: 120. Set to 0 for no waiting
    (only download already-completed results).

.PARAMETER Suites
    Only needed if -DestroyVms is set (for terraform var args). Default: cpu,memory,disk,network,system

.PARAMETER GithubRef
    Only needed if -DestroyVms is set (for terraform var args). Default: main

.EXAMPLE
    .\Download-Results.ps1
    .\Download-Results.ps1 -VmNames "e64asv5,e64sv5,e64asv6" -DestroyVms
    .\Download-Results.ps1 -MaxWaitMinutes 0
    .\Download-Results.ps1 -VmNames "e64asv5" -MaxWaitMinutes 60 -DestroyVms
#>
param(
    [string]$VmNames = "",
    [int]$MaxWaitMinutes = 120,
    [switch]$DestroyVms,
    [switch]$DestroyInfra,
    [string]$Suites = "cpu,memory,disk,network,system",
    [string]$GithubRef = "main"
)

$ErrorActionPreference = "Stop"
$ProjectDir = Split-Path -Parent $PSScriptRoot
$InfraDir = Join-Path $ProjectDir "infra"
$VmDir = Join-Path $ProjectDir "vm"
$StatesDir = Join-Path $ProjectDir "states"
$ResultsDir = Join-Path $ProjectDir "results"
$ScriptsDir = $PSScriptRoot

# --- VM configurations (must match Deploy-Benchmark.ps1) ---
$allVmConfigs = [ordered]@{
    "e8asv5" = @{ vm_size = "Standard_E8as_v5" }
    "e8sv5"  = @{ vm_size = "Standard_E8s_v5" }
    "e8asv6" = @{ vm_size = "Standard_E8as_v6" }
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

function Open-StorageFirewall {
    param([string]$StorageAccount, [string]$ResourceGroup)
    Write-SubStep "Opening storage firewall for $StorageAccount..."
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    az storage account update -n $StorageAccount -g $ResourceGroup `
        --public-network-access Enabled --default-action Allow 2>&1 | Out-Null
    $ErrorActionPreference = $prevEAP
    Start-Sleep -Seconds 30
}

function Close-StorageFirewall {
    param([string]$StorageAccount, [string]$ResourceGroup)
    Write-SubStep "Closing storage firewall for $StorageAccount..."
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    az storage account update -n $StorageAccount -g $ResourceGroup `
        --public-network-access Disabled --default-action Deny 2>&1 | Out-Null
    $ErrorActionPreference = $prevEAP
}

function Download-VmResults {
    param([string]$StorageAccount, [string]$Container, [string]$VmKey)

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
        return $true
    }
    else {
        Write-Host "WARNING: Could not download results for $VmKey" -ForegroundColor Yellow
        return $false
    }
}

# ══════════════════════════════════════════════

# Get infra outputs
$infraOutputs = @{
    subscription_id        = (Get-Content (Join-Path $InfraDir "terraform.tfvars") | Select-String 'subscription_id\s*=' | ForEach-Object { ($_ -split '"')[1] })
    resource_group_name    = Get-InfraOutput "resource_group_name"
    location               = Get-InfraOutput "location"
    subnet_id              = Get-InfraOutput "subnet_id"
    storage_account_id     = Get-InfraOutput "storage_account_id"
    storage_account_name   = Get-InfraOutput "storage_account_name"
    storage_container_name = Get-InfraOutput "storage_container_name"
    ssh_public_key_path    = "~/.ssh/id_aldi_ed25519.pub"
}

$storageAccount = $infraOutputs.storage_account_name
$container = $infraOutputs.storage_container_name
$resourceGroup = $infraOutputs.resource_group_name

New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null

Write-Host "=============================================="  -ForegroundColor Cyan
Write-Host " Download Benchmark Results"                    -ForegroundColor Cyan
Write-Host " Storage: $storageAccount / $container"         -ForegroundColor Cyan
Write-Host " Max wait: ${MaxWaitMinutes}m"                  -ForegroundColor Cyan
Write-Host "=============================================="  -ForegroundColor Cyan
Write-Host ""

# --- Open firewall ---
Write-Step "Opening storage firewall..."
Open-StorageFirewall -StorageAccount $storageAccount -ResourceGroup $resourceGroup

try {

# --- Determine which VMs to check ---
if ($VmNames -ne "") {
    $vmKeys = @($VmNames -split ',' | ForEach-Object { $_.Trim() })
} else {
    # Auto-detect: list all DONE markers and results in blob storage
    Write-Step "Auto-detecting VMs from blob storage..."
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $blobs = az storage blob list `
        --account-name $storageAccount `
        --container-name $container `
        --auth-mode login `
        --query "[].name" -o tsv 2>$null
    $ErrorActionPreference = $prevEAP

    $vmKeys = @()
    if ($blobs) {
        $vmKeys = @($blobs | ForEach-Object {
            if ($_ -match "^vm-bench-([^/]+)/") { $Matches[1] }
        } | Select-Object -Unique)
    }

    # Also check allVmConfigs for VMs that haven't uploaded yet
    foreach ($k in $allVmConfigs.Keys) {
        if ($k -notin $vmKeys) {
            # Check if there's a running VM with state
            $stateFile = Join-Path $StatesDir "$k.tfstate"
            if (Test-Path $stateFile) {
                $stateJson = Get-Content $stateFile | ConvertFrom-Json
                if ($stateJson.resources.Count -gt 0) {
                    $vmKeys += $k
                }
            }
        }
    }

    if ($vmKeys.Count -eq 0) {
        Write-Host "No VMs found to collect results for." -ForegroundColor Yellow
        return
    }
    Write-SubStep "Found VMs: $($vmKeys -join ', ')"
}

Write-Host ""

# --- Check which already have results locally ---
$alreadyCollected = @()
$needsDownload = @()
foreach ($key in $vmKeys) {
    $localDir = Join-Path $ResultsDir $key
    if ((Test-Path $localDir) -and (Get-ChildItem $localDir -Recurse -File).Count -gt 0) {
        Write-SubStep "$key : results already downloaded locally"
        $alreadyCollected += $key
    } else {
        $needsDownload += $key
    }
}

# --- Poll and download ---
if ($needsDownload.Count -gt 0 -and $MaxWaitMinutes -gt 0) {
    Write-Step "Polling for benchmark completion (max ${MaxWaitMinutes}m)..."

    $pending = New-Object System.Collections.Generic.List[string]
    foreach ($k in $needsDownload) { $pending.Add($k) }
    $downloaded = @()
    $maxAttempts = $MaxWaitMinutes * 2  # every 30s
    $attempt = 0

    while ($pending.Count -gt 0 -and $attempt -lt $maxAttempts) {
        $attempt++
        Start-Sleep -Seconds 30

        foreach ($key in @($pending)) {
            $blobName = "vm-bench-${key}/DONE"
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            $exists = az storage blob exists `
                --account-name $storageAccount `
                --container-name $container `
                --name $blobName `
                --auth-mode login `
                --query "exists" -o tsv 2>$null
            $ErrorActionPreference = $prevEAP

            if ($exists -eq "true") {
                Write-SubStep "$key : benchmark complete"
                $pending.Remove($key) | Out-Null

                $ok = Download-VmResults -StorageAccount $storageAccount -Container $container -VmKey $key
                if ($ok) { $downloaded += $key }

                # Destroy VM if requested
                if ($DestroyVms -and $allVmConfigs.Contains($key)) {
                    $stateFile = Join-Path $StatesDir "$key.tfstate"
                    if (Test-Path $stateFile) {
                        Write-SubStep "Destroying VM: $key"
                        $logFile = Join-Path $StatesDir "$key-destroy.log"
                        $varArgs = Get-TerraformVarArgs -VmKey $key -VmSize $allVmConfigs[$key].vm_size -InfraOutputs $infraOutputs
                        Start-Job -Name "destroy-$key" -ScriptBlock {
                            param($vmDir, $stateFile, $varArgs, $logFile)
                            Set-Location $vmDir
                            $allArgs = @("destroy", "-auto-approve", "-state", $stateFile, "-input=false") + $varArgs
                            & terraform @allArgs 2>&1 | Tee-Object -FilePath $logFile
                        } -ArgumentList $VmDir, $stateFile, $varArgs, $logFile | Out-Null
                    }
                }
            }
        }

        if ($pending.Count -gt 0 -and ($attempt % 4 -eq 0)) {
            $elapsed = [math]::Round($attempt * 30 / 60, 1)
            Write-SubStep "Waiting (${elapsed}m): $($pending -join ', ')"
        }
    }

    if ($pending.Count -gt 0) {
        Write-Host "WARNING: Benchmarks did not complete for: $($pending -join ', ')" -ForegroundColor Yellow
    }

    $alreadyCollected += $downloaded
}
elseif ($needsDownload.Count -gt 0 -and $MaxWaitMinutes -eq 0) {
    # No waiting - just try to download whatever is available now
    Write-Step "Downloading available results (no wait)..."
    foreach ($key in $needsDownload) {
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $exists = az storage blob exists `
            --account-name $storageAccount `
            --container-name $container `
            --name "vm-bench-${key}/DONE" `
            --auth-mode login `
            --query "exists" -o tsv 2>$null
        $ErrorActionPreference = $prevEAP

        if ($exists -eq "true") {
            $ok = Download-VmResults -StorageAccount $storageAccount -Container $container -VmKey $key
            if ($ok) { $alreadyCollected += $key }
        } else {
            Write-SubStep "$key : not yet complete (skipping)"
        }
    }
}

# Wait for any destroy jobs
Get-Job | Where-Object { $_.Name -like "destroy-*" -and $_.State -eq "Running" } | Wait-Job -Timeout 300 | Out-Null
Get-Job | Where-Object { $_.Name -like "destroy-*" } | Remove-Job -Force

} # end try
finally {
    Write-Step "Closing storage firewall..."
    Close-StorageFirewall -StorageAccount $storageAccount -ResourceGroup $resourceGroup
}

# --- Score results ---
if ($alreadyCollected.Count -gt 0) {
    Write-Host ""
    Write-Step "Scoring results..."
    & "$ScriptsDir\Collect-Results.ps1" -ResultsDir $ResultsDir
}
else {
    Write-Host "No results to score." -ForegroundColor Yellow
}

# --- Destroy infra if requested ---
if ($DestroyInfra) {
    Write-Host ""
    Write-Step "Destroying shared infrastructure..."
    Invoke-Terraform -WorkDir $InfraDir -Arguments @("destroy", "-auto-approve") -Description "infra destroy"
}

# --- Summary ---
Write-Host ""
Write-Host "=============================================="  -ForegroundColor Green
Write-Host " Results collected"                             -ForegroundColor Green
Write-Host " VMs: $($alreadyCollected -join ', ')"          -ForegroundColor Green
Write-Host " Results: $ResultsDir"                          -ForegroundColor Green
Write-Host " JSON: $(Join-Path $ResultsDir 'results.json')" -ForegroundColor Green
Write-Host " CSV:  $(Join-Path $ResultsDir 'summary.csv')"  -ForegroundColor Green
Write-Host "=============================================="  -ForegroundColor Green
