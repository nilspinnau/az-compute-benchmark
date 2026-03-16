# Azure VM Benchmark Toolkit

A general-purpose benchmarking toolkit for Azure Virtual Machines, with defaults tuned for **SAP Application Server** workloads.

Deploys VMs via Terraform in batches (respecting quota limits), runs standardized benchmarks automatically via the Azure CustomScript extension, collects results via Azure Blob Storage, and produces a scored comparison summary. No public IPs or SSH access required.

## Benchmark Suites

| Suite | Tool | What it measures | SAP relevance |
|-------|------|-----------------|---------------|
| **cpu** | sysbench | Single & multi-threaded CPU, thread scaling, context switching | SAPS rating correlation, dialog step latency |
| **memory** | sysbench, STREAM | Memory bandwidth (read/write), NUMA cross-node | In-memory data processing, buffer pools |
| **disk** | fio | Random/sequential IOPS, throughput, mixed R/W, latency percentiles | `/usr/sap`, spool, swap, temp I/O |
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
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (logged in via `az login`)
- SSH key pair (for VM provisioning — no SSH access is used at runtime)
- PowerShell 5.1+ (Windows) or pwsh (Linux/macOS)

### Setup

```powershell
# 1. Create your config file from the example
cp benchmark.example.json benchmark.json

# 2. Edit benchmark.json — set at minimum:
#    - subscription_id: your Azure subscription
#    - ssh_public_key_path: path to your SSH public key
#    - vms: the VM SKUs you want to benchmark
```

### One-Command Run

```powershell
.\scripts\Run-Benchmark-All.ps1
```

The orchestration script handles the full lifecycle:
1. **Deploy shared infrastructure** — resource group, VNet, subnet, NAT gateway, NSG, storage account
2. **Deploy all VMs in parallel** via Terraform (NIC, VM, managed identity, role assignment)
3. cloud-init installs tools, builds sysbench, downloads scripts from GitHub, and runs benchmarks autonomously
4. **Poll** Azure Blob Storage for `DONE` marker blobs (uploaded by each VM when benchmarks finish)
5. **Download results** from blob storage locally
6. **Destroy VMs and infrastructure** (unless `-SkipDestroy` is set)
7. **Score and compare** — parse results into a scored JSON + CSV summary

### Options

```powershell
# Deploy specific VMs only (keys must exist in benchmark.json)
.\scripts\Run-Benchmark-All.ps1 -VmNames "e8asv5,e8sv5"

# Only run specific suites
.\scripts\Run-Benchmark-All.ps1 -Suites "cpu,memory"

# Keep infrastructure after benchmarking (for debugging)
.\scripts\Run-Benchmark-All.ps1 -SkipDestroy

# Use a different git branch for benchmark scripts
.\scripts\Run-Benchmark-All.ps1 -GithubRef "dev"

# Use a custom config file
.\scripts\Run-Benchmark-All.ps1 -ConfigFile "./my-benchmark.json"
```

### Manual / Step-by-Step

```powershell
# 1. Deploy infrastructure and VMs
.\scripts\Deploy-Benchmark.ps1

# 2. Download results when ready, then destroy
.\scripts\Download-Results.ps1 -DestroyVms -DestroyInfra

# 3. Re-score existing local results
.\scripts\Collect-Results.ps1
```

## Architecture

```
No public IPs — VMs use NAT gateway for outbound internet only.
Scripts are downloaded from GitHub. Results are uploaded via managed identity.

┌──────────────────┐                     ┌─────────────────────┐
│  Client Machine  │   terraform apply   │   Benchmark VM      │
│  (PowerShell +   │ ─────────────────►  │   (no public IP)    │
│   Terraform)     │                     │                     │
└──────┬───────────┘                     │  cloud-init:        │
       │                                 │   - install tools   │
       │  Poll DONE marker               │   - build sysbench  │
       │  (az storage blob)              │   - download scripts│
       │                                 │     from GitHub     │
       │                                 │   - run benchmarks  │
       │                                 │   - upload results  │
       │                                 │   - write DONE blob │
       │         ┌──────────────────┐    └────────┬────────────┘
       │         │  Storage Account │             │
       └────────►│  (Entra ID auth) │ ◄───────────┘
                 │                  │   Managed Identity
                 └──────────────────┘
                         ▲
                         │
                 ┌───────┴────────┐
                 │  NAT Gateway   │
                 │  (outbound)    │
                 └────────────────┘
```

### Key Design Decisions

- **Split Terraform layout** — `infra/` deploys shared resources once; `vm/` deploys one VM per apply with a separate state file per VM. This allows batch deployment and independent teardown.
- **No SSH, no public IPs** — VMs have only private IPs behind a NAT gateway. Benchmarks execute autonomously via cloud-init.
- **GitHub-based script delivery** — cloud-init downloads the full repo tarball from GitHub and extracts benchmark scripts. No storage account needed for scripts.
- **Blob-based result transfer** — VMs upload results using a system-assigned managed identity with `Storage Blob Data Contributor` role. The storage account uses Entra ID (AAD) authentication only — no shared access keys.
- **DONE marker polling** — Each VM writes a `{vm-name}/DONE` blob when benchmarks finish. The orchestrator polls for these markers. Since all benchmark work runs via cloud-init (asynchronous to terraform), terraform apply returns quickly after provisioning the VM.

