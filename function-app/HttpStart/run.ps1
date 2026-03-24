param($Request, $TriggerMetadata)

# Normalize body to PSCustomObject (Azure Functions may deserialize as hashtable)
$config = $Request.Body | ConvertTo-Json -Depth 10 | ConvertFrom-Json

# --- Validate required fields ---

if (-not $config) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [System.Net.HttpStatusCode]::BadRequest
        Body       = '{"error": "Request body is required. Send a JSON object with vms, location, etc."}'
    })
    return
}

if (-not $config.vms -or ($config.vms.PSObject.Properties | Measure-Object).Count -eq 0) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [System.Net.HttpStatusCode]::BadRequest
        Body       = '{"error": "vms is required and must contain at least one VM definition. Example: {\"vms\": {\"e8asv5\": {\"vmSize\": \"Standard_E8as_v5\"}}}"}'
    })
    return
}

# Validate each VM entry has vmSize
foreach ($prop in $config.vms.PSObject.Properties) {
    if (-not $prop.Value.vmSize) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [System.Net.HttpStatusCode]::BadRequest
            Body       = "{`"error`": `"VM '$($prop.Name)' is missing required field 'vmSize'`"}"
        })
        return
    }

    # Validate VM size format
    if ($prop.Value.vmSize -notmatch '^Standard_[A-Za-z0-9_]+$') {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [System.Net.HttpStatusCode]::BadRequest
            Body       = "{`"error`": `"VM '$($prop.Name)' has invalid vmSize '$($prop.Value.vmSize)'. Must match 'Standard_*' pattern.`"}"
        })
        return
    }
}

# Validate optional fields
if ($config.benchmarkSuites) {
    $validSuites = @("cpu", "memory", "disk", "network", "system")
    $requestedSuites = $config.benchmarkSuites -split ','
    foreach ($suite in $requestedSuites) {
        $suite = $suite.Trim()
        if ($suite -notin $validSuites) {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [System.Net.HttpStatusCode]::BadRequest
                Body       = "{`"error`": `"Invalid benchmark suite '$suite'. Valid suites: $($validSuites -join ', ')`"}"
            })
            return
        }
    }
}

if ($config.location -and $config.location -notmatch '^[a-z0-9]+$') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [System.Net.HttpStatusCode]::BadRequest
        Body       = '{"error": "Invalid location format. Use Azure region names like swedencentral, germanywestcentral, etc."}'
    })
    return
}

# Validate VM key names (used in resource names, must be safe)
foreach ($prop in $config.vms.PSObject.Properties) {
    if ($prop.Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,19}$') {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [System.Net.HttpStatusCode]::BadRequest
            Body       = "{`"error`": `"VM key '$($prop.Name)' is invalid. Use alphanumeric characters, hyphens, underscores only (max 20 chars).`"}"
        })
        return
    }
}

# Validate githubRepoUrl if provided (must be a GitHub HTTPS URL)
if ($config.githubRepoUrl) {
    if ($config.githubRepoUrl -notmatch '^https://github\.com/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$') {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [System.Net.HttpStatusCode]::BadRequest
            Body       = '{"error": "githubRepoUrl must be a valid GitHub HTTPS URL (https://github.com/owner/repo)"}'
        })
        return
    }
}

# Validate githubRef if provided (must be safe branch/tag name)
if ($config.githubRef -and $config.githubRef -notmatch '^[a-zA-Z0-9._/-]+$') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [System.Net.HttpStatusCode]::BadRequest
        Body       = '{"error": "githubRef must contain only alphanumeric characters, dots, slashes, and hyphens"}'
    })
    return
}

# Validate maxWaitMinutes if provided
if ($config.maxWaitMinutes) {
    $waitMin = 0
    if (-not [int]::TryParse($config.maxWaitMinutes, [ref]$waitMin) -or $waitMin -lt 1 -or $waitMin -gt 240) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [System.Net.HttpStatusCode]::BadRequest
            Body       = '{"error": "maxWaitMinutes must be an integer between 1 and 240"}'
        })
        return
    }
}

# --- Start orchestration ---

$instanceId = Start-DurableOrchestration -FunctionName 'Orchestrator' -Input ($config | ConvertTo-Json -Depth 10 -Compress)

Write-Host "Started orchestration with ID = '$instanceId'."

$mgmtUrls = New-DurableOrchestrationCheckStatusResponse -Request $Request -InstanceId $instanceId
Push-OutputBinding -Name Response -Value $mgmtUrls
