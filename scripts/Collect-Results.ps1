<#
.SYNOPSIS
    Parse benchmark results into a scored JSON summary.

.DESCRIPTION
    Walks through the results directory, extracts key metrics from each VM's
    benchmark output, calculates relative-to-best scores (0-100) per metric,
    computes weighted composite scores, and outputs results.json.

    Supports merging: run with -MergeWith to combine with a previous results.json.
    Scores are always recalculated across all VMs in the final set.

.PARAMETER ResultsDir
    Path to the results directory. Default: ../results (relative to script location)

.PARAMETER MergeWith
    Path to an existing results.json to merge with. New VM results are added,
    and all scores are recalculated across the combined set.

.PARAMETER WeightCpu
    Weight for CPU category in composite score (default: 0.40)

.PARAMETER WeightMemory
    Weight for Memory category in composite score (default: 0.30)

.PARAMETER WeightDisk
    Weight for Disk category in composite score (default: 0.20)

.PARAMETER WeightSystem
    Weight for System category in composite score (default: 0.10)

.EXAMPLE
    .\Collect-Results.ps1
    .\Collect-Results.ps1 -ResultsDir ".\results" -MergeWith ".\previous-results.json"
#>
param(
    [string]$ResultsDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "results"),
    [string]$MergeWith = "",
    [double]$WeightCpu = 0.40,
    [double]$WeightMemory = 0.30,
    [double]$WeightDisk = 0.20,
    [double]$WeightSystem = 0.10
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ResultsDir)) {
    Write-Error "Results directory not found: $ResultsDir"
    exit 1
}

# ── Metric definitions: direction (+/- = higher/lower is better), category, unit ──
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

# ── Helper functions ──

function Get-FioMetric {
    param([string]$FilePath, [string]$IoType, [string]$Field)
    if (-not (Test-Path $FilePath)) { return $null }
    try {
        $json = Get-Content $FilePath -Raw | ConvertFrom-Json
        $job = $json.jobs[0]
        switch ($Field) {
            "iops"   { return [math]::Round($job.$IoType.iops, 0) }
            "bw_mib" { return [math]::Round($job.$IoType.bw / 1024, 1) }
            "p99_us" {
                $clat = $job.$IoType.clat_ns
                if ($clat -and $clat.percentile -and $clat.percentile.'99.000000') {
                    return [math]::Round($clat.percentile.'99.000000' / 1000, 0)  # ns to us
                }
                return $null
            }
        }
    }
    catch { return $null }
}

function Get-SysbenchNumber {
    param([string]$FilePath, [string]$Pattern)
    if (-not (Test-Path $FilePath)) { return $null }
    $line = Select-String -Path $FilePath -Pattern $Pattern | Select-Object -First 1
    if ($line) {
        $parts = $line.Line.Trim() -split '\s+'
        $val = $parts[-1] -replace '[^\d.\-]',''  # strip unit suffixes like 's'
        try { return [double]$val } catch { return $null }
    }
    return $null
}

function Get-SysbenchMiBSec {
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { return $null }
    $match = Select-String -Path $FilePath -Pattern '([\d.]+)\s+MiB/sec' | Select-Object -First 1
    if ($match -and $match.Matches.Groups.Count -ge 2) {
        try { return [double]$match.Matches.Groups[1].Value } catch { return $null }
    }
    return $null
}

