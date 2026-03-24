param($InputData)

$ErrorActionPreference = "Stop"

$params = if ($InputData -is [string]) { $InputData | ConvertFrom-Json } else { $InputData }

Write-Host "Creating resource group: $($params.resourceGroupName) in $($params.location)"

$rg = New-AzResourceGroup `
    -Name $params.resourceGroupName `
    -Location $params.location `
    -Tag @{ environment = "benchmark"; managed_by = "function-app"; ephemeral = "true" } `
    -Force

Write-Host "Resource group created: $($rg.ResourceGroupName)"

return @{
    resourceGroupName = $rg.ResourceGroupName
    location          = $rg.Location
} | ConvertTo-Json -Compress
