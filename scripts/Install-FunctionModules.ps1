<#
.SYNOPSIS
    Download required Az PowerShell modules for the Function App.

.DESCRIPTION
    Downloads the Az modules needed by the Function App into the
    function-app/Modules directory. Required because Flex Consumption
    plans don't support managed dependencies.

.EXAMPLE
    .\Install-FunctionModules.ps1
#>

$ErrorActionPreference = "Stop"
$ProjectDir = Split-Path -Parent $PSScriptRoot
$ModulesDir = Join-Path (Join-Path $ProjectDir "function-app") "Modules"

Write-Host "Downloading Az modules to: $ModulesDir" -ForegroundColor Cyan

# Clean existing modules
if (Test-Path $ModulesDir) {
    Remove-Item -Recurse -Force $ModulesDir
}
New-Item -ItemType Directory -Path $ModulesDir -Force | Out-Null

$modules = @(
    "Az.Accounts",
    "Az.Resources",
    "Az.Compute",
    "Az.Network",
    "Az.Storage",
    "Az.PrivateDns"
)

foreach ($mod in $modules) {
    Write-Host "  Downloading $mod..." -ForegroundColor Gray
    Save-Module -Name $mod -Path $ModulesDir -Force -Repository PSGallery
}

Write-Host ""
Write-Host "Modules downloaded successfully." -ForegroundColor Green
Write-Host "These will be bundled with the Function App during publish."
