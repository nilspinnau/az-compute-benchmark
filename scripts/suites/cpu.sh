#!/usr/bin/env bash
#
# CPU Benchmark Suite
# Focus: SAP Application Server CPU performance (SAPS correlation)
#
# Tests:
#   1. sysbench CPU — single-threaded (SAP dialog step latency)
#   2. sysbench CPU — multi-threaded (SAP batch/parallel workloads)
#   3. sysbench CPU — scaling test across thread counts
#
set -euo pipefail

OUTPUT_DIR="$1"
RESULTS_DIR="$OUTPUT_DIR/cpu"
mkdir -p "$RESULTS_DIR"

NUM_CPUS=$(nproc)
# Duration per test in seconds
DURATION=60
# sysbench max-prime — higher = longer per event, more stable measurement
MAX_PRIME=20000

echo "    [cpu] Single-threaded sysbench (1 thread, ${DURATION}s)..."
sysbench cpu \
    --cpu-max-prime=$MAX_PRIME \
    --threads=1 \
    --time=$DURATION \
    run > "$RESULTS_DIR/sysbench-cpu-1thread.txt" 2>&1

echo "    [cpu] Multi-threaded sysbench ($NUM_CPUS threads, ${DURATION}s)..."
sysbench cpu \
    --cpu-max-prime=$MAX_PRIME \
    --threads=$NUM_CPUS \
    --time=$DURATION \
    run > "$RESULTS_DIR/sysbench-cpu-${NUM_CPUS}threads.txt" 2>&1

# Scaling test: 1, 2, 4, 8, 16, 32, 64, up to NUM_CPUS
echo "    [cpu] Thread scaling test..."
scaling_file="$RESULTS_DIR/thread-scaling.csv"
echo "threads,events_per_sec,latency_avg_ms,latency_p95_ms" > "$scaling_file"

thread_counts=()
t=1
while [[ $t -le $NUM_CPUS ]]; do
    thread_counts+=($t)
    t=$((t * 2))
done
# Always include the full core count
if [[ ${thread_counts[-1]} -ne $NUM_CPUS ]]; then
    thread_counts+=($NUM_CPUS)
fi

for threads in "${thread_counts[@]}"; do
    echo "      [cpu] Scaling: $threads threads..."
    result=$(sysbench cpu \
        --cpu-max-prime=$MAX_PRIME \
        --threads=$threads \
        --time=30 \
        run 2>&1)

    eps=$(echo "$result" | grep "events per second" | awk '{print $NF}')
    lat_avg=$(echo "$result" | grep "avg:" | awk '{print $NF}')
    lat_p95=$(echo "$result" | grep "95th percentile:" | awk '{print $NF}')

    echo "$threads,$eps,$lat_avg,$lat_p95" >> "$scaling_file"
    echo "$result" > "$RESULTS_DIR/sysbench-cpu-${threads}threads.txt"
done

# --- Context switching benchmark (SAP runs hundreds of work processes) ---
echo "    [cpu] Context switching test ($NUM_CPUS threads, ${DURATION}s)..."
sysbench threads \
    --threads=$NUM_CPUS \
    --thread-yields=1000 \
    --thread-locks=8 \
    --time=$DURATION \
    run > "$RESULTS_DIR/sysbench-threads.txt" 2>&1

# --- Mutex contention (SAP shared memory segments) ---
echo "    [cpu] Mutex contention test ($NUM_CPUS threads)..."
sysbench mutex \
    --mutex-num=4096 \
    --mutex-locks=50000 \
    --mutex-loops=10000 \
    --threads=$NUM_CPUS \
    run > "$RESULTS_DIR/sysbench-mutex.txt" 2>&1

echo "    [cpu] Done. Results in $RESULTS_DIR"
