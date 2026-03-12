#!/usr/bin/env bash
#
# System Benchmark Suite
# Focus: Overall system performance scoring
#
# Tests:
#   1. UnixBench (byte-unixbench) — industry-standard composite score
#
set -euo pipefail

OUTPUT_DIR="$1"
RESULTS_DIR="$OUTPUT_DIR/system"
mkdir -p "$RESULTS_DIR"

NUM_CPUS=$(nproc)

# --- UnixBench ---
if command -v gcc &>/dev/null || command -v cc &>/dev/null; then
    UBENCH_DIR=$(mktemp -d)
    echo "    [system] Downloading UnixBench..."

    if command -v git &>/dev/null; then
        git clone --depth 1 https://github.com/kdlucas/byte-unixbench.git "$UBENCH_DIR/unixbench" 2>/dev/null
    elif command -v curl &>/dev/null; then
        curl -sL https://github.com/kdlucas/byte-unixbench/archive/refs/heads/master.tar.gz \
            | tar xz -C "$UBENCH_DIR"
        mv "$UBENCH_DIR"/byte-unixbench-* "$UBENCH_DIR/unixbench"
    else
        echo "    [system] WARNING: Neither git nor curl available, skipping UnixBench"
        exit 0
    fi

    echo "    [system] Building and running UnixBench (this takes 15-30 min)..."
    pushd "$UBENCH_DIR/unixbench/UnixBench" > /dev/null

    # Build
    make -j"$NUM_CPUS" > "$RESULTS_DIR/unixbench-build.log" 2>&1

    # Run single-threaded and multi-threaded
    ./Run -c 1 -c "$NUM_CPUS" > "$RESULTS_DIR/unixbench-results.txt" 2>&1

    popd > /dev/null
    rm -rf "$UBENCH_DIR"
else
    echo "    [system] WARNING: No C compiler found, skipping UnixBench"
fi

echo "    [system] Done. Results in $RESULTS_DIR"
