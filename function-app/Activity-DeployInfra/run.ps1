param($InputData)

$ErrorActionPreference = "Stop"

$params = if ($InputData -is [string]) { $InputData | ConvertFrom-Json } else { $InputData }
$rgName = $params.resourceGroupName
$location = $params.location
$addressSpace = $params.addressSpace
$runId = $params.runId
$tags = @{ environment = "benchmark"; managed_by = "function-app"; run_id = $runId; ephemeral = "true" }

# Generate unique suffix for storage account name
$storageSuffix = -join ((97..122) + (48..57) | Get-Random -Count 8 | ForEach-Object { [char]$_ })

Write-Host "Deploying shared infrastructure in $rgName..."

# --- VNet ---
Write-Host "  Creating VNet..."
$vnet = New-AzVirtualNetwork `
    -Name "vnet-benchmark" `
    -ResourceGroupName $rgName `
    -Location $location `
    -AddressPrefix $addressSpace `
    -Tag $tags

# --- Subnets ---
Write-Host "  Creating subnets..."
# Parse CIDR to compute subnets
$cidrParts = $addressSpace -split '/'
$baseIp = $cidrParts[0]
$mask = [int]$cidrParts[1]
$octets = $baseIp -split '\.'
# VM subnet: first half, PE subnet: second half (mask + 1)
$subnetMask = $mask + 1
$vmSubnetPrefix = "${baseIp}/${subnetMask}"
# For the second subnet, flip the bit at position (subnetMask-1) in the IP
$ipInt = ([int]$octets[0] -shl 24) + ([int]$octets[1] -shl 16) + ([int]$octets[2] -shl 8) + [int]$octets[3]
$halfSize = [math]::Pow(2, 32 - $subnetMask)
$peIpInt = $ipInt + [int]$halfSize
$peOctet0 = ($peIpInt -shr 24) -band 0xFF
$peOctet1 = ($peIpInt -shr 16) -band 0xFF
$peOctet2 = ($peIpInt -shr 8) -band 0xFF
$peOctet3 = $peIpInt -band 0xFF
$peSubnetPrefix = "${peOctet0}.${peOctet1}.${peOctet2}.${peOctet3}/${subnetMask}"

$vnet | Add-AzVirtualNetworkSubnetConfig `
    -Name "snet-benchmark" `
    -AddressPrefix $vmSubnetPrefix | Out-Null

$vnet | Add-AzVirtualNetworkSubnetConfig `
    -Name "snet-privateendpoints" `
    -AddressPrefix $peSubnetPrefix | Out-Null

$vnet | Set-AzVirtualNetwork | Out-Null
$vnet = Get-AzVirtualNetwork -Name "vnet-benchmark" -ResourceGroupName $rgName
$vmSubnet = $vnet.Subnets | Where-Object { $_.Name -eq "snet-benchmark" }
$peSubnet = $vnet.Subnets | Where-Object { $_.Name -eq "snet-privateendpoints" }

# --- NAT Gateway ---
Write-Host "  Creating NAT gateway..."
$pip = New-AzPublicIpAddress `
    -Name "pip-nat-benchmark" `
    -ResourceGroupName $rgName `
    -Location $location `
    -AllocationMethod "Static" `
    -Sku "Standard" `
    -Tag $tags `
    -Force

$nat = New-AzNatGateway `
    -Name "nat-benchmark" `
    -ResourceGroupName $rgName `
    -Location $location `
    -Sku "Standard" `
    -PublicIpAddress $pip `
    -IdleTimeoutInMinutes 10

# Associate NAT gateway with VM subnet
$vmSubnet.NatGateway = $nat
$vnet | Set-AzVirtualNetwork | Out-Null

# --- NSG (deny all inbound by default, VMs only need outbound) ---
Write-Host "  Creating NSG..."
$nsgRules = @(
    New-AzNetworkSecurityRuleConfig `
        -Name "DenyAllInbound" `
        -Protocol "*" `
        -Direction Inbound `
        -Priority 4096 `
        -SourceAddressPrefix "*" `
        -SourcePortRange "*" `
        -DestinationAddressPrefix "*" `
        -DestinationPortRange "*" `
        -Access Deny
)

$nsg = New-AzNetworkSecurityGroup `
    -Name "nsg-benchmark" `
    -ResourceGroupName $rgName `
    -Location $location `
    -SecurityRules $nsgRules `
    -Tag $tags

# Associate NSG with VM subnet
$vnet = Get-AzVirtualNetwork -Name "vnet-benchmark" -ResourceGroupName $rgName
$vmSubnet = $vnet.Subnets | Where-Object { $_.Name -eq "snet-benchmark" }
$vmSubnet.NetworkSecurityGroup = $nsg
$vnet | Set-AzVirtualNetwork | Out-Null

# --- Storage account (for benchmark results upload from VMs) ---
Write-Host "  Creating storage account..."
$storageAccountName = "stbench${storageSuffix}"
$storageAccount = New-AzStorageAccount `
    -Name $storageAccountName `
    -ResourceGroupName $rgName `
    -Location $location `
    -SkuName "Standard_LRS" `
    -Kind "StorageV2" `
    -AllowBlobPublicAccess $false `
    -EnableHttpsTrafficOnly $true `
    -MinimumTlsVersion "TLS1_2" `
    -Tag $tags

# Create container using Azure AD auth (function app identity has subscription-scoped Storage Blob Data Contributor)
Write-Host "  Creating container..."
$ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
# Retry container creation to allow RBAC propagation on new storage account
$retries = 0
while ($retries -lt 6) {
    try {
        New-AzStorageContainer -Name "benchmark-results" -Context $ctx | Out-Null
        break
    } catch {
        $retries++
        if ($retries -ge 6) { throw }
        Write-Host "    Waiting for RBAC propagation... (attempt $retries/6)"
        Start-Sleep -Seconds 10
    }
}

# --- Private DNS zone + Private endpoint for blob ---
# NOTE: Intentionally NOT creating PE/DNS for ephemeral storage.
# VMs access via public endpoint (NAT gateway).
# Function App polls via public endpoint (no privatelink CNAME means
# the orchestrator's private DNS zone won't intercept resolution).

# Refresh subnet reference
$vnet = Get-AzVirtualNetwork -Name "vnet-benchmark" -ResourceGroupName $rgName
$vmSubnet = $vnet.Subnets | Where-Object { $_.Name -eq "snet-benchmark" }

Write-Host "Infrastructure deployment complete."

return @{
    subnetId           = $vmSubnet.Id
    storageAccountName = $storageAccountName
    storageAccountId   = $storageAccount.Id
    containerName      = "benchmark-results"
    vnetId             = $vnet.Id
} | ConvertTo-Json -Compress
