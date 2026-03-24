param($InputData)

$ErrorActionPreference = "Stop"

$params = if ($InputData -is [string]) { $InputData | ConvertFrom-Json } else { $InputData }
$storageAccountName = $params.storageAccountName
$containerName = $params.containerName
$vmNames = $params.vmNames
$runId = $params.runId
$resultsStorageAccountName = $params.resultsStorageAccountName
$resultsContainerName = $params.resultsContainerName

Write-Host "Collecting results for $($vmNames.Count) VMs..."

$token = (Get-AzAccessToken -ResourceUrl "https://storage.azure.com/").Token
$headers = @{
    "Authorization" = "Bearer $token"
    "x-ms-version"  = "2020-10-02"
}

# ── Metric definitions ──
$MetricDefs = [ordered]@{
    cpu_single_eps       = @{ direction = "+"; category = "cpu";    unit = "events/s";  label = "CPU single-thread" }
    cpu_multi_eps        = @{ direction = "+"; category = "cpu";    unit = "events/s";  label = "CPU multi-thread" }
    cpu_single_lat_ms    = @{ direction = "-"; category = "cpu";    unit = "ms";        label = "CPU single-thread latency" }
    ctx_switch_eps       = @{ direction = "+"; category = "cpu";    unit = "events/s";  label = "Context switching" }
    mutex_total_time_s   = @{ direction = "-"; category = "cpu";    unit = "s";         label = "Mutex contention time" }
    mem_seq_read_mib_s   = @{ direction = "+"; category = "memory"; unit = "MiB/s";     label = "Memory seq read" }
    mem_seq_write_mib_s  = @{ direction = "+"; category = "memory"; unit = "MiB/s";     label = "Memory seq write" }
    mem_rnd_read_mib_s   = @{ direction = "+"; category = "memory"; unit = "MiB/s";     label = "Memory random read" }
    mem_rnd_write_mib_s  = @{ direction = "+"; category = "memory"; unit = "MiB/s";     label = "Memory random write" }
    stream_triad_mb_s    = @{ direction = "+"; category = "memory"; unit = "MB/s";      label = "STREAM Triad" }
    fio_rand_read_iops   = @{ direction = "+"; category = "disk";   unit = "IOPS";      label = "Random read 4K" }
    fio_rand_write_iops  = @{ direction = "+"; category = "disk";   unit = "IOPS";      label = "Random write 4K" }
    fio_mixed_read_iops  = @{ direction = "+"; category = "disk";   unit = "IOPS";      label = "Mixed R/W read" }
    fio_mixed_write_iops = @{ direction = "+"; category = "disk";   unit = "IOPS";      label = "Mixed R/W write" }
    fio_seq_read_mb_s    = @{ direction = "+"; category = "disk";   unit = "MiB/s";     label = "Sequential read 256K" }
    fio_seq_write_mb_s   = @{ direction = "+"; category = "disk";   unit = "MiB/s";     label = "Sequential write 256K" }
    fio_rand_read_p99_us = @{ direction = "-"; category = "disk";   unit = "us";        label = "Random read P99 lat" }
    fio_rand_write_p99_us= @{ direction = "-"; category = "disk";   unit = "us";        label = "Random write P99 lat" }
    unixbench_single     = @{ direction = "+"; category = "system"; unit = "score";     label = "UnixBench single" }
    unixbench_multi      = @{ direction = "+"; category = "system"; unit = "score";     label = "UnixBench multi" }
}

# ── Helper: Download and extract results tar.gz from blob ──
function Get-VmResultFiles {
    param([string]$VmKey, [hashtable]$Headers)

    $blobUrl = "https://${storageAccountName}.blob.core.windows.net/${containerName}/vm-bench-${VmKey}/results.tar.gz"
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "bench-$VmKey-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    $tempTar = "$tempDir.tar.gz"

    try {
        Invoke-RestMethod -Uri $blobUrl -Method GET -Headers $Headers -OutFile $tempTar
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        tar -xzf $tempTar -C $tempDir
        Remove-Item $tempTar -Force
        return $tempDir
    }
    catch {
        Write-Host "WARNING: Could not download results for $VmKey : $_"
        if (Test-Path $tempTar) { Remove-Item $tempTar -Force -ErrorAction SilentlyContinue }
        return $null
    }
}