## Scoring System

Results are scored using a **relative-to-best** approach:
- Each metric is scored 0–100, where 100 = best result across all VMs tested
- Metrics are grouped into categories with configurable weights:
  - **CPU** (40%): sysbench events/sec, thread scaling efficiency
  - **Memory** (30%): sysbench throughput, STREAM bandwidth
  - **Disk** (20%): fio IOPS, throughput, latency
  - **System** (10%): UnixBench composite score
- A weighted composite score provides a single ranking number

Output: `results/summary.json` and `results/summary.csv`

## Project Structure

```
.
├── benchmark.example.json           # Example config file (copy to benchmark.json)
├── infra/                           # Shared infrastructure (deploy once)
│   ├── providers.tf
│   ├── variables.tf
│   ├── main.tf                      # RG, VNet, subnet, NAT gateway, NSG, storage
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── vm/                              # Per-VM deployment (one state file each)
│   ├── providers.tf
│   ├── variables.tf
│   ├── main.tf                      # NIC, VM, managed identity, role assignment
│   └── outputs.tf
├── scripts/
│   ├── cloud-init.yaml              # VM bootstrap (packages, sysbench, benchmarks)
│   ├── vm-entrypoint.sh             # Standalone entrypoint (alternative to cloud-init)
│   ├── run-benchmarks.sh            # Main benchmark runner with hardware metadata
│   ├── upload-results.sh            # Upload results to blob via managed identity
│   ├── Deploy-Benchmark.ps1         # Deploy infra + VMs (PowerShell)
│   ├── Download-Results.ps1         # Poll, download, destroy (PowerShell)
│   ├── Run-Benchmark-All.ps1        # Full orchestration (PowerShell)
│   ├── Collect-Results.ps1          # Parse + score results (PowerShell)
│   ├── collect-results.sh           # Parse + score results (Bash)
│   ├── run-network-pair.sh          # Cross-VM iperf3 tests
│   └── suites/
│       ├── cpu.sh                   # sysbench CPU benchmarks
│       ├── memory.sh               # sysbench memory + STREAM
│       ├── disk.sh                  # fio I/O benchmarks
│       ├── network.sh              # iperf3 + NIC diagnostics
│       └── system.sh               # UnixBench composite score
├── states/                          # Per-VM Terraform state files (gitignored)
├── results/                         # Benchmark output (gitignored)
├── .gitattributes                   # LF for .sh/.yaml/.tf, CRLF for .ps1
└── .gitignore
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

Then include it: `-Suites "cpu,memory,custom"`

## Configuration

All user settings live in `benchmark.json` (gitignored). Copy the example to get started:

```bash
cp benchmark.example.json benchmark.json
```

| Field | Description | Required |
|-------|-------------|----------|
| `subscription_id` | Azure subscription ID | Yes |
| `location` | Azure region | Yes |
| `ssh_public_key_path` | Path to SSH public key | Yes |
| `vms` | Map of VM key → `{ "vm_size": "Standard_..." }` | Yes |
| `resource_group_name` | Resource group name | No (default: `rg-sap-benchmark`) |
| `address_space` | VNet CIDR | No (default: `10.0.0.0/24`) |
| `os_image` | OS image (publisher/offer/sku/version) | No (default: SLES SAP 15 SP5) |
| `os_disk_size_gb` | OS disk size | No (default: 64) |
| `benchmark_suites` | Comma-separated suites to run | No (default: all) |
| `github_repo_url` | Repo URL for benchmark scripts | No |
| `github_ref` | Branch/tag/commit | No (default: `main`) |
| `max_wait_minutes` | Polling timeout | No (default: 120) |
| `tags` | Azure resource tags | No |

Example `benchmark.json`:

```json
{
  "subscription_id": "00000000-0000-0000-0000-000000000000",
  "location": "swedencentral",
  "ssh_public_key_path": "~/.ssh/id_rsa.pub",
  "vms": {
    "e8asv5": { "vm_size": "Standard_E8as_v5" },
    "e8sv5":  { "vm_size": "Standard_E8s_v5" },
    "d32sv5": { "vm_size": "Standard_D32s_v5" }
  }
}
```

To benchmark different VM sizes, just edit the `vms` section — no code changes needed.

## Requirements

| Component | Version |
|-----------|---------|
| Terraform | >= 1.5 |
| AzureRM Provider | ~> 4.0 |
| Azure CLI | Latest |
| PowerShell | 5.1+ (Windows) / pwsh (Linux/macOS) |
| OS Image | SUSE SLES for SAP 15 SP5 (configurable) |

## License

MIT
