#!/usr/bin/env bash
#
# run-network-pair.sh — Cross-VM network benchmark using iperf3
#
# Usage:
#   On server VM:  ./run-network-pair.sh server
#   On client VM:  ./run-network-pair.sh client <SERVER_PRIVATE_IP> [--output-dir /path]
#
# Tests SAP app server ↔ DB network latency and throughput.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-}"
DURATION=60

usage() {
    echo "Usage:"
    echo "  $0 server                                  # start iperf3 server"
    echo "  $0 client <SERVER_IP> [--output-dir DIR]   # run client tests"
    exit 1
}

[[ -z "$MODE" ]] && usage

case "$MODE" in
    server)
        echo "Starting iperf3 server on ports 5201-5204..."
        for port in 5201 5202 5203 5204; do
            iperf3 -s -p $port -D
        done
        echo "Server ready. Run client from another VM."
        echo "To stop: pkill iperf3"
        ;;
    client)
        SERVER_IP="${2:-}"
        [[ -z "$SERVER_IP" ]] && { echo "ERROR: Server IP required"; usage; }

        OUTPUT_DIR="${SCRIPT_DIR}/../results/network-pair-$(date +%Y%m%d-%H%M%S)"
        shift 2
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
                *) echo "Unknown option: $1"; usage ;;
            esac
        done
        mkdir -p "$OUTPUT_DIR"

        echo "Testing against server: $SERVER_IP"

        echo "  [1/4] Single TCP stream (${DURATION}s)..."
        iperf3 -c "$SERVER_IP" -p 5201 -t $DURATION -J \
            > "$OUTPUT_DIR/iperf3-tcp-1stream.json" 2>&1

        echo "  [2/4] 8 parallel TCP streams (${DURATION}s)..."
        iperf3 -c "$SERVER_IP" -p 5202 -t $DURATION -P 8 -J \
            > "$OUTPUT_DIR/iperf3-tcp-8streams.json" 2>&1

        echo "  [3/4] UDP bandwidth test (${DURATION}s)..."
        iperf3 -c "$SERVER_IP" -p 5203 -t $DURATION -u -b 10G -J \
            > "$OUTPUT_DIR/iperf3-udp.json" 2>&1

        echo "  [4/4] Reverse direction test (${DURATION}s)..."
        iperf3 -c "$SERVER_IP" -p 5204 -t $DURATION -R -J \
            > "$OUTPUT_DIR/iperf3-tcp-reverse.json" 2>&1

        echo "Done. Results in $OUTPUT_DIR"
        ;;
    *)
        usage
        ;;
esac
