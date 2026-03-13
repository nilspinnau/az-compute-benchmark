<#
.SYNOPSIS
    Orchestrate VM benchmarks: deploy infra, deploy all VMs in parallel,
    poll for completion, download results & destroy each VM as it finishes.

.DESCRIPTION
    Uses a split Terraform layout:
      - infra/  : shared resources (RG, VNet, storage) - deployed once
      - vm/     : single VM (NIC, VM, role assignment) - one state file per VM

    All VMs are deployed simultaneously via background processes.
    A polling loop checks for DONE markers in blob storage. As soon as a
    VM finishes, its results are downloaded and the VM is destroyed - freeing
    quota for other workloads.

.PARAMETER Suites
    Comma-separated benchmark suites. Default: cpu,memory,disk,network,system

.PARAMETER SkipDestroy
    If set, skips the final infrastructure destroy.

.PARAMETER GithubRef
    Git branch/tag/commit for benchmark scripts. Default: main

.PARAMETER MaxWaitMinutes
    Maximum minutes to wait for benchmarks. Default: 120

.EXAMPLE
    .\Run-Benchmark-All.ps1
    .\Run-Benchmark-All.ps1 -Suites "cpu,memory"
    .\Run-Benchmark-All.ps1 -SkipDestroy
#>
param(
    [string]$Suites = "cpu,memory,disk,network,system",
    [string]$GithubRef = "main",
    [int]$MaxWaitMinutes = 120,
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
# Add or remove entries here. Each key becomes the VM name suffix and state file name.
$allVms = [ordered]@{
    "e64asv5" = @{ vm_size = "Standard_E64as_v5" }
    "e64sv5"  = @{ vm_size = "Standard_E64s_v5" }
    "e64asv6" = @{ vm_size = "Standard_E64as_v6" }
}

Write-Host "=============================================="  -ForegroundColor Cyan
Write-Host " Azure VM Benchmark"                            -ForegroundColor Cyan
Write-Host " VMs: $($allVms.Keys -join ', ')"               -ForegroundColor Cyan
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

function Get-TerraformVarArgs {
    param(
        [string]$VmKey,
        [string]$VmSize,
        [hashtable]$InfraOutputs
    )
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

Write-SubStep "Resource group: $($infraOutputs.resource_group_name)"
Write-SubStep "Storage account: $($infraOutputs.storage_account_name)"

# Init vm/ module once
Write-Step "Initializing VM module..."
Invoke-Terraform -WorkDir $VmDir -Arguments @("init", "-input=false") -Description "vm init"

# --- 2. Deploy all VMs in parallel ---
Write-Step "Deploying all VMs in parallel..."
$deployJobs = @{}

foreach ($key in $allVms.Keys) {
    $vmSize = $allVms[$key].vm_size
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

# Wait for all deploy jobs to finish
Write-Step "Waiting for all deployments to complete..."
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

if ($deployedKeys.Count -eq 0) {
    Write-Host "ERROR: No VMs deployed successfully. Aborting." -ForegroundColor Red
    exit 1
}

$failedKeys = @($allVms.Keys | Where-Object { $_ -notin $deployedKeys })
if ($failedKeys.Count -gt 0) {
    Write-Host "Failed initial deploy: $($failedKeys -join ', ')" -ForegroundColor Yellow
    Write-Host "These will be retried after active VMs complete and are destroyed." -ForegroundColor Yellow
}

Write-SubStep "Successfully deployed: $($deployedKeys -join ', ')"

# --- Helper: Poll a set of VMs for DONE, download results, destroy ---
function Poll-And-Collect {
    param(
        [string[]]$VmKeys,
        [hashtable]$InfraOutputs,
        [hashtable]$AllVms,
        [int]$MaxMinutes
    )

    $pending = New-Object System.Collections.Generic.List[string]
    foreach ($k in $VmKeys) { $pending.Add($k) }
    $collected = @()
    $maxAttempts = $MaxMinutes * 2  # every 30s
    $attempt = 0

    while ($pending.Count -gt 0 -and $attempt -lt $maxAttempts) {
        $attempt++
        Start-Sleep -Seconds 30

        foreach ($key in @($pending)) {
            $blobName = "vm-bench-${key}/DONE"
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            $exists = az storage blob exists `
                --account-name $InfraOutputs.storage_account_name `
                --container-name $InfraOutputs.storage_container_name `
                --name $blobName `
                --auth-mode login `
                --query "exists" -o tsv 2>$null
            $ErrorActionPreference = $prevEAP

            if ($exists -eq "true") {
                Write-SubStep "$key : benchmark complete - downloading results, destroying VM"
                $pending.Remove($key) | Out-Null
                $collected += $key

                # Download results immediately
                Download-Results `
                    -StorageAccount $InfraOutputs.storage_account_name `
                    -Container $InfraOutputs.storage_container_name `
                    -VmKey $key

                # Destroy VM in background so polling continues
                $stateFile = Join-Path $StatesDir "$key.tfstate"
                $logFile = Join-Path $StatesDir "$key-destroy.log"
                $varArgs = Get-TerraformVarArgs -VmKey $key -VmSize $AllVms[$key].vm_size -InfraOutputs $InfraOutputs
                Start-Job -Name "destroy-$key" -ScriptBlock {
                    param($vmDir, $stateFile, $varArgs, $logFile)
                    Set-Location $vmDir
                    $allArgs = @("destroy", "-auto-approve", "-state", $stateFile, "-input=false") + $varArgs
                    $output = & terraform @allArgs 2>&1
                    $output | Tee-Object -FilePath $logFile
                } -ArgumentList $VmDir, $stateFile, $varArgs, $logFile | Out-Null
            }
        }

        if ($pending.Count -gt 0 -and ($attempt % 4 -eq 0)) {
            $elapsed = [math]::Round($attempt * 30 / 60, 1)
            Write-SubStep "Waiting (${elapsed}m): $($pending -join ', ')"
        }
    }

    # Handle timed-out VMs
    if ($pending.Count -gt 0) {
        Write-Host "WARNING: Benchmarks did not complete for: $($pending -join ', ')" -ForegroundColor Yellow
        foreach ($key in $pending) {
            Write-SubStep "Destroying timed-out VM: $key"
            $stateFile = Join-Path $StatesDir "$key.tfstate"
            $varArgs = Get-TerraformVarArgs -VmKey $key -VmSize $AllVms[$key].vm_size -InfraOutputs $InfraOutputs
            Start-Job -Name "destroy-$key" -ScriptBlock {
                param($vmDir, $stateFile, $varArgs)
                Set-Location $vmDir
                $allArgs = @("destroy", "-auto-approve", "-state", $stateFile, "-input=false") + $varArgs
                $output = & terraform @allArgs 2>&1
                $output
            } -ArgumentList $VmDir, $stateFile, $varArgs | Out-Null
        }
    }

    # Wait for all destroy jobs from this round
    Get-Job | Where-Object { $_.Name -like "destroy-*" -and $_.State -eq "Running" } | Wait-Job -Timeout 300 | Out-Null
    Get-Job | Where-Object { $_.Name -like "destroy-*" } | Remove-Job -Force

    return $collected
}

# --- 3. Poll for completion - download and destroy each VM as it finishes ---
Write-Step "Polling for benchmark completion (max $MaxWaitMinutes min)..."
$completed = @(Poll-And-Collect -VmKeys $deployedKeys -InfraOutputs $infraOutputs -AllVms $allVms -MaxMinutes $MaxWaitMinutes)

# --- 3b. Retry failed VMs sequentially (freed quota) ---
if ($failedKeys.Count -gt 0 -and $completed.Count -gt 0) {
    Write-Step "Retrying failed VMs sequentially (quota freed)..."
    foreach ($key in $failedKeys) {
        $vmSize = $allVms[$key].vm_size
        $stateFile = Join-Path $StatesDir "$key.tfstate"
        $logFile = Join-Path $StatesDir "$key-deploy.log"
        $varArgs = Get-TerraformVarArgs -VmKey $key -VmSize $vmSize -InfraOutputs $infraOutputs

        Write-SubStep "Deploying $key ($vmSize)..."
        try {
            Invoke-Terraform -WorkDir $VmDir `
                -Arguments (@("apply", "-auto-approve", "-state", $stateFile, "-input=false") + $varArgs) `
                -Description "$key deploy"
            Write-SubStep "$key : deployed successfully"

            Write-SubStep "Polling $key for completion..."
            $retryCompleted = @(Poll-And-Collect -VmKeys @($key) -InfraOutputs $infraOutputs -AllVms $allVms -MaxMinutes $MaxWaitMinutes)
            $completed += $retryCompleted
        }
        catch {
            Write-Host "WARNING: $key retry failed: $_" -ForegroundColor Yellow
        }
    }
}

# --- 4. Collect & score results ---
if ($completed.Count -gt 0) {
    Write-Host ""
    Write-Step "Collecting and scoring results..."
    & "$ScriptsDir\Collect-Results.ps1" -ResultsDir $ResultsDir
}
else {
    Write-Host "No completed benchmarks to score." -ForegroundColor Yellow
}

# --- 5. Final cleanup ---
if (-not $SkipDestroy) {
    Write-Host ""
    Write-Step "Destroying shared infrastructure..."
    Invoke-Terraform -WorkDir $InfraDir -Arguments @("destroy", "-auto-approve") -Description "infra destroy"
}
else {
    Write-Host ""
    Write-Host "Skipping final destroy (-SkipDestroy). Run 'terraform -chdir=infra destroy' manually." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=============================================="  -ForegroundColor Green
Write-Host " Benchmarking complete!"                        -ForegroundColor Green
Write-Host " Completed: $($completed -join ', ')"           -ForegroundColor Green
Write-Host " Results: $ResultsDir"                          -ForegroundColor Green
Write-Host " JSON:    $(Join-Path $ResultsDir 'results.json')" -ForegroundColor Green
Write-Host " CSV:     $(Join-Path $ResultsDir 'summary.csv')"  -ForegroundColor Green
Write-Host "=============================================="  -ForegroundColor Green
