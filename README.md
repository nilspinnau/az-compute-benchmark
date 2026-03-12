# Azure VM Benchmark Toolkit

A general-purpose benchmarking toolkit for Azure Virtual Machines, with defaults tuned for **SAP Application Server** workloads.

Deploys VMs via Terraform in batches (to respect quota limits), runs standardized benchmarks via `az vm run-command` (no public IPs needed), collects results via Azure Blob Storage, and merges everything into a comparable summary.

## Benchmark Suites

| Suite | Tool | What it measures | SAP relevance |
|-------|------|-----------------|---------------|
| **cpu** | sysbench | Single & multi-threaded CPU, thread scaling | SAPS rating correlation, dialog step latency |
| **memory** | sysbench, STREAM | Memory bandwidth (read/write), NUMA topology | In-memory data processing, buffer pools |
| **disk** | fio | Random/sequential IOPS, throughput, mixed R/W | `/usr/sap`, spool, swap, temp I/O |
| **network** | iperf3 | Loopback throughput, TCP tuning, NIC info | App server ↔ DB communication |
| **system** | UnixBench | Composite system performance score | Overall system comparison |

## Hardware Information Collected

Each benchmark run collects detailed hardware metadata:
- **CPU**: Model, vendor, clock speed (current/max MHz), cache sizes (L1/L2/L3), stepping, flags
- **Memory**: Total size, type (DDR4/DDR5), speed, configured speed, DIMM count, manufacturer
- **NUMA**: Topology and node configuration
- **OS**: Distribution, kernel version
- **Azure**: VM size, location, VM ID (via IMDS)

Raw dumps from `lscpu`, `/proc/cpuinfo`, `/proc/meminfo`, `dmidecode` are also saved.

## Quick Start

### Prerequisites

- [Terraform](https://www.terraform.io/downloads) >= 1.5
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (`az login`)
- SSH key pair (for VM provisioning, no SSH access needed)
- PowerShell 5.1+ (Windows) or pwsh (Linux/macOS)

### One-Command Run (Recommended)

```powershell
# 1. Configure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set your subscription_id and ssh_public_key_path

# 2. Initialize
terraform init

# 3. Run everything — deploys in batches, benchmarks, collects, merges, destroys
.\scripts\Run-Benchmark-All.ps1
```

The orchestration script will:
1. Deploy shared infrastructure (RG, VNet, Storage Account)
2. For each batch of VMs (default: 2 at a time):
   - Deploy VMs
   - Wait for cloud-init to install benchmark tools
   - Upload and run benchmark scripts via `az vm run-command`
   - Upload results to Azure Blob Storage (via managed identity)
   - Download results locally
   - Destroy the batch VMs
3. Merge all results into `results/summary.csv`
4. Destroy all remaining infrastructure

### Options

```powershell
# Custom batch size
.\scripts\Run-Benchmark-All.ps1 -BatchSize 1

# Only run specific suites
.\scripts\Run-Benchmark-All.ps1 -Suites "cpu,memory"

# Keep infrastructure after benchmarking (for debugging)
.\scripts\Run-Benchmark-All.ps1 -SkipDestroy

# Custom VM config file
.\scripts\Run-Benchmark-All.ps1 -ConfigFile my-vms.json
```

### Manual / Partial Run

```powershell
# Deploy specific VMs manually
terraform apply -var 'vm_configs={"e64asv5":{"vm_size":"Standard_E64as_v5"}}'

# Run benchmarks on deployed VMs
.\scripts\Deploy-AndRun.ps1

# Collect and merge results
.\scripts\Collect-Results.ps1

# Cleanup
terraform destroy
```

### Custom VM Configuration File

Create a JSON file (e.g., `my-vms.json`):

```json
{
  "e64asv5": { "vm_size": "Standard_E64as_v5" },
  "e64sv5":  { "vm_size": "Standard_E64s_v5" },
  "e96asv5": { "vm_size": "Standard_E96as_v5" },
  "m128s":   { "vm_size": "Standard_M128s" }
}
```

```powershell
.\scripts\Run-Benchmark-All.ps1 -ConfigFile my-vms.json -BatchSize 1
```

## Architecture

```
No public IPs — all VM communication via az vm run-command + Azure Blob Storage

┌──────────────┐     az vm run-command      ┌─────────────────┐
│  Your Client │ ─────────────────────────►  │  Benchmark VM   │
│  (PowerShell)│                             │  (no public IP) │
└──────┬───────┘                             └────────┬────────┘
       │                                              │
       │  az storage blob download     Managed Identity│
       │                                              │
       │         ┌──────────────────┐                 │
       └────────►│  Storage Account │ ◄───────────────┘
                 │  (results blob)  │   upload-results.sh
                 └──────────────────┘
```

## Project Structure

```
.
├── main.tf                      # VM, network, storage resources
├── variables.tf                 # Configurable parameters
├── outputs.tf                   # VM names, storage info
├── versions.tf                  # Provider versions
├── terraform.tfvars.example     # Example variable values
├── scripts/
│   ├── cloud-init.yaml          # VM bootstrap (installs benchmark tools)
│   ├── run-benchmarks.sh        # Main benchmark runner
│   ├── upload-results.sh        # Upload results to blob storage
│   ├── Run-Benchmark-All.ps1    # Full orchestration (deploy/bench/collect/destroy)
│   ├── Deploy-AndRun.ps1        # Run benchmarks on already-deployed VMs
│   ├── Collect-Results.ps1      # Parse results into summary CSV
│   ├── deploy-and-run.sh        # Bash equivalent (for Linux/macOS clients)
│   ├── collect-results.sh       # Bash equivalent
│   ├── run-network-pair.sh      # Cross-VM iperf3 tests
│   └── suites/
│       ├── cpu.sh               # sysbench CPU benchmarks
│       ├── memory.sh            # sysbench memory + STREAM
│       ├── disk.sh              # fio I/O benchmarks
│       ├── network.sh           # iperf3 + NIC diagnostics
│       └── system.sh            # UnixBench composite score
└── results/                     # Benchmark output (gitignored)
```

## Adding Custom Benchmark Suites

Create a new script in `scripts/suites/`:

```bash
#!/usr/bin/env bash
set -euo pipefail
OUTPUT_DIR="$1"
RESULTS_DIR="$OUTPUT_DIR/custom"
mkdir -p "$RESULTS_DIR"
# Your benchmark commands here...
echo "    [custom] Done. Results in $RESULTS_DIR"
```

Then run with: `--Suites "cpu,memory,custom"`

## Default VM Configurations

| Name | VM Size | vCPUs | Memory | Processor |
|------|---------|-------|--------|-----------|
| e64asv5 | Standard_E64as_v5 | 64 | 512 GiB | AMD EPYC 7763 |
| e64sv5 | Standard_E64s_v5 | 64 | 512 GiB | Intel Xeon Platinum 8370C |
| e96asv5 | Standard_E96as_v5 | 96 | 672 GiB | AMD EPYC 7763 |

## License

MIT