# ── Helper: Extract sysbench number ──
function Get-SysbenchNumber {
    param([string]$Content, [string]$Pattern)
    $lines = $Content -split "`n"
    foreach ($line in $lines) {
        if ($line -match $Pattern) {
            $parts = $line.Trim() -split '\s+'
            $val = $parts[-1] -replace '[^\d.\-]', ''
            try { return [double]$val } catch { return $null }
        }
    }
    return $null
}

# ── Helper: Extract sysbench MiB/sec ──
function Get-SysbenchMiBSec {
    param([string]$Content)
    if ($Content -match '([\d.]+)\s+MiB/sec') {
        try { return [double]$Matches[1] } catch { return $null }
    }
    return $null
}

# ── Helper: Extract fio metric from JSON ──
function Get-FioMetric {
    param([string]$Content, [string]$IoType, [string]$Field)
    try {
        $json = $Content | ConvertFrom-Json
        $job = $json.jobs[0]
        switch ($Field) {
            "iops"   { return [math]::Round($job.$IoType.iops, 0) }
            "bw_mib" { return [math]::Round($job.$IoType.bw / 1024, 1) }
            "p99_us" {
                $clat = $job.$IoType.clat_ns
                if ($clat -and $clat.percentile -and $clat.percentile.'99.000000') {
                    return [math]::Round($clat.percentile.'99.000000' / 1000, 0)
                }
                return $null
            }
        }
    }
    catch { return $null }
}

# ── Helper: Extract UnixBench score ──
function Get-UnixBenchScore {
    param([string]$Content, [string]$Type)
    $lines = $Content -split "`n"
    $found = $false
    foreach ($line in $lines) {
        if ($Type -eq "single" -and $line -match "1 parallel copy") { $found = $true }
        if ($Type -eq "multi" -and $line -match "\d+ parallel cop") { $found = $true }
        if ($found -and $line -match "System Benchmarks Index Score\s+(\d+\.?\d*)") {
            try { return [double]$Matches[1] } catch { return $null }
        }
    }
    return $null
}

# ── Helper: Read file content from extracted dir, or $null ──
function Read-ResultFile {
    param([string]$BasePath, [string]$RelPath)
    $fullPath = Join-Path $BasePath $RelPath
    if (Test-Path $fullPath) {
        return Get-Content $fullPath -Raw
    }
    return $null
}

# ══════════════════════════════════════════════
# Download and parse results for each VM
# ══════════════════════════════════════════════

$vms = [ordered]@{}

