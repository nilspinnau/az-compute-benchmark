<#
.SYNOPSIS
    Publish the Function App code to Azure.

.DESCRIPTION
    Publishes the function-app/ directory to the Azure Function App
    and retrieves the function key for triggering benchmarks.

.PARAMETER FunctionAppName
    Name of the deployed Function App (from Terraform output).

.PARAMETER ResourceGroupName
    Name of the resource group containing the Function App.

.EXAMPLE
    .\Publish-FunctionApp.ps1 -FunctionAppName "func-bench-sapbench" -ResourceGroupName "rg-sap-benchmark-orchestrator"
#>
param(
    [Parameter(Mandatory)]
    [string]$FunctionAppName,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName
)

$ErrorActionPreference = "Stop"
$ProjectDir = Split-Path -Parent $PSScriptRoot
$FuncAppDir = Join-Path $ProjectDir "function-app"

Write-Host "Publishing Function App: $FunctionAppName" -ForegroundColor Cyan

# Publish using Azure Functions Core Tools
Push-Location $FuncAppDir
try {
    func azure functionapp publish $FunctionAppName --powershell
}
finally {
    Pop-Location
}

Write-Host ""
Write-Host "Retrieving function key..." -ForegroundColor Cyan

# Retrieve function key for HttpStart
$keysJson = az functionapp function keys list `
    --resource-group $ResourceGroupName `
    --name $FunctionAppName `
    --function-name "HttpStart" 2>$null

if ($keysJson) {
    $keys = $keysJson | ConvertFrom-Json
    $functionKey = $keys.default
    $baseUrl = "https://${FunctionAppName}.azurewebsites.net"

    Write-Host ""
    Write-Host "=============================================="  -ForegroundColor Green
    Write-Host " Function App published successfully"           -ForegroundColor Green
    Write-Host "=============================================="  -ForegroundColor Green
    Write-Host ""
    Write-Host "Function App URL: $baseUrl"
    Write-Host ""
    Write-Host "To trigger a benchmark run:" -ForegroundColor Cyan
    Write-Host @"

curl -X POST '$baseUrl/api/HttpStart?code=$functionKey' \
  -H 'Content-Type: application/json' \
  -d '{
    "location": "swedencentral",
    "benchmarkSuites": "cpu,memory,disk,network,system",
    "githubRef": "main",
    "vms": {
      "e8asv5": { "vmSize": "Standard_E8as_v5" },
      "e8sv5":  { "vmSize": "Standard_E8s_v5" },
      "e8asv6": { "vmSize": "Standard_E8as_v6" }
    }
  }'
"@
}
else {
    Write-Host "WARNING: Could not retrieve function key. You may need to get it from the Azure portal." -ForegroundColor Yellow
}
