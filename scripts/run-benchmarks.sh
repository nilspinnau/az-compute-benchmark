#!/usr/bin/env bash
#
# run-benchmarks.sh — Main entry point for running all benchmark suites.
#
# Usage:
#   ./run-benchmarks.sh [--output-dir /path/to/results] [--suites cpu,memory,disk,network,system]
#
# Designed for SAP Application Server workload profiling.
# Runs on SLES, RHEL, Ubuntu.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/../results/$(hostname)-$(date +%Y%m%d-%H%M%S)"
SUITES="cpu,memory,disk,network,system"

usage() {
    echo "Usage: $0 [--output-dir DIR] [--suites SUITE_LIST]"
    echo ""
    echo "  --output-dir DIR         Directory for results (default: auto-generated)"
    echo "  --suites SUITE_LIST      Comma-separated list of: cpu,memory,disk,network,system"
    echo ""
    echo "Examples:"
    echo "  $0                                    # run all suites"
    echo "  $0 --suites cpu,memory                # run only CPU and memory"
    echo "  $0 --output-dir /tmp/bench-results    # custom output directory"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --suites)
            SUITES="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

mkdir -p "$OUTPUT_DIR"

# Collect system info
echo "=============================================="
echo " Azure VM Benchmark Suite"
echo " Host: $(hostname)"
echo " Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo " Output: $OUTPUT_DIR"
echo " Suites: $SUITES"
echo "=============================================="

