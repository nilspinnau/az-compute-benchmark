param($InputData)

$ErrorActionPreference = "Stop"

$params = if ($InputData -is [string]) { $InputData | ConvertFrom-Json } else { $InputData }
$rgName = $params.resourceGroupName

# Safety check: only delete ephemeral resource groups
if ($rgName -notmatch '^rg-bench-ephemeral-') {
    throw "Safety check failed: refusing to delete resource group '$rgName' (does not match ephemeral naming pattern 'rg-bench-ephemeral-*')"
}

Write-Host "Deleting ephemeral resource group: $rgName"

try {
    Remove-AzResourceGroup -Name $rgName -Force -ErrorAction Stop
    Write-Host "Resource group $rgName deleted."
    return @{ status = "deleted"; resourceGroupName = $rgName } | ConvertTo-Json -Compress
}
catch {
    Write-Host "WARNING: Could not delete resource group $rgName : $_"
    return @{ status = "failed"; resourceGroupName = $rgName; error = $_.ToString() } | ConvertTo-Json -Compress
}
