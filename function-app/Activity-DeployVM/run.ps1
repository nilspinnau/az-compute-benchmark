param($InputData)

$ErrorActionPreference = "Stop"

$params = if ($InputData -is [string]) { $InputData | ConvertFrom-Json } else { $InputData }
$rgName = $params.resourceGroupName
$location = $params.location
$subnetId = $params.subnetId
$vmKey = $params.vmName
$vmSize = $params.vmSize
$osDiskType = $params.osDiskType
$osDiskSizeGb = $params.osDiskSizeGb
$storageAccountName = $params.storageAccountName
$storageAccountId = $params.storageAccountId
$containerName = $params.containerName
$userAssignedIdentityId = $params.userAssignedIdentityId
$userAssignedIdentityClientId = $params.userAssignedIdentityClientId
$runId = $params.runId
$suites = $params.benchmarkSuites
$githubRef = $params.githubRef
$githubRepoUrl = $params.githubRepoUrl

$vmName = "vm-bench-$vmKey"
$nicName = "nic-bench-$vmKey"
$adminUsername = "azureadmin"

Write-Host "Deploying VM: $vmName ($vmSize)..."

try {
    # --- Generate cloud-init ---
    $cloudInit = @"
#cloud-config

package_update: true
package_upgrade: false

write_files:
  - path: /etc/benchmark-config
    content: |
      STORAGE_ACCOUNT=$storageAccountName
      CONTAINER_NAME=$containerName
      MI_CLIENT_ID=$userAssignedIdentityClientId
      RUN_ID=$runId
      GITHUB_REPO_URL=$githubRepoUrl
      GITHUB_REF=$githubRef
      BENCHMARK_SUITES=$suites
    permissions: '0644'

runcmd:
  - mkdir -p /home/$adminUsername/benchmark
  - chown ${adminUsername}:users /home/$adminUsername/benchmark
  - zypper -n install -y fio || true
  - zypper -n install -y iperf || zypper -n install -y iperf3 || true
  - zypper -n install -y gcc gcc-c++ || true
  - zypper -n install -y make || true
  - zypper -n install -y bc || true
  - zypper -n install -y git-core || true
  - zypper -n install -y numactl || true
  - zypper -n install -y jq || true
  - zypper -n install -y autoconf automake libtool || true
  - zypper -n install -y pkg-config || true
  - - /bin/bash
    - -c
    - |
      set -euo pipefail
      if ! command -v sysbench &>/dev/null; then
        cd /tmp
        curl -sL https://github.com/akopytov/sysbench/archive/refs/tags/1.0.20.tar.gz -o sysbench.tar.gz
        tar -xzf sysbench.tar.gz
        cd sysbench-1.0.20
        ./autogen.sh
        ./configure --without-mysql
        make -j`$(nproc)
        make install
        ldconfig
        cd /tmp && rm -rf sysbench-1.0.20 sysbench.tar.gz
      fi
  - - /bin/bash
    - -c
    - |
      set -uo pipefail
      exec > >(tee -a /var/log/benchmark-entrypoint.log) 2>&1
      source /etc/benchmark-config
      BENCH_DIR="/home/$adminUsername/benchmark"
      echo "=== Downloading scripts from GitHub ==="
      TARBALL_URL="`$GITHUB_REPO_URL/archive/refs/heads/`$GITHUB_REF.tar.gz"
      TEMP_DIR=`$(mktemp -d)
      curl -sL "`$TARBALL_URL" -o "`$TEMP_DIR/repo.tar.gz"
      tar -xzf "`$TEMP_DIR/repo.tar.gz" -C "`$TEMP_DIR"
      EXTRACTED_DIR=`$(find "`$TEMP_DIR" -maxdepth 1 -type d -name '*-*' | head -1)
      SCRIPTS_DIR="`$BENCH_DIR/scripts"
      mkdir -p "`$SCRIPTS_DIR"
      cp -r "`$EXTRACTED_DIR/scripts/"* "`$SCRIPTS_DIR/"
      chmod -R +x "`$SCRIPTS_DIR/"
      rm -rf "`$TEMP_DIR"
      echo "=== Running benchmarks (suites: `$BENCHMARK_SUITES) ==="
      cd "`$BENCH_DIR"
      bash "`$SCRIPTS_DIR/run-benchmarks.sh" --suites "`$BENCHMARK_SUITES" || true
      echo "=== Uploading results ==="
      VM_NAME=`$(hostname)
      BLOB_URL="https://`$STORAGE_ACCOUNT.blob.core.windows.net/`$CONTAINER_NAME"
      # Get bearer token from IMDS using the user-assigned managed identity
      get_token() {
        curl -s -H "Metadata:true" "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com/&client_id=`$MI_CLIENT_ID" | jq -r '.access_token'
      }
      TOKEN=`$(get_token)
      if [ -z "`$TOKEN" ] || [ "`$TOKEN" = "null" ]; then
        echo "ERROR: Failed to get bearer token from IMDS"
        exit 1
      fi
      RESULT_DIR=`$(find "`$BENCH_DIR/results" -maxdepth 1 -type d | sort | tail -1)
      if [ "`$RESULT_DIR" != "`$BENCH_DIR/results" ] && [ -n "`$RESULT_DIR" ]; then
        TAR_FILE="/tmp/benchmark-results-`${VM_NAME}.tar.gz"
        tar -czf "`$TAR_FILE" -C "`$RESULT_DIR" .
        FILE_SIZE=`$(stat -c%s "`$TAR_FILE")
        echo "Tar file size: `$FILE_SIZE bytes"
        HTTP_CODE=`$(curl -s -w "%{http_code}" -o /dev/null \
          -X PUT \
          -H "Authorization: Bearer `$TOKEN" \
          -H "x-ms-blob-type: BlockBlob" \
          -H "x-ms-version: 2020-10-02" \
          -H "Content-Type: application/gzip" \
          -H "Content-Length: `$FILE_SIZE" \
          --data-binary "@`$TAR_FILE" \
          "`${BLOB_URL}/`${VM_NAME}/results.tar.gz")
        echo "Results upload HTTP: `$HTTP_CODE"
        rm -f "`$TAR_FILE"
      else
        echo "WARNING: No result directory found"
      fi
      echo "=== Writing DONE marker ==="
      # Refresh token in case the benchmarks took a while
      TOKEN=`$(get_token)
      MARKER="{\"hostname\":\"`$VM_NAME\",\"completed\":\"`$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"benchmark_exit_code\":0}"
      HTTP_CODE=`$(curl -s -w "%{http_code}" -o /dev/null \
        -X PUT \
        -H "Authorization: Bearer `$TOKEN" \
        -H "x-ms-blob-type: BlockBlob" \
        -H "x-ms-version: 2020-10-02" \
        -H "Content-Type: application/json" \
        --data "`$MARKER" \
        "`${BLOB_URL}/`${VM_NAME}/DONE")
      echo "DONE marker HTTP: `$HTTP_CODE"
      echo "=== Benchmark entrypoint complete ==="
