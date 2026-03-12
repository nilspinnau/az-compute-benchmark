#!/usr/bin/env bash
#
# Memory Benchmark Suite
# Focus: SAP Application Server memory performance
#
# Tests:
#   1. sysbench memory — sequential read/write throughput
#   2. STREAM — memory bandwidth (copy, scale, add, triad)
#   3. NUMA-aware memory latency (if numactl available)
#
set -euo pipefail

OUTPUT_DIR="$1"
RESULTS_DIR="$OUTPUT_DIR/memory"
mkdir -p "$RESULTS_DIR"

NUM_CPUS=$(nproc)
DURATION=60

# --- sysbench memory ---
echo "    [memory] sysbench memory — write (${DURATION}s, $NUM_CPUS threads)..."
sysbench memory \
    --memory-block-size=1M \
    --memory-total-size=0 \
    --memory-oper=write \
    --memory-access-mode=seq \
    --threads=$NUM_CPUS \
    --time=$DURATION \
    run > "$RESULTS_DIR/sysbench-memory-write.txt" 2>&1

echo "    [memory] sysbench memory — read (${DURATION}s, $NUM_CPUS threads)..."
sysbench memory \
    --memory-block-size=1M \
    --memory-total-size=0 \
    --memory-oper=read \
    --memory-access-mode=seq \
    --threads=$NUM_CPUS \
    --time=$DURATION \
    run > "$RESULTS_DIR/sysbench-memory-read.txt" 2>&1

# --- Random access memory latency (SAP scattered access patterns) ---
echo "    [memory] sysbench memory — random write ($NUM_CPUS threads, ${DURATION}s)..."
sysbench memory \
    --memory-block-size=1M \
    --memory-total-size=0 \
    --memory-oper=write \
    --memory-access-mode=rnd \
    --threads=$NUM_CPUS \
    --time=$DURATION \
    run > "$RESULTS_DIR/sysbench-memory-rnd-write.txt" 2>&1

echo "    [memory] sysbench memory — random read ($NUM_CPUS threads, ${DURATION}s)..."
sysbench memory \
    --memory-block-size=1M \
    --memory-total-size=0 \
    --memory-oper=read \
    --memory-access-mode=rnd \
    --threads=$NUM_CPUS \
    --time=$DURATION \
    run > "$RESULTS_DIR/sysbench-memory-rnd-read.txt" 2>&1

# --- Single-threaded memory (per-core bandwidth) ---
echo "    [memory] sysbench memory — single-threaded read (${DURATION}s)..."
sysbench memory \
    --memory-block-size=1M \
    --memory-total-size=0 \
    --memory-oper=read \
    --memory-access-mode=seq \
    --threads=1 \
    --time=$DURATION \
    run > "$RESULTS_DIR/sysbench-memory-read-1thread.txt" 2>&1

# --- STREAM benchmark ---
if command -v gcc &>/dev/null || command -v cc &>/dev/null; then
    echo "    [memory] Building STREAM benchmark..."
    STREAM_DIR=$(mktemp -d)
    cat > "$STREAM_DIR/stream.c" << 'STREAMEOF'
/*-----------------------------------------------------------------------*/
/* STREAM benchmark — simplified version for memory bandwidth measurement */
/* Based on the STREAM benchmark by John D. McCalpin                      */
/*-----------------------------------------------------------------------*/
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <float.h>
#include <limits.h>
#include <sys/time.h>

#ifndef STREAM_ARRAY_SIZE
#define STREAM_ARRAY_SIZE 80000000
#endif

#ifndef NTIMES
#define NTIMES 20
#endif

static double a[STREAM_ARRAY_SIZE], b[STREAM_ARRAY_SIZE], c[STREAM_ARRAY_SIZE];

static double mysecond(void) {
    struct timeval tp;
    gettimeofday(&tp, NULL);
    return ((double)tp.tv_sec + (double)tp.tv_usec * 1.e-6);
}

