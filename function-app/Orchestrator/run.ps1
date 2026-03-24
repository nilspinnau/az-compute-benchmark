param($Context)

$ErrorActionPreference = "Stop"

# Helper: Durable SDK may return strings or already-deserialized objects
function ConvertFrom-DurableData {
    param([object]$Data)
    if ($null -eq $Data) { return $null }
    if ($Data -is [string]) {
        try { return ($Data | ConvertFrom-Json) } catch { return $Data }
    }
    # Already an object — normalize to PSCustomObject
    return ($Data | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}

$config = ConvertFrom-DurableData $Context.Input

# --- Configuration defaults ---
$timestamp = $Context.CurrentUtcDateTime.ToString("yyyyMMddTHHmmssZ")
$instanceSuffix = $Context.InstanceId.Substring(0, 8)
$runId = "bench-${timestamp}-${instanceSuffix}"
$rgName = "rg-bench-ephemeral-${timestamp}-${instanceSuffix}"
$location = if ($config.location) { $config.location } else { "swedencentral" }
$suites = if ($config.benchmarkSuites) { $config.benchmarkSuites } else { "cpu,memory,disk,network,system" }
$githubRef = if ($config.githubRef) { $config.githubRef } else { "main" }
$githubRepoUrl = if ($config.githubRepoUrl) { $config.githubRepoUrl } else { "https://github.com/nilspinnau/az-compute-benchmark" }
$addressSpace = if ($config.addressSpace) { $config.addressSpace } else { "10.0.0.0/24" }
$maxWaitMinutes = if ($config.maxWaitMinutes) { [int]$config.maxWaitMinutes } else { 120 }
$resultsStorageName = $env:RESULTS_STORAGE_ACCOUNT_NAME
$resultsContainerName = $env:RESULTS_CONTAINER_NAME

# Collect VM definitions
$vmDefs = @{}
foreach ($prop in $config.vms.PSObject.Properties) {
    $vmDefs[$prop.Name] = @{
        vmSize = $prop.Value.vmSize
        osDiskType = if ($prop.Value.osDiskType) { $prop.Value.osDiskType } else { "Premium_LRS" }
        osDiskSizeGb = if ($prop.Value.osDiskSizeGb) { [int]$prop.Value.osDiskSizeGb } else { 64 }
    }
}

$vmKeys = @($vmDefs.Keys)
Write-Host "Orchestrating benchmark run: $runId"
Write-Host "  Location: $location"
Write-Host "  Suites: $suites"
Write-Host "  VMs: $($vmKeys -join ', ')"

$orchestrationResult = @{
    runId     = $runId
    status    = "running"
    location  = $location
    suites    = $suites
    vms       = $vmKeys
    startedAt = $Context.CurrentUtcDateTime.ToString('o')
}

try {
    # ══════════════════════════════════════════
    # Step 1: Create ephemeral resource group
    # ══════════════════════════════════════════
    Write-Host "Step 1: Creating ephemeral resource group: $rgName"
    $rgResult = Invoke-DurableActivity -FunctionName 'Activity-CreateResourceGroup' -Input (@{
        resourceGroupName = $rgName
        location          = $location
    } | ConvertTo-Json -Compress)

    # ══════════════════════════════════════════
    # Step 2: Deploy shared infrastructure
    # ══════════════════════════════════════════
    Write-Host "Step 2: Deploying shared infrastructure..."
    $infraResult = Invoke-DurableActivity -FunctionName 'Activity-DeployInfra' -Input (@{
        resourceGroupName = $rgName
        location          = $location
        addressSpace      = $addressSpace
        runId             = $runId
    } | ConvertTo-Json -Compress)

    $infraData = ConvertFrom-DurableData $infraResult

    # ══════════════════════════════════════════
    # Step 3: Fan-out deploy VMs in parallel
    # ══════════════════════════════════════════
    Write-Host "Step 3: Deploying $($vmKeys.Count) VMs in parallel..."
    $deployTasks = @()
    foreach ($vmKey in $vmKeys) {
        $vmDef = $vmDefs[$vmKey]
        $deployInput = @{
            resourceGroupName          = $rgName
            location                   = $location
            subnetId                   = $infraData.subnetId
            storageAccountName         = $infraData.storageAccountName
            storageAccountId           = $infraData.storageAccountId
            containerName              = $infraData.containerName
            userAssignedIdentityId     = $env:VM_IDENTITY_RESOURCE_ID
            userAssignedIdentityClientId = $env:VM_IDENTITY_CLIENT_ID
            runId                      = $runId
            vmName                     = $vmKey
            vmSize                     = $vmDef.vmSize
            osDiskType                 = $vmDef.osDiskType
            osDiskSizeGb               = $vmDef.osDiskSizeGb
            benchmarkSuites            = $suites
            githubRef                  = $githubRef
            githubRepoUrl              = $githubRepoUrl
        } | ConvertTo-Json -Compress

        $deployTasks += Invoke-DurableActivity -FunctionName 'Activity-DeployVM' -Input $deployInput -NoWait
    }

    $vmResults = Wait-DurableTask -Task $deployTasks
    Write-Host "All VMs deployed."

    # Track which VMs deployed successfully
    $deployedVms = @()
    $vmErrors = @{}
    foreach ($result in @($vmResults)) {
        $vmData = ConvertFrom-DurableData $result
        if ($vmData.status -eq "success") {
            $deployedVms += $vmData.vmName
        }
        else {
            Write-Host "WARNING: VM $($vmData.vmName) deployment failed: $($vmData.error)"
            $vmErrors[$vmData.vmName] = $vmData.error
        }
    }

    if ($deployedVms.Count -eq 0) {
        $orchestrationResult.vmErrors = $vmErrors
        throw "No VMs deployed successfully. Aborting."
    }

    # ══════════════════════════════════════════
    # Step 4: Poll for benchmark completion
    # ══════════════════════════════════════════
    Write-Host "Step 4: Polling for benchmark completion (max ${maxWaitMinutes}m)..."
    $pending = [System.Collections.Generic.List[string]]::new()
    foreach ($vm in $deployedVms) { $pending.Add($vm) }
    $completedVms = @()
    $pollIntervalSeconds = 60
    $pollStartTime = $Context.CurrentUtcDateTime
    $pollCount = 0

    while ($pending.Count -gt 0 -and ($Context.CurrentUtcDateTime - $pollStartTime).TotalMinutes -lt $maxWaitMinutes) {
        # Wait using Durable Timer (doesn't consume resources while waiting)
        Start-DurableTimer -Duration (New-TimeSpan -Seconds $pollIntervalSeconds)

        $pollCount++

        # Check all pending VMs
        $checkTasks = @()
        foreach ($vm in @($pending)) {
            $checkInput = @{
                storageAccountName = $infraData.storageAccountName
                containerName      = $infraData.containerName
                vmName             = $vm
            } | ConvertTo-Json -Compress

            $checkTasks += Invoke-DurableActivity -FunctionName 'Activity-PollCompletion' -Input $checkInput -NoWait
        }

        $checkResults = Wait-DurableTask -Task $checkTasks

        foreach ($result in @($checkResults)) {
            $checkData = ConvertFrom-DurableData $result
            if ($checkData.completed) {
                Write-Host "  VM $($checkData.vmName): benchmark complete"
                $pending.Remove($checkData.vmName) | Out-Null
                $completedVms += $checkData.vmName
            }
        }

        if ($pending.Count -gt 0 -and ($pollCount % 5 -eq 0)) {
            $elapsed = [math]::Round($pollCount * $pollIntervalSeconds / 60, 1)
            Write-Host "  Still waiting (${elapsed}m): $($pending -join ', ')"
        }
    }

    if ($pending.Count -gt 0) {
        Write-Host "WARNING: Benchmarks did not complete for: $($pending -join ', ')"
    }

    # ══════════════════════════════════════════
    # Step 5: Collect and score results
    # ══════════════════════════════════════════
    Write-Host "Step 5: Collecting and scoring results for $($completedVms.Count) VMs..."

    if ($completedVms.Count -gt 0) {
        $collectResult = Invoke-DurableActivity -FunctionName 'Activity-CollectResults' -Input (@{
            storageAccountName        = $infraData.storageAccountName
            containerName             = $infraData.containerName
            vmNames                   = $completedVms
            runId                     = $runId
            resultsStorageAccountName = $resultsStorageName
            resultsContainerName      = $resultsContainerName
        } | ConvertTo-Json -Compress)

        $scoredResults = ConvertFrom-DurableData $collectResult
    }
    else {
        $scoredResults = @{ error = "No VMs completed benchmarks" }
    }

    # ══════════════════════════════════════════
    # Step 6: Cleanup ephemeral resources
    # ══════════════════════════════════════════
    Write-Host "Step 6: Cleaning up ephemeral resource group: $rgName"
    Invoke-DurableActivity -FunctionName 'Activity-Cleanup' -Input (@{
        resourceGroupName = $rgName
    } | ConvertTo-Json -Compress)

    # ══════════════════════════════════════════
    # Build final result
    # ══════════════════════════════════════════
    $orchestrationResult.status = "completed"
    $orchestrationResult.completedAt = $Context.CurrentUtcDateTime.ToString('o')
    $orchestrationResult.completedVms = $completedVms
    $orchestrationResult.timedOutVms = @($pending)
    $orchestrationResult.results = $scoredResults
    $orchestrationResult.resultsLocation = @{
        storageAccount = $resultsStorageName
        container      = $resultsContainerName
        path           = "$runId/"
    }
}
catch {
    Write-Host "ERROR in orchestration: $_"
    $orchestrationResult.status = "failed"
    $orchestrationResult.error = $_.ToString()

    # Best-effort cleanup
    $cleanupRg = "rg-bench-ephemeral-${timestamp}-${instanceSuffix}"
    try {
        Write-Host "Attempting cleanup after failure for RG: $cleanupRg"
        Invoke-DurableActivity -FunctionName 'Activity-Cleanup' -Input (@{
            resourceGroupName = $cleanupRg
        } | ConvertTo-Json -Compress)
    }
    catch {
        Write-Host "Cleanup also failed: $_"
        $orchestrationResult.cleanupError = $_.ToString()
    }
}

return $orchestrationResult | ConvertTo-Json -Depth 20 -Compress