"@

    # Convert CRLF to LF (Windows PowerShell here-strings use CRLF, cloud-init needs LF)
    $cloudInit = $cloudInit -replace "`r`n", "`n"

    # --- Create NIC ---
    Write-Host "  Creating NIC: $nicName"
    $nic = New-AzNetworkInterface `
        -Name $nicName `
        -ResourceGroupName $rgName `
        -Location $location `
        -SubnetId $subnetId `
        -EnableAcceleratedNetworking

    # --- Create VM credentials (password auth; VMs are ephemeral + NSG blocks all inbound) ---
    $password = -join ((65..90) + (97..122) + (48..57) + (33, 35, 36, 37, 38, 42, 43) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($adminUsername, $securePassword)

    # --- Create VM config ---
    $vmConfig = New-AzVMConfig `
        -VMName $vmName `
        -VMSize $vmSize `
        -IdentityType UserAssigned `
        -IdentityId @($userAssignedIdentityId)

    $vmConfig = Set-AzVMOperatingSystem `
        -VM $vmConfig `
        -Linux `
        -ComputerName $vmName `
        -Credential $credential `
        -CustomData $cloudInit

    $vmConfig = Set-AzVMSourceImage `
        -VM $vmConfig `
        -PublisherName "SUSE" `
        -Offer "sles-sap-15-sp5" `
        -Skus "gen2" `
        -Version "latest"

    $vmConfig = Set-AzVMOSDisk `
        -VM $vmConfig `
        -Name "osdisk-bench-$vmKey" `
        -CreateOption "FromImage" `
        -StorageAccountType $osDiskType `
        -DiskSizeInGB $osDiskSizeGb `
        -Caching "ReadWrite"

    $vmConfig = Add-AzVMNetworkInterface `
        -VM $vmConfig `
        -Id $nic.Id `
        -Primary

    $vmConfig = Set-AzVMBootDiagnostic `
        -VM $vmConfig `
        -Disable

    # --- Deploy VM ---
    Write-Host "  Creating VM: $vmName"
    $vm = New-AzVM `
        -ResourceGroupName $rgName `
        -Location $location `
        -VM $vmConfig `
        -Tag @{ environment = "benchmark"; vm_size = $vmSize; ephemeral = "true" }

    $vmResource = Get-AzVM -ResourceGroupName $rgName -Name $vmName

    Write-Host "  VM $vmName deployed successfully."

    return @{
        status    = "success"
        vmName    = $vmKey
        vmId      = $vmResource.Id
        privateIp = $nic.IpConfigurations[0].PrivateIpAddress
    } | ConvertTo-Json -Compress
}
catch {
    Write-Host "ERROR deploying VM $vmName : $_"
    return @{
        status = "failed"
        vmName = $vmKey
        error  = $_.ToString()
    } | ConvertTo-Json -Compress
}