function Get-UnixBenchScore {
    param([string]$FilePath, [string]$Type)
    if (-not (Test-Path $FilePath)) { return $null }
    # UnixBench outputs "System Benchmarks Index Score ... <number>"
    $lines = Get-Content $FilePath
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

# ── Extract metrics from each VM ──

$vms = [ordered]@{}

foreach ($vmDir in Get-ChildItem -Path $ResultsDir -Directory) {
    $vmName = $vmDir.Name
    $rd = $vmDir.FullName

    # ── System info ──
    $info = [ordered]@{}
    $sysInfoPath = Join-Path $rd "system-info.json"
    if (Test-Path $sysInfoPath) {
        try {
            $si = Get-Content $sysInfoPath -Raw | ConvertFrom-Json

            # Helper to return $null for "N/A", "unknown", or empty strings
            $notNA = { param($v) if ($v -and $v -ne "N/A" -and $v -ne "unknown" -and $v -ne "") { $v } else { $null } }

            # VM / Azure
            $tmp = & $notNA $si.vm_size; $info.vm_size = if ($tmp) { $tmp } else { "unknown" }
            $info.vm_location = & $notNA $si.vm_location
            $info.vm_id       = & $notNA $si.vm_id
            $info.vm_image    = if ($si.vm_image) { "$($si.vm_image.publisher):$($si.vm_image.offer):$($si.vm_image.sku)" } else { $null }

            # CPU
            if ($si.cpu) {
                $c = $si.cpu
                $info.cpu_model            = $c.model
                $info.cpu_vendor           = $c.vendor
                $info.cpu_family           = & $notNA $c.family
                $info.cpu_stepping         = & $notNA $c.stepping
                $info.cpu_microcode        = & $notNA $c.microcode
                $info.cpu_vcpus            = $c.vcpus
                $info.cpu_sockets          = $c.sockets
                $info.cpu_cores_per_socket = $c.cores_per_socket
                $info.cpu_threads_per_core = $c.threads_per_core
                $tmp = & $notNA $c.max_mhz; $info.cpu_max_mhz = if ($tmp) { $tmp } else { & $notNA $c.dmi_max_speed }
                $tmp = & $notNA $c.current_mhz; $info.cpu_current_speed = if ($tmp) { $tmp } else { & $notNA $c.dmi_current_speed }
                $info.cpu_bogomips         = & $notNA $c.bogomips
                $info.cpu_op_modes         = & $notNA $c.op_modes
                $info.cpu_address_sizes    = & $notNA $c.address_sizes
                $info.cpu_hypervisor       = & $notNA $c.hypervisor
                $info.cpu_cache_l1d        = if ($c.cache) { & $notNA $c.cache.l1d } else { $null }
                $info.cpu_cache_l1i        = if ($c.cache) { & $notNA $c.cache.l1i } else { $null }
                $info.cpu_cache_l2         = if ($c.cache) { & $notNA $c.cache.l2 } else { $null }
                $info.cpu_cache_l3         = if ($c.cache) { & $notNA $c.cache.l3 } else { $null }
            }

            # Memory
            if ($si.memory) {
                $m = $si.memory
                $info.memory_total_gb      = $m.total_gb
                $info.memory_available_gb  = $m.available_gb
                $info.memory_swap_gb       = $m.swap_gb
                $info.memory_type          = & $notNA $m.type
                $info.memory_speed         = & $notNA $m.speed
                $info.memory_configured_speed = & $notNA $m.configured_speed
                $info.memory_max_capacity  = & $notNA $m.max_capacity
                $info.memory_manufacturer  = & $notNA $m.manufacturer
                $info.memory_dimm_count    = & $notNA $m.dimm_count
                $info.memory_per_dimm_size = & $notNA $m.per_dimm_size
                $info.memory_form_factor   = & $notNA $m.form_factor
                $info.memory_rank          = & $notNA $m.rank
                $info.memory_data_width    = & $notNA $m.data_width
                $info.numa_nodes           = $m.numa_nodes
                $info.memory_hugepage_size = & $notNA $m.hugepage_size
                $info.memory_hugepages_total = & $notNA $m.hugepages_total
            }

            # OS
            if ($si.os) {
                $info.os_name        = $si.os.name
                $info.kernel         = $si.os.kernel
                $info.kernel_cmdline = & $notNA $si.os.kernel_cmdline
            }

            # Disk summary from lsblk hardware dump
            $lsblkPath = Join-Path $rd "hardware\lsblk.txt"
            if (Test-Path $lsblkPath) {
                $lsblkLines = Get-Content $lsblkPath | Where-Object { $_ -match "disk" }
                $info.disks = @($lsblkLines | ForEach-Object { $_.Trim() -replace '\s+', ' ' })
            }
        } catch {}
    }

    # ── Extract all metrics ──
    $metrics = [ordered]@{}

    # CPU
    $metrics.cpu_single_eps    = Get-SysbenchNumber (Join-Path $rd "cpu\sysbench-cpu-1thread.txt") "events per second"
    $metrics.cpu_single_lat_ms = Get-SysbenchNumber (Join-Path $rd "cpu\sysbench-cpu-1thread.txt") "avg:"
    $cpuDir = Join-Path $rd "cpu"
    $metrics.cpu_multi_eps = $null
    if (Test-Path $cpuDir) {
        $multiFiles = Get-ChildItem -Path $cpuDir -Filter "sysbench-cpu-*threads.txt" |
            Where-Object { $_.Name -notmatch "1thread" -and $_.Name -match "\d{2,}" } |
            Sort-Object Name
        if ($multiFiles) {
            $metrics.cpu_multi_eps = Get-SysbenchNumber ($multiFiles | Select-Object -Last 1).FullName "events per second"
        }
    }
    # threads benchmark doesn't have "events per second" - compute from total events / total time
    $threadsFile = Join-Path $rd "cpu\sysbench-threads.txt"
    $metrics.ctx_switch_eps = $null
    if (Test-Path $threadsFile) {
        $totalEvents = Get-SysbenchNumber $threadsFile "total number of events"
        $totalTime   = Get-SysbenchNumber $threadsFile "total time:"
        if ($null -ne $totalEvents -and $null -ne $totalTime -and $totalTime -gt 0) {
            $metrics.ctx_switch_eps = [math]::Round($totalEvents / $totalTime, 2)
        }
    }
    # Mutex: extract total time
    $mutexFile = Join-Path $rd "cpu\sysbench-mutex.txt"
    $metrics.mutex_total_time_s = Get-SysbenchNumber $mutexFile "total time:"

    # Memory
    $metrics.mem_seq_read_mib_s  = Get-SysbenchMiBSec (Join-Path $rd "memory\sysbench-memory-read.txt")
    $metrics.mem_seq_write_mib_s = Get-SysbenchMiBSec (Join-Path $rd "memory\sysbench-memory-write.txt")
    $metrics.mem_rnd_read_mib_s  = Get-SysbenchMiBSec (Join-Path $rd "memory\sysbench-memory-rnd-read.txt")
    $metrics.mem_rnd_write_mib_s = Get-SysbenchMiBSec (Join-Path $rd "memory\sysbench-memory-rnd-write.txt")

    # STREAM Triad (multi-threaded)
    $memDir = Join-Path $rd "memory"
    $metrics.stream_triad_mb_s = $null
    if (Test-Path $memDir) {
        $streamFiles = Get-ChildItem -Path $memDir -Filter "stream-*threads.txt" | Sort-Object Name
        if ($streamFiles) {
            $triadLine = Select-String -Path ($streamFiles | Select-Object -Last 1).FullName -Pattern "Triad" | Select-Object -First 1
            if ($triadLine) {
                $parts = $triadLine.Line.Trim() -split '\s+'
                try { $metrics.stream_triad_mb_s = [double]$parts[1] } catch {}
            }
        }
    }

    # Disk
    $metrics.fio_rand_read_iops   = Get-FioMetric (Join-Path $rd "disk\fio-rand-read-4k.json")    "read"  "iops"
    $metrics.fio_rand_write_iops  = Get-FioMetric (Join-Path $rd "disk\fio-rand-write-4k.json")   "write" "iops"
    $metrics.fio_mixed_read_iops  = Get-FioMetric (Join-Path $rd "disk\fio-mixed-randrw-4k.json") "read"  "iops"
    $metrics.fio_mixed_write_iops = Get-FioMetric (Join-Path $rd "disk\fio-mixed-randrw-4k.json") "write" "iops"
    $metrics.fio_seq_read_mb_s    = Get-FioMetric (Join-Path $rd "disk\fio-seq-read-256k.json")   "read"  "bw_mib"
    $metrics.fio_seq_write_mb_s   = Get-FioMetric (Join-Path $rd "disk\fio-seq-write-256k.json")  "write" "bw_mib"
    $metrics.fio_rand_read_p99_us = Get-FioMetric (Join-Path $rd "disk\fio-rand-read-4k.json")    "read"  "p99_us"
    $metrics.fio_rand_write_p99_us= Get-FioMetric (Join-Path $rd "disk\fio-rand-write-4k.json")   "write" "p99_us"

    # System (UnixBench)
    $ubFile = Join-Path $rd "system\unixbench-results.txt"
    $metrics.unixbench_single = Get-UnixBenchScore $ubFile "single"
    $metrics.unixbench_multi  = Get-UnixBenchScore $ubFile "multi"

    $vms[$vmName] = [ordered]@{
        info    = $info
        metrics = $metrics
    }
}

# ── Merge with existing results if specified ──

if ($MergeWith -and (Test-Path $MergeWith)) {
    Write-Host "Merging with existing results: $MergeWith" -ForegroundColor Cyan
    $existing = Get-Content $MergeWith -Raw | ConvertFrom-Json
    if ($existing.vms) {
        foreach ($prop in $existing.vms.PSObject.Properties) {
            if (-not $vms.Contains($prop.Name)) {
                $vms[$prop.Name] = [ordered]@{
                    info    = $prop.Value.info
                    metrics = [ordered]@{}
                }
                foreach ($mp in $prop.Value.metrics.PSObject.Properties) {
                    $vms[$prop.Name].metrics[$mp.Name] = $mp.Value
                }
            }
        }
    }
}

# ── Calculate scores (relative to best = 100) ──

$weights = [ordered]@{
    cpu    = $WeightCpu
    memory = $WeightMemory
    disk   = $WeightDisk
    system = $WeightSystem
}

$vmNames = @($vms.Keys)
$scores = [ordered]@{}
$bestValues = [ordered]@{}

# Find best value per metric across all VMs
foreach ($metricName in $MetricDefs.Keys) {
    $def = $MetricDefs[$metricName]
    $values = @()
    foreach ($vm in $vmNames) {
        $v = $vms[$vm].metrics[$metricName]
        if ($null -ne $v) { $values += $v }
    }
    if ($values.Count -eq 0) { continue }

    if ($def.direction -eq "+") {
        $best = ($values | Measure-Object -Maximum).Maximum
    } else {
        $best = ($values | Measure-Object -Minimum).Minimum
    }
    $bestValues[$metricName] = $best
}

# Calculate per-metric score for each VM
foreach ($vm in $vmNames) {
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
            # Higher is better: score = value / best * 100
            $score = [math]::Round($v / $best * 100, 1)
        } else {
            # Lower is better: score = best / value * 100
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
        } else {
            $scores[$vm].per_category[$cat] = $null
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

# Assign ranks by composite score (1 = best)
$ranked = $vmNames | Sort-Object { $scores[$_].composite } -Descending
for ($i = 0; $i -lt $ranked.Count; $i++) {
    $scores[$ranked[$i]].rank = $i + 1
}

# ── Build output JSON ──

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
foreach ($vm in $vmNames) {
    $vmsOut[$vm] = [ordered]@{
        info    = $vms[$vm].info
        metrics = $vms[$vm].metrics
        scores  = $scores[$vm]
    }
}

$output = [ordered]@{
    generated_at = (Get-Date -Format "o")
    metric_definitions = $metricDefsOut
    scoring = [ordered]@{
        method  = "relative_to_best"
        description = "Best VM per metric gets 100, others are proportional. For direction='+' (higher is better): score = value/best*100. For direction='-' (lower is better): score = best/value*100."
        weights = $weights
        best_values = $bestValues
    }
    vms = $vmsOut
}

$jsonPath = Join-Path $ResultsDir "results.json"
$output | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8

# Also write a summary CSV for quick viewing
$csvPath = Join-Path $ResultsDir "summary.csv"
$csvHeader = "vm_name,vm_size,composite_score,rank"
foreach ($metricName in $MetricDefs.Keys) {
    $dir = $MetricDefs[$metricName].direction
    $csvHeader += ",${metricName}(${dir}),${metricName}_score"
}
$csvRows = @()
foreach ($vm in $vmNames | Sort-Object { $scores[$_].rank }) {
    $row = "$vm,$($vms[$vm].info.vm_size),$($scores[$vm].composite),$($scores[$vm].rank)"
    foreach ($metricName in $MetricDefs.Keys) {
        $val = $vms[$vm].metrics[$metricName]
        $sc  = $scores[$vm].per_metric[$metricName]
        $row += ",$(if ($null -ne $val) { $val } else { 'N/A' }),$(if ($null -ne $sc) { $sc } else { 'N/A' })"
    }
    $csvRows += $row
}
$csvHeader | Out-File -FilePath $csvPath -Encoding UTF8
$csvRows | Out-File -FilePath $csvPath -Encoding UTF8 -Append

# ── Console output ──

Write-Host ""
Write-Host "Results written to:" -ForegroundColor Green
Write-Host "  JSON: $jsonPath"
Write-Host "  CSV:  $csvPath"
Write-Host ""

# Display ranked summary table
Write-Host "====== VM Comparison (ranked by composite score) ======" -ForegroundColor Cyan
Write-Host ""

$tableData = @()
foreach ($vm in $vmNames | Sort-Object { $scores[$_].rank }) {
    $row = [ordered]@{
        Rank      = $scores[$vm].rank
        VM        = $vm
        Size      = $vms[$vm].info.vm_size
        Composite = "$($scores[$vm].composite)"
        CPU       = "$(if ($scores[$vm].per_category.cpu) { $scores[$vm].per_category.cpu } else { 'N/A' })"
        Memory    = "$(if ($scores[$vm].per_category.memory) { $scores[$vm].per_category.memory } else { 'N/A' })"
        Disk      = "$(if ($scores[$vm].per_category.disk) { $scores[$vm].per_category.disk } else { 'N/A' })"
        System    = "$(if ($scores[$vm].per_category.system) { $scores[$vm].per_category.system } else { 'N/A' })"
    }
    $tableData += [PSCustomObject]$row
}
$tableData | Format-Table -AutoSize

# Show best values
Write-Host "Best values per metric:" -ForegroundColor Cyan
foreach ($metricName in $MetricDefs.Keys) {
    if ($null -ne $bestValues[$metricName]) {
        $def = $MetricDefs[$metricName]
        $bestVm = ""
        foreach ($vm in $vmNames) {
            $v = $vms[$vm].metrics[$metricName]
            if ($null -ne $v -and $bestValues[$metricName] -eq $v) { $bestVm = $vm; break }
        }
        $dir = $def.direction
        Write-Host "  $($def.label) ($dir): $($bestValues[$metricName]) $($def.unit) [$bestVm]"
    }
}
