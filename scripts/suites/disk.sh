#!/usr/bin/env bash
#
# Disk I/O Benchmark Suite
# Focus: SAP Application Server disk patterns (/usr/sap, swap, temp)
#
# Tests:
#   1. Random read 4K (metadata-heavy operations)
#   2. Random write 4K
#   3. Sequential read 256K (log files, application loading)
#   4. Sequential write 256K
#   5. Mixed random read/write 70/30 (typical SAP app server)
#
set -euo pipefail

OUTPUT_DIR="$1"
RESULTS_DIR="$OUTPUT_DIR/disk"
mkdir -p "$RESULTS_DIR"

NUM_CPUS=$(nproc)
# Test on the OS disk by default — SAP app servers typically use it
TEST_DIR="/tmp/fio-benchmark"
mkdir -p "$TEST_DIR"

# fio common settings
RUNTIME=60
SIZE="4G"
IODEPTH=32

echo "    [disk] Running fio benchmarks (runtime=${RUNTIME}s each)..."

# 1. Random read 4K — metadata, small file access
echo "    [disk] Random read 4K (iodepth=$IODEPTH)..."
fio --name=rand-read-4k \
    --directory="$TEST_DIR" \
    --rw=randread \
    --bs=4k \
    --size=$SIZE \
    --numjobs=4 \
    --iodepth=$IODEPTH \
    --runtime=$RUNTIME \
    --time_based \
    --group_reporting \
    --lat_percentiles=1 \
    --output-format=json \
    --output="$RESULTS_DIR/fio-rand-read-4k.json" \
    > /dev/null 2>&1
rm -f "$TEST_DIR"/*

# 2. Random write 4K
echo "    [disk] Random write 4K (iodepth=$IODEPTH)..."
fio --name=rand-write-4k \
    --directory="$TEST_DIR" \
    --rw=randwrite \
    --bs=4k \
    --size=$SIZE \
    --numjobs=4 \
    --iodepth=$IODEPTH \
    --runtime=$RUNTIME \
    --time_based \
    --group_reporting \
    --lat_percentiles=1 \
    --output-format=json \
    --output="$RESULTS_DIR/fio-rand-write-4k.json" \
    > /dev/null 2>&1
rm -f "$TEST_DIR"/*

# 3. Sequential read 256K — application binaries, log reading
echo "    [disk] Sequential read 256K..."
fio --name=seq-read-256k \
    --directory="$TEST_DIR" \
    --rw=read \
    --bs=256k \
    --size=$SIZE \
    --numjobs=4 \
    --iodepth=16 \
    --runtime=$RUNTIME \
    --time_based \
    --group_reporting \
    --output-format=json \
    --output="$RESULTS_DIR/fio-seq-read-256k.json" \
    > /dev/null 2>&1
rm -f "$TEST_DIR"/*

# 4. Sequential write 256K — log writing, spool
echo "    [disk] Sequential write 256K..."
fio --name=seq-write-256k \
    --directory="$TEST_DIR" \
    --rw=write \
    --bs=256k \
    --size=$SIZE \
    --numjobs=4 \
    --iodepth=16 \
    --runtime=$RUNTIME \
    --time_based \
    --group_reporting \
    --output-format=json \
    --output="$RESULTS_DIR/fio-seq-write-256k.json" \
    > /dev/null 2>&1
rm -f "$TEST_DIR"/*

# 5. Mixed random R/W 70/30 — typical SAP app server pattern
echo "    [disk] Mixed random R/W 70/30 (4K)..."
fio --name=mixed-randrw-4k \
    --directory="$TEST_DIR" \
    --rw=randrw \
    --rwmixread=70 \
    --bs=4k \
    --size=$SIZE \
    --numjobs=4 \
    --iodepth=$IODEPTH \
    --runtime=$RUNTIME \
    --time_based \
    --group_reporting \
    --lat_percentiles=1 \
    --output-format=json \
    --output="$RESULTS_DIR/fio-mixed-randrw-4k.json" \
    > /dev/null 2>&1

# Cleanup test files
rm -rf "$TEST_DIR"

echo "    [disk] Done. Results in $RESULTS_DIR"