int main() {
    double times[4][NTIMES];
    double avgtime[4] = {0}, maxtime[4] = {0}, mintime[4];
    double bytes[4] = {
        2 * sizeof(double) * STREAM_ARRAY_SIZE,
        2 * sizeof(double) * STREAM_ARRAY_SIZE,
        3 * sizeof(double) * STREAM_ARRAY_SIZE,
        3 * sizeof(double) * STREAM_ARRAY_SIZE
    };
    const char *label[4] = {"Copy", "Scale", "Add", "Triad"};
    double scalar = 3.0;
    int j, k;

    for (j = 0; j < STREAM_ARRAY_SIZE; j++) {
        a[j] = 1.0; b[j] = 2.0; c[j] = 0.0;
    }

    for (k = 0; k < NTIMES; k++) {
        times[0][k] = mysecond();
        for (j = 0; j < STREAM_ARRAY_SIZE; j++) c[j] = a[j];
        times[0][k] = mysecond() - times[0][k];

        times[1][k] = mysecond();
        for (j = 0; j < STREAM_ARRAY_SIZE; j++) b[j] = scalar * c[j];
        times[1][k] = mysecond() - times[1][k];

        times[2][k] = mysecond();
        for (j = 0; j < STREAM_ARRAY_SIZE; j++) c[j] = a[j] + b[j];
        times[2][k] = mysecond() - times[2][k];

        times[3][k] = mysecond();
        for (j = 0; j < STREAM_ARRAY_SIZE; j++) a[j] = b[j] + scalar * c[j];
        times[3][k] = mysecond() - times[3][k];
    }

    for (j = 0; j < 4; j++) {
        mintime[j] = FLT_MAX;
        for (k = 1; k < NTIMES; k++) {
            avgtime[j] += times[j][k];
            if (times[j][k] < mintime[j]) mintime[j] = times[j][k];
            if (times[j][k] > maxtime[j]) maxtime[j] = times[j][k];
        }
        avgtime[j] /= (NTIMES - 1);
    }

    printf("Function    Best Rate MB/s  Avg time     Min time     Max time\n");
    for (j = 0; j < 4; j++) {
        printf("%-12s%11.1f  %11.6f  %11.6f  %11.6f\n",
               label[j],
               1.0E-06 * bytes[j] / mintime[j],
               avgtime[j], mintime[j], maxtime[j]);
    }
    return 0;
}
STREAMEOF

    COMPILER=$(command -v gcc 2>/dev/null || command -v cc)
    $COMPILER -O3 -march=native -fopenmp -DSTREAM_ARRAY_SIZE=80000000 -DNTIMES=20 \
        "$STREAM_DIR/stream.c" -o "$STREAM_DIR/stream" -lm 2>/dev/null

    echo "    [memory] Running STREAM (single-threaded)..."
    OMP_NUM_THREADS=1 "$STREAM_DIR/stream" > "$RESULTS_DIR/stream-1thread.txt" 2>&1

    echo "    [memory] Running STREAM ($NUM_CPUS threads)..."
    OMP_NUM_THREADS=$NUM_CPUS "$STREAM_DIR/stream" > "$RESULTS_DIR/stream-${NUM_CPUS}threads.txt" 2>&1

    rm -rf "$STREAM_DIR"
else
    echo "    [memory] WARNING: No C compiler found, skipping STREAM benchmark"
fi

# --- NUMA topology info ---
if command -v numactl &>/dev/null; then
    echo "    [memory] Collecting NUMA topology..."
    numactl --hardware > "$RESULTS_DIR/numa-topology.txt" 2>&1

    # --- NUMA cross-node memory latency ---
    NUMA_NODES=$(numactl --hardware 2>/dev/null | grep "available:" | awk '{print $2}')
    if [[ "$NUMA_NODES" -gt 1 ]]; then
        echo "    [memory] NUMA cross-node memory bandwidth tests ($NUMA_NODES nodes)..."
        for src_node in $(seq 0 $((NUMA_NODES - 1))); do
            for mem_node in $(seq 0 $((NUMA_NODES - 1))); do
                echo "      [memory] CPU node $src_node → Memory node $mem_node..."
                numactl --cpunodebind=$src_node --membind=$mem_node \
                    sysbench memory \
                    --memory-block-size=1M \
                    --memory-total-size=0 \
                    --memory-oper=read \
                    --memory-access-mode=seq \
                    --threads=1 \
                    --time=15 \
                    run > "$RESULTS_DIR/numa-bw-cpu${src_node}-mem${mem_node}.txt" 2>&1
            done
        done
    fi
fi

echo "    [memory] Done. Results in $RESULTS_DIR"
