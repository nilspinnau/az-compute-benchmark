param($InputData)

$ErrorActionPreference = "Stop"

$params = if ($InputData -is [string]) { $InputData | ConvertFrom-Json } else { $InputData }
$storageAccountName = $params.storageAccountName
$containerName = $params.containerName
$vmName = $params.vmName
$blobName = "vm-bench-${vmName}/DONE"

Write-Host "Checking completion for VM: $vmName"

try {
    $token = (Get-AzAccessToken -ResourceUrl "https://storage.azure.com/").Token
    $headers = @{
        "Authorization"  = "Bearer $token"
        "x-ms-version"   = "2020-10-02"
    }

    $blobUrl = "https://${storageAccountName}.blob.core.windows.net/${containerName}/${blobName}"
    try {
        $response = Invoke-RestMethod -Uri $blobUrl -Method HEAD -Headers $headers -ErrorAction Stop
        Write-Host "  VM $vmName : DONE marker found"
        return @{
            vmName    = $vmName
            completed = $true
        } | ConvertTo-Json -Compress
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 404) {
            Write-Host "  VM $vmName : not yet complete"
            return @{
                vmName    = $vmName
                completed = $false
            } | ConvertTo-Json -Compress
        }
        throw
    }
}
catch {
    Write-Host "  Error checking $vmName : $_"
    return @{
        vmName    = $vmName
        completed = $false
        error     = $_.ToString()
    } | ConvertTo-Json -Compress
}
