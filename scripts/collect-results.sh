#!/usr/bin/env bash
#
# collect-results.sh — Parse benchmark results into a scored JSON summary
#
# Extracts metrics from each VM's benchmark output, calculates relative-to-best
# scores (0-100), weighted composite scores, and outputs results.json.
#
# Usage:
#   ./collect-results.sh [--results-dir /path/to/results] [--merge-with /path/to/results.json]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results"
MERGE_WITH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --results-dir) RESULTS_DIR="$2"; shift 2 ;;
        --merge-with)  MERGE_WITH="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ ! -d "$RESULTS_DIR" ]]; then
    echo "ERROR: Results directory not found: $RESULTS_DIR"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required but not found. Install with: zypper install jq"
    exit 1
fi

JSON_OUT="$RESULTS_DIR/results.json"
CSV_OUT="$RESULTS_DIR/summary.csv"

# ── Weights ──
W_CPU=0.40
W_MEM=0.30
W_DISK=0.20
W_SYS=0.10

# ── Helper: extract sysbench number ──
sysbench_num() {
    local file="$1" pattern="$2"
    [[ -f "$file" ]] || return
    grep "$pattern" "$file" 2>/dev/null | awk '{print $NF}' | head -1
}

# ── Helper: extract MiB/sec from sysbench memory output ──
sysbench_mibsec() {
    local file="$1"
    [[ -f "$file" ]] || return
    grep -oP '[\d.]+(?= MiB/sec)' "$file" 2>/dev/null | head -1
}

# ── Helper: extract fio metric ──
fio_metric() {
    local file="$1" iotype="$2" field="$3"
    [[ -f "$file" ]] || return
    case "$field" in
        iops)   jq -r ".jobs[0].${iotype}.iops // empty" "$file" 2>/dev/null | xargs printf "%.0f" 2>/dev/null ;;
        bw_mib) jq -r ".jobs[0].${iotype}.bw // empty" "$file" 2>/dev/null | awk '{printf "%.1f", $1/1024}' 2>/dev/null ;;
        p99_us) jq -r ".jobs[0].${iotype}.clat_ns.percentile.\"99.000000\" // empty" "$file" 2>/dev/null | awk '{printf "%.0f", $1/1000}' 2>/dev/null ;;
    esac
}

# ── Helper: extract UnixBench score ──
unixbench_score() {
    local file="$1" type="$2"
    [[ -f "$file" ]] || return
    local marker=""
    [[ "$type" == "single" ]] && marker="1 parallel copy"
    [[ "$type" == "multi" ]]  && marker="[0-9]+ parallel cop"
    local found=0
    while IFS= read -r line; do
        if [[ $found -eq 0 ]] && echo "$line" | grep -qE "$marker"; then
            found=1
        fi
        if [[ $found -eq 1 ]] && echo "$line" | grep -qE "System Benchmarks Index Score"; then
            echo "$line" | grep -oP '[\d.]+$'
            return
        fi
    done < "$file"
}

# ── Collect per-VM data ──
# Build a temporary JSON using jq
TMP_VMS=$(mktemp)
echo '{}' > "$TMP_VMS"