foreach ($vmKey in $vmNames) {
    Write-Host "Processing results for: $vmKey"
    $resultDir = Get-VmResultFiles -VmKey $vmKey -Headers $headers
    if (-not $resultDir) { continue }

    # Find the actual results subdirectory (run-benchmarks.sh creates a timestamped folder)
    # The tar was created from inside the result directory, so it may extract flat
    $subDirs = Get-ChildItem -Path $resultDir -Directory
    if (Test-Path (Join-Path $resultDir "system-info.json")) {
        # Flat structure: tar was created from inside the results dir
        $rd = $resultDir
    } elseif ($subDirs.Count -ge 1) {
        $rd = $subDirs[0].FullName
    } else {
        $rd = $resultDir
    }

    # --- System info ---
    $info = [ordered]@{}
    $sysInfoContent = Read-ResultFile $rd "system-info.json"
    if ($sysInfoContent) {
        try {
            $si = $sysInfoContent | ConvertFrom-Json
            $notNA = { param($v) if ($v -and $v -ne "N/A" -and $v -ne "unknown" -and $v -ne "") { $v } else { $null } }

            $info.vm_size = if (& $notNA $si.vm_size) { $si.vm_size } else { "unknown" }
            $info.vm_location = & $notNA $si.vm_location
            $info.vm_id = & $notNA $si.vm_id
            if ($si.cpu) {
                $info.cpu_model = $si.cpu.model
                $info.cpu_vcpus = $si.cpu.vcpus
                $info.cpu_vendor = $si.cpu.vendor
            }
            if ($si.memory) {
                $info.memory_total_gb = $si.memory.total_gb
                $info.memory_type = & $notNA $si.memory.type
                $info.memory_speed = & $notNA $si.memory.speed
                $info.numa_nodes = $si.memory.numa_nodes
            }
            if ($si.os) {
                $info.os_name = $si.os.name
                $info.kernel = $si.os.kernel
            }
        }
        catch { Write-Host "  WARNING: Could not parse system-info.json for $vmKey" }
    }

    # --- Extract metrics ---
    $metrics = [ordered]@{}

    # CPU
    $cpuSingleContent = Read-ResultFile $rd "cpu/sysbench-cpu-1thread.txt"
    if ($cpuSingleContent) {
        $metrics.cpu_single_eps = Get-SysbenchNumber $cpuSingleContent "events per second"
        $metrics.cpu_single_lat_ms = Get-SysbenchNumber $cpuSingleContent "avg:"
    }

    # Find highest thread count file for multi-thread
    $cpuDir = Join-Path $rd "cpu"
    $metrics.cpu_multi_eps = $null
    if (Test-Path $cpuDir) {
        $multiFiles = Get-ChildItem -Path $cpuDir -Filter "sysbench-cpu-*threads.txt" |
            Where-Object { $_.Name -notmatch "1threads?" } |
            Sort-Object { if ($_.Name -match '(\d+)threads') { [int]$Matches[1] } else { 0 } }
        if ($multiFiles) {
            $content = Get-Content ($multiFiles | Select-Object -Last 1).FullName -Raw
            $metrics.cpu_multi_eps = Get-SysbenchNumber $content "events per second"
        }
    }

    # Context switching
    $threadsContent = Read-ResultFile $rd "cpu/sysbench-threads.txt"
    $metrics.ctx_switch_eps = $null
    if ($threadsContent) {
        $totalEvents = Get-SysbenchNumber $threadsContent "total number of events"
        $totalTime = Get-SysbenchNumber $threadsContent "total time:"
        if ($null -ne $totalEvents -and $null -ne $totalTime -and $totalTime -gt 0) {
            $metrics.ctx_switch_eps = [math]::Round($totalEvents / $totalTime, 2)
        }
    }

    # Mutex
    $mutexContent = Read-ResultFile $rd "cpu/sysbench-mutex.txt"
    if ($mutexContent) {
        $metrics.mutex_total_time_s = Get-SysbenchNumber $mutexContent "total time:"
    }

    # Memory
    $memReadContent = Read-ResultFile $rd "memory/sysbench-memory-read.txt"
    if ($memReadContent) { $metrics.mem_seq_read_mib_s = Get-SysbenchMiBSec $memReadContent }
    $memWriteContent = Read-ResultFile $rd "memory/sysbench-memory-write.txt"
    if ($memWriteContent) { $metrics.mem_seq_write_mib_s = Get-SysbenchMiBSec $memWriteContent }
    $memRndReadContent = Read-ResultFile $rd "memory/sysbench-memory-rnd-read.txt"
    if ($memRndReadContent) { $metrics.mem_rnd_read_mib_s = Get-SysbenchMiBSec $memRndReadContent }
    $memRndWriteContent = Read-ResultFile $rd "memory/sysbench-memory-rnd-write.txt"
    if ($memRndWriteContent) { $metrics.mem_rnd_write_mib_s = Get-SysbenchMiBSec $memRndWriteContent }

    # STREAM Triad
    $memDir = Join-Path $rd "memory"
    $metrics.stream_triad_mb_s = $null
    if (Test-Path $memDir) {
        $streamFiles = Get-ChildItem -Path $memDir -Filter "stream-*threads.txt" -ErrorAction SilentlyContinue | Sort-Object Name
        if ($streamFiles) {
            $streamContent = Get-Content ($streamFiles | Select-Object -Last 1).FullName -Raw
            if ($streamContent -match 'Triad:\s+([\d.]+)') {
                try { $metrics.stream_triad_mb_s = [double]$Matches[1] } catch {}
            }
            elseif ($streamContent) {
                $lines = $streamContent -split "`n"
                foreach ($line in $lines) {
                    if ($line -match 'Triad') {
                        $parts = $line.Trim() -split '\s+'
                        if ($parts.Count -ge 2) {
                            try { $metrics.stream_triad_mb_s = [double]$parts[1] } catch {}
                        }
                    }
                }
            }
        }
    }

    # Disk (fio JSON)
    $fioRandRead = Read-ResultFile $rd "disk/fio-rand-read-4k.json"
    if ($fioRandRead) {
        $metrics.fio_rand_read_iops = Get-FioMetric $fioRandRead "read" "iops"
        $metrics.fio_rand_read_p99_us = Get-FioMetric $fioRandRead "read" "p99_us"
    }
    $fioRandWrite = Read-ResultFile $rd "disk/fio-rand-write-4k.json"
    if ($fioRandWrite) {
        $metrics.fio_rand_write_iops = Get-FioMetric $fioRandWrite "write" "iops"
        $metrics.fio_rand_write_p99_us = Get-FioMetric $fioRandWrite "write" "p99_us"
    }
    $fioMixed = Read-ResultFile $rd "disk/fio-mixed-randrw-4k.json"
    if ($fioMixed) {
        $metrics.fio_mixed_read_iops = Get-FioMetric $fioMixed "read" "iops"
        $metrics.fio_mixed_write_iops = Get-FioMetric $fioMixed "write" "iops"
    }
    $fioSeqRead = Read-ResultFile $rd "disk/fio-seq-read-256k.json"
    if ($fioSeqRead) { $metrics.fio_seq_read_mb_s = Get-FioMetric $fioSeqRead "read" "bw_mib" }
    $fioSeqWrite = Read-ResultFile $rd "disk/fio-seq-write-256k.json"
    if ($fioSeqWrite) { $metrics.fio_seq_write_mb_s = Get-FioMetric $fioSeqWrite "write" "bw_mib" }

    # System (UnixBench)
    $ubContent = Read-ResultFile $rd "system/unixbench-results.txt"
    if ($ubContent) {
        $metrics.unixbench_single = Get-UnixBenchScore $ubContent "single"
        $metrics.unixbench_multi = Get-UnixBenchScore $ubContent "multi"
    }

    $vms[$vmKey] = [ordered]@{
        info    = $info
        metrics = $metrics
    }

    # Cleanup temp dir
    Remove-Item $resultDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ══════════════════════════════════════════════
# Calculate scores (relative to best = 100)
# ══════════════════════════════════════════════

$weights = [ordered]@{
    cpu    = 0.40
    memory = 0.30
    disk   = 0.20
    system = 0.10
}

$allVmNames = @($vms.Keys)
$scores = [ordered]@{}
$bestValues = [ordered]@{}

# Find best value per metric
foreach ($metricName in $MetricDefs.Keys) {
    $def = $MetricDefs[$metricName]
    $values = @()
    foreach ($vm in $allVmNames) {
        $v = $vms[$vm].metrics[$metricName]
        if ($null -ne $v) { $values += $v }
    }
    if ($values.Count -eq 0) { continue }
    if ($def.direction -eq "+") {
        $best = ($values | Measure-Object -Maximum).Maximum
    }
    else {
        $best = ($values | Measure-Object -Minimum).Minimum
    }
    $bestValues[$metricName] = $best
}

# Per-metric scores
foreach ($vm in $allVmNames) {
    $scores[$vm] = [ordered]@{ per_metric = [ordered]@{}; per_category = [ordered]@{}; composite = $null; rank = $null }

    foreach ($metricName in $MetricDefs.Keys) {
        $def = $MetricDefs[$metricName]
        $v = $vms[$vm].metrics[$metricName]
        $best = $bestValues[$metricName]

        if ($null -eq $v -or $null -eq $best -or $best -eq 0) {
            $scores[$vm].per_metric[$metricName] = $null
            continue
        }

        if ($def.direction -eq "+") {
            $score = [math]::Round($v / $best * 100, 1)
        }
        else {
            $score = [math]::Round($best / $v * 100, 1)
        }
        $scores[$vm].per_metric[$metricName] = $score
    }

    # Per-category average
    foreach ($cat in @("cpu", "memory", "disk", "system")) {
        $catScores = @()
        foreach ($metricName in $MetricDefs.Keys) {
            if ($MetricDefs[$metricName].category -eq $cat) {
                $s = $scores[$vm].per_metric[$metricName]
                if ($null -ne $s) { $catScores += $s }
            }
        }
        if ($catScores.Count -gt 0) {
            $scores[$vm].per_category[$cat] = [math]::Round(($catScores | Measure-Object -Average).Average, 1)
        }
    }

    # Weighted composite
    $compositeNum = 0.0; $compositeDen = 0.0
    foreach ($cat in $weights.Keys) {
        $catScore = $scores[$vm].per_category[$cat]
        if ($null -ne $catScore) {
            $compositeNum += $catScore * $weights[$cat]
            $compositeDen += $weights[$cat]
        }
    }
    if ($compositeDen -gt 0) {
        $scores[$vm].composite = [math]::Round($compositeNum / $compositeDen, 1)
    }
}

# Assign ranks
$ranked = $allVmNames | Sort-Object { $scores[$_].composite } -Descending
for ($i = 0; $i -lt $ranked.Count; $i++) {
    $scores[$ranked[$i]].rank = $i + 1
}

# ── Build output ──
$metricDefsOut = [ordered]@{}
foreach ($metricName in $MetricDefs.Keys) {
    $def = $MetricDefs[$metricName]
    $metricDefsOut[$metricName] = [ordered]@{
        label     = $def.label
        unit      = $def.unit
        direction = $def.direction
        category  = $def.category
    }
}

$vmsOut = [ordered]@{}
foreach ($vm in $allVmNames) {
    $vmsOut[$vm] = [ordered]@{
        info    = $vms[$vm].info
        metrics = $vms[$vm].metrics
        scores  = $scores[$vm]
    }
}

$output = [ordered]@{
    generated_at       = (Get-Date -Format "o")
    run_id             = $runId
    metric_definitions = $metricDefsOut
    scoring            = [ordered]@{
        method      = "relative_to_best"
        description = "Best VM per metric gets 100, others are proportional."
        weights     = $weights
        best_values = $bestValues
    }
    vms = $vmsOut
}

$outputJson = $output | ConvertTo-Json -Depth 20

# ══════════════════════════════════════════════
# Upload results to persistent storage
# ══════════════════════════════════════════════

Write-Host "Uploading results to persistent storage..."

$uploadToken = (Get-AzAccessToken -ResourceUrl "https://storage.azure.com/").Token
$uploadHeaders = @{
    "Authorization"    = "Bearer $uploadToken"
    "x-ms-version"     = "2020-10-02"
    "x-ms-blob-type"   = "BlockBlob"
    "Content-Type"     = "application/json"
}

# Upload results.json
$resultsUrl = "https://${resultsStorageAccountName}.blob.core.windows.net/${resultsContainerName}/${runId}/results.json"
Invoke-RestMethod -Uri $resultsUrl -Method PUT -Headers $uploadHeaders -Body $outputJson | Out-Null

# Build and upload summary CSV
$csvHeader = "vm_name,vm_size,composite_score,rank"
foreach ($metricName in $MetricDefs.Keys) {
    $dir = $MetricDefs[$metricName].direction
    $csvHeader += ",${metricName}(${dir}),${metricName}_score"
}
$csvRows = @($csvHeader)
foreach ($vm in $allVmNames | Sort-Object { $scores[$_].rank }) {
    $row = "$vm,$($vms[$vm].info.vm_size),$($scores[$vm].composite),$($scores[$vm].rank)"
    foreach ($metricName in $MetricDefs.Keys) {
        $val = $vms[$vm].metrics[$metricName]
        $sc = $scores[$vm].per_metric[$metricName]
        $row += ",$(if ($null -ne $val) { $val } else { 'N/A' }),$(if ($null -ne $sc) { $sc } else { 'N/A' })"
    }
    $csvRows += $row
}
$csvContent = $csvRows -join "`n"

$csvUrl = "https://${resultsStorageAccountName}.blob.core.windows.net/${resultsContainerName}/${runId}/summary.csv"
$csvHeaders = @{
    "Authorization"    = "Bearer $uploadToken"
    "x-ms-version"     = "2020-10-02"
    "x-ms-blob-type"   = "BlockBlob"
    "Content-Type"     = "text/csv"
}
Invoke-RestMethod -Uri $csvUrl -Method PUT -Headers $csvHeaders -Body $csvContent | Out-Null

Write-Host "Results uploaded: ${runId}/results.json, ${runId}/summary.csv"

return $outputJson