# System metadata
collect_metadata() {
    echo ">>> Collecting system metadata..."
    local meta_file="$OUTPUT_DIR/system-info.json"
    local hw_dir="$OUTPUT_DIR/hardware"
    mkdir -p "$hw_dir"

    # --- CPU details (lscpu) ---
    local cpu_model
    cpu_model=$(lscpu | grep "Model name" | sed 's/.*:\s*//' | head -1)
    local cpu_cores
    cpu_cores=$(nproc)
    local cpu_sockets
    cpu_sockets=$(lscpu | grep "^Socket(s):" | awk '{print $NF}')
    local cpu_cores_per_socket
    cpu_cores_per_socket=$(lscpu | grep "^Core(s) per socket:" | awk '{print $NF}')
    local cpu_threads_per_core
    cpu_threads_per_core=$(lscpu | grep "^Thread(s) per core:" | awk '{print $NF}')
    local cpu_max_mhz
    cpu_max_mhz=$(lscpu | grep "CPU max MHz" | sed 's/.*:\s*//' | tr -d ' ' || echo "N/A")
    local cpu_min_mhz
    cpu_min_mhz=$(lscpu | grep "CPU min MHz" | sed 's/.*:\s*//' | tr -d ' ' || echo "N/A")
    local cpu_cur_mhz
    cpu_cur_mhz=$(lscpu | grep "CPU MHz" | head -1 | sed 's/.*:\s*//' | tr -d ' ' || echo "N/A")
    local cpu_vendor
    cpu_vendor=$(lscpu | grep "Vendor ID" | sed 's/.*:\s*//' | head -1)
    local cpu_family
    cpu_family=$(lscpu | grep "CPU family" | awk '{print $NF}')
    local cpu_stepping
    cpu_stepping=$(lscpu | grep "Stepping" | awk '{print $NF}')
    local cpu_bogomips
    cpu_bogomips=$(lscpu | grep "BogoMIPS" | sed 's/.*:\s*//' | tr -d ' ' || echo "N/A")
    local cpu_virtualization
    cpu_virtualization=$(lscpu | grep "Hypervisor vendor" | sed 's/.*:\s*//' || echo "N/A")
    local cpu_virt_type
    cpu_virt_type=$(lscpu | grep "Virtualization type" | sed 's/.*:\s*//' || echo "N/A")
    local cpu_op_modes
    cpu_op_modes=$(lscpu | grep "CPU op-mode" | sed 's/.*:\s*//' || echo "N/A")
    local cpu_byte_order
    cpu_byte_order=$(lscpu | grep "Byte Order" | sed 's/.*:\s*//' || echo "N/A")
    local cpu_address_sizes
    cpu_address_sizes=$(lscpu | grep "Address sizes" | sed 's/.*:\s*//' || echo "N/A")
    local cpu_cache_l1d
    cpu_cache_l1d=$(lscpu | grep "L1d cache" | sed 's/.*:\s*//' || echo "N/A")
    local cpu_cache_l1i
    cpu_cache_l1i=$(lscpu | grep "L1i cache" | sed 's/.*:\s*//' || echo "N/A")
    local cpu_cache_l2
    cpu_cache_l2=$(lscpu | grep "L2 cache" | sed 's/.*:\s*//' || echo "N/A")
    local cpu_cache_l3
    cpu_cache_l3=$(lscpu | grep "L3 cache" | sed 's/.*:\s*//' || echo "N/A")
    local cpu_flags
    cpu_flags=$(lscpu | grep "^Flags:" | sed 's/.*:\s*//' || echo "N/A")

    # CPU details from dmidecode (more accurate clock/voltage info)
    local cpu_dmi_version="N/A"
    local cpu_dmi_voltage="N/A"
    local cpu_dmi_ext_clock="N/A"
    local cpu_dmi_max_speed="N/A"
    local cpu_dmi_current_speed="N/A"
    local cpu_microcode="N/A"
    if command -v dmidecode &>/dev/null; then
        cpu_dmi_version=$(dmidecode --type processor 2>/dev/null | grep "Version:" | head -1 | sed 's/.*:\s*//' || echo "N/A")
        cpu_dmi_voltage=$(dmidecode --type processor 2>/dev/null | grep "Voltage:" | head -1 | sed 's/.*:\s*//' || echo "N/A")
        cpu_dmi_ext_clock=$(dmidecode --type processor 2>/dev/null | grep "External Clock:" | head -1 | sed 's/.*:\s*//' || echo "N/A")
        cpu_dmi_max_speed=$(dmidecode --type processor 2>/dev/null | grep "Max Speed:" | head -1 | sed 's/.*:\s*//' || echo "N/A")
        cpu_dmi_current_speed=$(dmidecode --type processor 2>/dev/null | grep "Current Speed:" | head -1 | sed 's/.*:\s*//' || echo "N/A")
    fi
    # Microcode from /proc/cpuinfo
    cpu_microcode=$(grep "microcode" /proc/cpuinfo 2>/dev/null | head -1 | awk '{print $NF}' || echo "N/A")

    # --- Memory details ---
    local mem_total_kb
    mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local mem_total_gb
    mem_total_gb=$(echo "scale=1; $mem_total_kb / 1048576" | bc)
    local mem_available_kb
    mem_available_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}' || echo "0")
    local mem_available_gb
    mem_available_gb=$(echo "scale=1; $mem_available_kb / 1048576" | bc)
    local mem_hugepage_size
    mem_hugepage_size=$(grep Hugepagesize /proc/meminfo | awk '{print $2, $3}' || echo "N/A")
    local mem_hugepages_total
    mem_hugepages_total=$(grep HugePages_Total /proc/meminfo | awk '{print $2}' || echo "0")
    local mem_swap_total_kb
    mem_swap_total_kb=$(grep SwapTotal /proc/meminfo | awk '{print $2}' || echo "0")
    local mem_swap_total_gb
    mem_swap_total_gb=$(echo "scale=1; $mem_swap_total_kb / 1048576" | bc)
    local numa_nodes
    numa_nodes=$(lscpu | grep "NUMA node(s):" | awk '{print $NF}')

    # RAM details via dmidecode (requires root)
    local mem_type="N/A"
    local mem_speed="N/A"
    local mem_configured_speed="N/A"
    local mem_dimm_count="N/A"
    local mem_manufacturer="N/A"
    local mem_form_factor="N/A"
    local mem_data_width="N/A"
    local mem_total_width="N/A"
    local mem_per_dimm_size="N/A"
    local mem_rank="N/A"
    local mem_part_number="N/A"
    local mem_max_capacity="N/A"
    local mem_slots_used="N/A"
    local mem_slots_total="N/A"
    if command -v dmidecode &>/dev/null; then
        mem_type=$(dmidecode --type memory 2>/dev/null | grep "^\s*Type:" | grep -v "Error\|Unknown\|Other" | head -1 | sed 's/.*:\s*//' || echo "N/A")
        mem_speed=$(dmidecode --type memory 2>/dev/null | grep "^\s*Speed:" | grep -v "Unknown" | head -1 | sed 's/.*:\s*//' || echo "N/A")
        mem_configured_speed=$(dmidecode --type memory 2>/dev/null | grep "Configured Memory Speed\|Configured Clock Speed" | head -1 | sed 's/.*:\s*//' || echo "N/A")
        mem_dimm_count=$(dmidecode --type memory 2>/dev/null | grep -c "^\s*Size:.*[0-9]" || echo "N/A")
        mem_manufacturer=$(dmidecode --type memory 2>/dev/null | grep "Manufacturer:" | grep -v "Not Specified\|Unknown" | head -1 | sed 's/.*:\s*//' || echo "N/A")
        mem_form_factor=$(dmidecode --type memory 2>/dev/null | grep "Form Factor:" | grep -v "Unknown" | head -1 | sed 's/.*:\s*//' || echo "N/A")
        mem_data_width=$(dmidecode --type memory 2>/dev/null | grep "Data Width:" | grep -v "Unknown" | head -1 | sed 's/.*:\s*//' || echo "N/A")
        mem_total_width=$(dmidecode --type memory 2>/dev/null | grep "Total Width:" | grep -v "Unknown" | head -1 | sed 's/.*:\s*//' || echo "N/A")
        mem_per_dimm_size=$(dmidecode --type memory 2>/dev/null | grep "^\s*Size:" | grep -v "No Module" | head -1 | sed 's/.*:\s*//' || echo "N/A")
        mem_rank=$(dmidecode --type memory 2>/dev/null | grep "Rank:" | head -1 | sed 's/.*:\s*//' || echo "N/A")
        mem_part_number=$(dmidecode --type memory 2>/dev/null | grep "Part Number:" | grep -v "Not Specified\|Unknown" | head -1 | sed 's/.*:\s*//' || echo "N/A")
        mem_max_capacity=$(dmidecode --type memory 2>/dev/null | grep "Maximum Capacity:" | head -1 | sed 's/.*:\s*//' || echo "N/A")
        mem_slots_total=$(dmidecode --type memory 2>/dev/null | grep "Number Of Devices:" | head -1 | awk '{print $NF}' || echo "N/A")
        mem_slots_used=$mem_dimm_count
    fi

    # --- Disk info ---
    local disk_info="N/A"
    disk_info=$(lsblk -d -o NAME,SIZE,TYPE,ROTA,MODEL,TRAN 2>/dev/null | head -10 || echo "N/A")

    # --- OS / Kernel ---
    local kernel
    kernel=$(uname -r)
    local os_name
    os_name=$(cat /etc/os-release 2>/dev/null | grep "^PRETTY_NAME=" | cut -d'"' -f2)
    local kernel_cmdline
    kernel_cmdline=$(cat /proc/cmdline 2>/dev/null || echo "N/A")

    # --- Azure VM metadata (full compute block) ---
    local vm_size="unknown"
    local vm_location="unknown"
    local vm_id="unknown"
    local vm_offer="unknown"
    local vm_publisher="unknown"
    local vm_sku="unknown"
    if command -v curl &>/dev/null; then
        vm_size=$(curl -s -H "Metadata:true" --connect-timeout 2 \
            "http://169.254.169.254/metadata/instance/compute/vmSize?api-version=2021-02-01&format=text" 2>/dev/null || echo "unknown")
        vm_location=$(curl -s -H "Metadata:true" --connect-timeout 2 \
            "http://169.254.169.254/metadata/instance/compute/location?api-version=2021-02-01&format=text" 2>/dev/null || echo "unknown")
        vm_id=$(curl -s -H "Metadata:true" --connect-timeout 2 \
            "http://169.254.169.254/metadata/instance/compute/vmId?api-version=2021-02-01&format=text" 2>/dev/null || echo "unknown")
        vm_offer=$(curl -s -H "Metadata:true" --connect-timeout 2 \
            "http://169.254.169.254/metadata/instance/compute/offer?api-version=2021-02-01&format=text" 2>/dev/null || echo "unknown")
        vm_publisher=$(curl -s -H "Metadata:true" --connect-timeout 2 \
            "http://169.254.169.254/metadata/instance/compute/publisher?api-version=2021-02-01&format=text" 2>/dev/null || echo "unknown")
        vm_sku=$(curl -s -H "Metadata:true" --connect-timeout 2 \
            "http://169.254.169.254/metadata/instance/compute/sku?api-version=2021-02-01&format=text" 2>/dev/null || echo "unknown")
    fi

    cat > "$meta_file" <<EOF
{
  "hostname": "$(hostname)",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "vm_size": "$vm_size",
  "vm_location": "$vm_location",
  "vm_id": "$vm_id",
  "vm_image": {
    "offer": "$vm_offer",
    "publisher": "$vm_publisher",
    "sku": "$vm_sku"
  },
  "cpu": {
    "model": "$cpu_model",
    "vendor": "$cpu_vendor",
    "family": "$cpu_family",
    "stepping": "$cpu_stepping",
    "microcode": "$cpu_microcode",
    "vcpus": $cpu_cores,
    "sockets": "$cpu_sockets",
    "cores_per_socket": "$cpu_cores_per_socket",
    "threads_per_core": "$cpu_threads_per_core",
    "max_mhz": "$cpu_max_mhz",
    "min_mhz": "$cpu_min_mhz",
    "current_mhz": "$cpu_cur_mhz",
    "bogomips": "$cpu_bogomips",
    "op_modes": "$cpu_op_modes",
    "byte_order": "$cpu_byte_order",
    "address_sizes": "$cpu_address_sizes",
    "hypervisor": "$cpu_virtualization",
    "virtualization_type": "$cpu_virt_type",
    "dmi_version": "$cpu_dmi_version",
    "dmi_voltage": "$cpu_dmi_voltage",
    "dmi_external_clock": "$cpu_dmi_ext_clock",
    "dmi_max_speed": "$cpu_dmi_max_speed",
    "dmi_current_speed": "$cpu_dmi_current_speed",
    "cache": {
      "l1d": "$cpu_cache_l1d",
      "l1i": "$cpu_cache_l1i",
      "l2": "$cpu_cache_l2",
      "l3": "$cpu_cache_l3"
    }
  },
  "memory": {
    "total_gb": $mem_total_gb,
    "available_gb": $mem_available_gb,
    "swap_gb": $mem_swap_total_gb,
    "type": "$mem_type",
    "form_factor": "$mem_form_factor",
    "speed": "$mem_speed",
    "configured_speed": "$mem_configured_speed",
    "data_width": "$mem_data_width",
    "total_width": "$mem_total_width",
    "per_dimm_size": "$mem_per_dimm_size",
    "rank": "$mem_rank",
    "dimm_count": "$mem_dimm_count",
    "slots_total": "$mem_slots_total",
    "slots_used": "$mem_slots_used",
    "max_capacity": "$mem_max_capacity",
    "manufacturer": "$mem_manufacturer",
    "part_number": "$mem_part_number",
    "numa_nodes": "$numa_nodes",
    "hugepage_size": "$mem_hugepage_size",
    "hugepages_total": "$mem_hugepages_total"
  },
  "os": {
    "name": "$os_name",
    "kernel": "$kernel",
    "kernel_cmdline": "$kernel_cmdline"
  }
}
EOF

    # Save raw hardware dumps for full detail
    lscpu > "$hw_dir/lscpu.txt" 2>&1
    lscpu -e > "$hw_dir/lscpu-extended.txt" 2>&1
    lscpu -J > "$hw_dir/lscpu.json" 2>&1 || true
    cat /proc/cpuinfo > "$hw_dir/cpuinfo.txt" 2>&1
    cat /proc/meminfo > "$hw_dir/meminfo.txt" 2>&1
    lsblk -a -o NAME,SIZE,TYPE,ROTA,MODEL,TRAN,MOUNTPOINT,FSTYPE > "$hw_dir/lsblk.txt" 2>&1
    if command -v dmidecode &>/dev/null; then
        dmidecode > "$hw_dir/dmidecode-full.txt" 2>&1
        dmidecode --type processor > "$hw_dir/dmidecode-cpu.txt" 2>&1
        dmidecode --type memory > "$hw_dir/dmidecode-memory.txt" 2>&1
        dmidecode --type baseboard > "$hw_dir/dmidecode-baseboard.txt" 2>&1
        dmidecode --type bios > "$hw_dir/dmidecode-bios.txt" 2>&1
        dmidecode --type cache > "$hw_dir/dmidecode-cache.txt" 2>&1
        dmidecode --type system > "$hw_dir/dmidecode-system.txt" 2>&1
    fi
    if command -v numactl &>/dev/null; then
        numactl --hardware > "$hw_dir/numa-hardware.txt" 2>&1
        numactl --show > "$hw_dir/numa-policy.txt" 2>&1
    fi
    if [[ -d /sys/devices/system/node ]]; then
        for node_dir in /sys/devices/system/node/node*; do
            node=$(basename "$node_dir")
            cat "$node_dir/meminfo" > "$hw_dir/numa-${node}-meminfo.txt" 2>&1 || true
        done
    fi
    # Collect per-CPU current frequencies
    if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
        for cpu_dir in /sys/devices/system/cpu/cpu*/cpufreq; do
            cpu=$(basename "$(dirname "$cpu_dir")")
            echo "$cpu: cur=$(cat "$cpu_dir/scaling_cur_freq" 2>/dev/null || echo N/A) min=$(cat "$cpu_dir/scaling_min_freq" 2>/dev/null || echo N/A) max=$(cat "$cpu_dir/scaling_max_freq" 2>/dev/null || echo N/A) governor=$(cat "$cpu_dir/scaling_governor" 2>/dev/null || echo N/A)"
        done > "$hw_dir/cpu-frequencies.txt" 2>&1
    fi
    # Azure IMDS full metadata dump
    if command -v curl &>/dev/null; then
        curl -s -H "Metadata:true" --connect-timeout 2 \
            "http://169.254.169.254/metadata/instance?api-version=2021-02-01" 2>/dev/null \
            | jq '.' > "$hw_dir/azure-imds.json" 2>&1 || true
    fi

    echo "    Metadata saved to $meta_file"
    echo "    Raw hardware dumps in $hw_dir"
}

collect_metadata

# Run each selected suite
IFS=',' read -ra SUITE_ARRAY <<< "$SUITES"
for suite in "${SUITE_ARRAY[@]}"; do
    suite=$(echo "$suite" | tr -d ' ')
    script="$SCRIPT_DIR/suites/${suite}.sh"
    if [[ -f "$script" ]]; then
        echo ""
        echo ">>> Running suite: $suite"
        bash "$script" "$OUTPUT_DIR"
    else
        echo "WARNING: Suite script not found: $script — skipping"
    fi
done

echo ""
echo "=============================================="
echo " All benchmarks complete!"
echo " Results: $OUTPUT_DIR"
echo "=============================================="