for vm_dir in "$RESULTS_DIR"/*/; do
    vm_name=$(basename "$vm_dir")
    [[ "$vm_name" == "summary.csv" || "$vm_name" == "results.json" ]] && continue

    # Find result subdirectory
    result_dir=$(find "$vm_dir" -maxdepth 1 -type d | tail -1)
    rd="${result_dir%/}"

    # System info
    vm_size="unknown"; cpu_model=""; cpu_max_mhz=""; cpu_cores=""; mem_gb=""
    mem_type=""; mem_speed=""
    if [[ -f "$rd/system-info.json" ]]; then
        vm_size=$(jq -r '.vm_size // "unknown"' "$rd/system-info.json" 2>/dev/null || echo "unknown")
        cpu_cores=$(jq -r '.cpu.vcpus // .cpu_cores // null' "$rd/system-info.json" 2>/dev/null)
        cpu_model=$(jq -r '.cpu.model // null' "$rd/system-info.json" 2>/dev/null)
        cpu_max_mhz=$(jq -r '.cpu.max_mhz // null' "$rd/system-info.json" 2>/dev/null)
        mem_gb=$(jq -r '.memory.total_gb // .memory_gb // null' "$rd/system-info.json" 2>/dev/null)
        mem_type=$(jq -r '.memory.type // null' "$rd/system-info.json" 2>/dev/null)
        mem_speed=$(jq -r '.memory.speed // null' "$rd/system-info.json" 2>/dev/null)
    fi

    # CPU metrics
    cpu_single_eps=$(sysbench_num "$rd/cpu/sysbench-cpu-1thread.txt" "events per second" || true)
    cpu_single_lat=$(sysbench_num "$rd/cpu/sysbench-cpu-1thread.txt" "avg:" || true)
    cpu_multi_eps=""
    multi_file=$(find "$rd/cpu/" -name "sysbench-cpu-*threads.txt" ! -name "*1thread*" -name "*[0-9][0-9]*" 2>/dev/null | sort -t- -k4 -n | tail -1 || true)
    [[ -n "$multi_file" && -f "$multi_file" ]] && cpu_multi_eps=$(sysbench_num "$multi_file" "events per second" || true)
    ctx_switch_eps=$(sysbench_num "$rd/cpu/sysbench-threads.txt" "events per second" || true)
    mutex_time=$(sysbench_num "$rd/cpu/sysbench-mutex.txt" "total time:" || true)

    # Memory metrics
    mem_seq_read=$(sysbench_mibsec "$rd/memory/sysbench-memory-read.txt" || true)
    mem_seq_write=$(sysbench_mibsec "$rd/memory/sysbench-memory-write.txt" || true)
    mem_rnd_read=$(sysbench_mibsec "$rd/memory/sysbench-memory-rnd-read.txt" || true)
    mem_rnd_write=$(sysbench_mibsec "$rd/memory/sysbench-memory-rnd-write.txt" || true)

    # STREAM Triad
    stream_triad=""
    stream_file=$(find "$rd/memory/" -name "stream-*threads.txt" 2>/dev/null | sort | tail -1 || true)
    [[ -n "$stream_file" && -f "$stream_file" ]] && stream_triad=$(grep "Triad" "$stream_file" | awk '{print $2}' || true)

    # Disk metrics
    fio_rr_iops=$(fio_metric "$rd/disk/fio-rand-read-4k.json" "read" "iops" || true)
    fio_rw_iops=$(fio_metric "$rd/disk/fio-rand-write-4k.json" "write" "iops" || true)
    fio_mr_iops=$(fio_metric "$rd/disk/fio-mixed-randrw-4k.json" "read" "iops" || true)
    fio_mw_iops=$(fio_metric "$rd/disk/fio-mixed-randrw-4k.json" "write" "iops" || true)
    fio_sr_bw=$(fio_metric "$rd/disk/fio-seq-read-256k.json" "read" "bw_mib" || true)
    fio_sw_bw=$(fio_metric "$rd/disk/fio-seq-write-256k.json" "write" "bw_mib" || true)
    fio_rr_p99=$(fio_metric "$rd/disk/fio-rand-read-4k.json" "read" "p99_us" || true)
    fio_rw_p99=$(fio_metric "$rd/disk/fio-rand-write-4k.json" "write" "p99_us" || true)

    # UnixBench
    ub_single=$(unixbench_score "$rd/system/unixbench-results.txt" "single" || true)
    ub_multi=$(unixbench_score "$rd/system/unixbench-results.txt" "multi" || true)

    # Convert empty to null for jq
    to_jq_num() { [[ -n "$1" && "$1" != "null" ]] && echo "$1" || echo "null"; }

    # Build VM JSON entry
    jq --arg vm "$vm_name" \
       --arg vs "$vm_size" --arg cm "$cpu_model" --arg cmhz "$cpu_max_mhz" \
       --arg cc "$cpu_cores" --arg mg "$mem_gb" --arg mt "$mem_type" --arg ms "$mem_speed" \
       --argjson cse "$(to_jq_num "$cpu_single_eps")" \
       --argjson cme "$(to_jq_num "$cpu_multi_eps")" \
       --argjson csl "$(to_jq_num "$cpu_single_lat")" \
       --argjson csx "$(to_jq_num "$ctx_switch_eps")" \
       --argjson mtt "$(to_jq_num "$mutex_time")" \
       --argjson msr "$(to_jq_num "$mem_seq_read")" \
       --argjson msw "$(to_jq_num "$mem_seq_write")" \
       --argjson mrr "$(to_jq_num "$mem_rnd_read")" \
       --argjson mrw "$(to_jq_num "$mem_rnd_write")" \
       --argjson str "$(to_jq_num "$stream_triad")" \
       --argjson fri "$(to_jq_num "$fio_rr_iops")" \
       --argjson fwi "$(to_jq_num "$fio_rw_iops")" \
       --argjson fmri "$(to_jq_num "$fio_mr_iops")" \
       --argjson fmwi "$(to_jq_num "$fio_mw_iops")" \
       --argjson fsrb "$(to_jq_num "$fio_sr_bw")" \
       --argjson fswb "$(to_jq_num "$fio_sw_bw")" \
       --argjson frrp "$(to_jq_num "$fio_rr_p99")" \
       --argjson frwp "$(to_jq_num "$fio_rw_p99")" \
       --argjson ubs "$(to_jq_num "$ub_single")" \
       --argjson ubm "$(to_jq_num "$ub_multi")" \
       '.[$vm] = {
            info: {
                vm_size: $vs,
                cpu_model: (if $cm == "null" or $cm == "" then null else $cm end),
                cpu_max_mhz: (if $cmhz == "null" or $cmhz == "" then null else $cmhz end),
                cpu_cores: (if $cc == "null" or $cc == "" then null else ($cc | tonumber) end),
                memory_gb: (if $mg == "null" or $mg == "" then null else ($mg | tonumber) end),
                memory_type: (if $mt == "null" or $mt == "" then null else $mt end),
                memory_speed: (if $ms == "null" or $ms == "" then null else $ms end)
            },
            metrics: {
                cpu_single_eps: $cse,
                cpu_multi_eps: $cme,
                cpu_single_lat_ms: $csl,
                ctx_switch_eps: $csx,
                mutex_total_time_s: $mtt,
                mem_seq_read_mib_s: $msr,
                mem_seq_write_mib_s: $msw,
                mem_rnd_read_mib_s: $mrr,
                mem_rnd_write_mib_s: $mrw,
                stream_triad_mb_s: $str,
                fio_rand_read_iops: $fri,
                fio_rand_write_iops: $fwi,
                fio_mixed_read_iops: $fmri,
                fio_mixed_write_iops: $fmwi,
                fio_seq_read_mb_s: $fsrb,
                fio_seq_write_mb_s: $fswb,
                fio_rand_read_p99_us: $frrp,
                fio_rand_write_p99_us: $frwp,
                unixbench_single: $ubs,
                unixbench_multi: $ubm
            }
        }' "$TMP_VMS" > "${TMP_VMS}.tmp" && mv "${TMP_VMS}.tmp" "$TMP_VMS"
done

# ── Merge with existing results.json if specified ──
if [[ -n "$MERGE_WITH" && -f "$MERGE_WITH" ]]; then
    echo "Merging with existing results: $MERGE_WITH"
    EXISTING_VMS=$(jq '.vms // {}' "$MERGE_WITH")
    # Add existing VMs that aren't in fresh results
    for vm in $(echo "$EXISTING_VMS" | jq -r 'keys[]'); do
        if ! jq -e --arg v "$vm" '.[$v]' "$TMP_VMS" &>/dev/null; then
            jq --arg v "$vm" --argjson data "$(echo "$EXISTING_VMS" | jq --arg v "$vm" '.[$v]')" \
               '.[$v] = $data' "$TMP_VMS" > "${TMP_VMS}.tmp" && mv "${TMP_VMS}.tmp" "$TMP_VMS"
        fi
    done
fi

# ── Metric definitions ──
METRIC_DEFS='{
    "cpu_single_eps":        {"label":"CPU single-thread",       "unit":"events/s", "direction":"+", "category":"cpu"},
    "cpu_multi_eps":         {"label":"CPU multi-thread",        "unit":"events/s", "direction":"+", "category":"cpu"},
    "cpu_single_lat_ms":     {"label":"CPU single-thread latency","unit":"ms",      "direction":"-", "category":"cpu"},
    "ctx_switch_eps":        {"label":"Context switching",       "unit":"events/s", "direction":"+", "category":"cpu"},
    "mutex_total_time_s":    {"label":"Mutex contention time",   "unit":"s",        "direction":"-", "category":"cpu"},
    "mem_seq_read_mib_s":    {"label":"Memory seq read",         "unit":"MiB/s",    "direction":"+", "category":"memory"},
    "mem_seq_write_mib_s":   {"label":"Memory seq write",        "unit":"MiB/s",    "direction":"+", "category":"memory"},
    "mem_rnd_read_mib_s":    {"label":"Memory random read",      "unit":"MiB/s",    "direction":"+", "category":"memory"},
    "mem_rnd_write_mib_s":   {"label":"Memory random write",     "unit":"MiB/s",    "direction":"+", "category":"memory"},
    "stream_triad_mb_s":     {"label":"STREAM Triad",            "unit":"MB/s",     "direction":"+", "category":"memory"},
    "fio_rand_read_iops":    {"label":"Random read 4K",          "unit":"IOPS",     "direction":"+", "category":"disk"},
    "fio_rand_write_iops":   {"label":"Random write 4K",         "unit":"IOPS",     "direction":"+", "category":"disk"},
    "fio_mixed_read_iops":   {"label":"Mixed R/W read",          "unit":"IOPS",     "direction":"+", "category":"disk"},
    "fio_mixed_write_iops":  {"label":"Mixed R/W write",         "unit":"IOPS",     "direction":"+", "category":"disk"},
    "fio_seq_read_mb_s":     {"label":"Sequential read 256K",    "unit":"MiB/s",    "direction":"+", "category":"disk"},
    "fio_seq_write_mb_s":    {"label":"Sequential write 256K",   "unit":"MiB/s",    "direction":"+", "category":"disk"},
    "fio_rand_read_p99_us":  {"label":"Random read P99 lat",     "unit":"us",       "direction":"-", "category":"disk"},
    "fio_rand_write_p99_us": {"label":"Random write P99 lat",    "unit":"us",       "direction":"-", "category":"disk"},
    "unixbench_single":      {"label":"UnixBench single",        "unit":"score",    "direction":"+", "category":"system"},
    "unixbench_multi":       {"label":"UnixBench multi",         "unit":"score",    "direction":"+", "category":"system"}
}'

# ── Calculate scores with jq ──
jq -n \
    --argjson vms "$(cat "$TMP_VMS")" \
    --argjson defs "$METRIC_DEFS" \
    --argjson w_cpu "$W_CPU" --argjson w_mem "$W_MEM" --argjson w_disk "$W_DISK" --argjson w_sys "$W_SYS" \
'
def score_metric($val; $best; $dir):
    if $val == null or $best == null or $best == 0 then null
    elif $dir == "+" then (($val / $best * 100) * 10 | round / 10)
    else (($best / $val * 100) * 10 | round / 10)
    end;

# Find best value per metric
($defs | keys) as $metric_names |
(reduce $metric_names[] as $m ({}; 
    ($defs[$m].direction) as $dir |
    ([($vms | to_entries[].value.metrics[$m]) | select(. != null)] ) as $vals |
    if ($vals | length) == 0 then .
    elif $dir == "+" then . + {($m): ($vals | max)}
    else . + {($m): ($vals | min)}
    end
)) as $best_values |

# Calculate per-metric scores for each VM
(reduce ($vms | keys[]) as $vm ({};
    .[$vm] = (reduce $metric_names[] as $m ({};
        ($vms[$vm].metrics[$m]) as $val |
        ($best_values[$m]) as $best |
        ($defs[$m].direction) as $dir |
        . + {($m): score_metric($val; $best; $dir)}
    ))
)) as $vm_scores |

# Category averages
(["cpu","memory","disk","system"]) as $categories |
(reduce ($vms | keys[]) as $vm ({};
    .[$vm] = (reduce $categories[] as $cat ({};
        ([($metric_names[] | select($defs[.].category == $cat)) as $m | $vm_scores[$vm][$m] | select(. != null)]) as $cat_scores |
        if ($cat_scores | length) > 0
        then . + {($cat): (($cat_scores | add / length) * 10 | round / 10)}
        else . + {($cat): null}
        end
    ))
)) as $cat_scores |

# Weighted composite
{"cpu": $w_cpu, "memory": $w_mem, "disk": $w_disk, "system": $w_sys} as $weights |
(reduce ($vms | keys[]) as $vm ({};
    ($cat_scores[$vm]) as $cs |
    (reduce $categories[] as $cat ({num: 0, den: 0};
        if $cs[$cat] != null then {num: (.num + $cs[$cat] * $weights[$cat]), den: (.den + $weights[$cat])}
        else . end
    )) as $comp |
    .[$vm] = (if $comp.den > 0 then (($comp.num / $comp.den) * 10 | round / 10) else null end)
)) as $composites |

# Rank by composite (descending)
([$vms | keys[] | {vm: ., score: $composites[.]}] | sort_by(-.score) | to_entries | map({(.value.vm): (.key + 1)}) | add // {}) as $ranks |

# Build output
{
    generated_at: (now | todate),
    metric_definitions: $defs,
    scoring: {
        method: "relative_to_best",
        description: "Best VM per metric gets 100, others proportional. direction=+ means higher is better, direction=- means lower is better.",
        weights: $weights,
        best_values: $best_values
    },
    vms: (reduce ($vms | keys[]) as $vm ({};
        .[$vm] = {
            info: $vms[$vm].info,
            metrics: $vms[$vm].metrics,
            scores: {
                per_metric: $vm_scores[$vm],
                per_category: $cat_scores[$vm],
                composite: $composites[$vm],
                rank: $ranks[$vm]
            }
        }
    ))
}
' > "$JSON_OUT"

# ── Also produce CSV for quick viewing ──
jq -r '
    # Header
    ("vm_name,vm_size,composite_score,rank," +
     ((.metric_definitions | keys) | map(. + "(" + (.as $m | .[$m] | .direction // "+") + ")," + . + "_score") | join(","))),
    # Rows sorted by rank
    (.vms | to_entries | sort_by(.value.scores.rank) | .[] |
        .key as $vm | .value as $v |
        [$vm, $v.info.vm_size, ($v.scores.composite // "N/A" | tostring), ($v.scores.rank // "N/A" | tostring)] +
        ([(.scores.per_metric | keys[]) as $m |
            (($v.metrics[$m] // "N/A") | tostring),
            (($v.scores.per_metric[$m] // "N/A") | tostring)
        ]) | join(",")
    )
' "$JSON_OUT" > "$CSV_OUT" 2>/dev/null || true

rm -f "$TMP_VMS"

# ── Console output ──
echo ""
echo "Results written to:"
echo "  JSON: $JSON_OUT"
echo "  CSV:  $CSV_OUT"
echo ""
echo "====== VM Comparison (ranked by composite score) ======"
echo ""
jq -r '
    .vms | to_entries | sort_by(.value.scores.rank) | .[] |
    "  #\(.value.scores.rank) \(.key) (\(.value.info.vm_size)) — Composite: \(.value.scores.composite)  |  CPU: \(.value.scores.per_category.cpu // "N/A")  Memory: \(.value.scores.per_category.memory // "N/A")  Disk: \(.value.scores.per_category.disk // "N/A")  System: \(.value.scores.per_category.system // "N/A")"
' "$JSON_OUT"

echo ""
echo "Best values per metric:"
jq -r '
    .metric_definitions as $defs |
    .scoring.best_values | to_entries[] |
    "  \($defs[.key].label) (\($defs[.key].direction)): \(.value) \($defs[.key].unit)"
' "$JSON_OUT"
