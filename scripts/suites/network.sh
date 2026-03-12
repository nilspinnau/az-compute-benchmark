#!/usr/bin/env bash
#
# Network Benchmark Suite
# Focus: SAP Application Server network throughput (app ↔ DB communication)
#
# Tests:
#   1. iperf3 loopback — baseline memory/stack throughput
#   2. Network interface info and accelerated networking status
#   3. TCP tuning parameters snapshot
#
# Note: For cross-VM iperf3 tests, use run-network-pair.sh separately with
# two VMs (one as server, one as client).
#
set -euo pipefail

OUTPUT_DIR="$1"
RESULTS_DIR="$OUTPUT_DIR/network"
mkdir -p "$RESULTS_DIR"

NUM_CPUS=$(nproc)
DURATION=30

# --- Network interface info ---
echo "    [network] Collecting network configuration..."
{
    echo "=== ip link ==="
    ip link show 2>/dev/null || true
    echo ""
    echo "=== Accelerated Networking Check ==="
    if command -v ethtool &>/dev/null; then
        for iface in $(ls /sys/class/net/ | grep -v lo); do
            echo "--- $iface ---"
            ethtool -i "$iface" 2>/dev/null || true
        done
    fi
    echo ""
    echo "=== lspci (Mellanox/network) ==="
    lspci 2>/dev/null | grep -iE "mellanox|network|ethernet" || true
} > "$RESULTS_DIR/network-info.txt" 2>&1

# --- TCP tuning snapshot ---
echo "    [network] Collecting TCP tuning parameters..."
{
    echo "=== TCP buffer sizes ==="
    echo "tcp_rmem: $(cat /proc/sys/net/ipv4/tcp_rmem 2>/dev/null)"
    echo "tcp_wmem: $(cat /proc/sys/net/ipv4/tcp_wmem 2>/dev/null)"
    echo "tcp_mem:  $(cat /proc/sys/net/core/rmem_max 2>/dev/null)"
    echo ""
    echo "=== Core net settings ==="
    echo "rmem_max: $(cat /proc/sys/net/core/rmem_max 2>/dev/null)"
    echo "wmem_max: $(cat /proc/sys/net/core/wmem_max 2>/dev/null)"
    echo "netdev_max_backlog: $(cat /proc/sys/net/core/netdev_max_backlog 2>/dev/null)"
} > "$RESULTS_DIR/tcp-tuning.txt" 2>&1

# --- iperf3 loopback test ---
if command -v iperf3 &>/dev/null; then
    echo "    [network] iperf3 loopback — single stream (${DURATION}s)..."
    # Start server in background
    iperf3 -s -D -p 5201 --one-off 2>/dev/null
    sleep 1
    iperf3 -c 127.0.0.1 -p 5201 -t $DURATION -J \
        > "$RESULTS_DIR/iperf3-loopback-1stream.json" 2>&1 || true

    echo "    [network] iperf3 loopback — $NUM_CPUS parallel streams (${DURATION}s)..."
    iperf3 -s -D -p 5202 --one-off 2>/dev/null
    sleep 1
    iperf3 -c 127.0.0.1 -p 5202 -t $DURATION -P $NUM_CPUS -J \
        > "$RESULTS_DIR/iperf3-loopback-${NUM_CPUS}streams.json" 2>&1 || true
else
    echo "    [network] WARNING: iperf3 not found, skipping throughput tests"
fi

echo "    [network] Done. Results in $RESULTS_DIR"
