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

### One-Command Run

```powershell
# 1. Configure shared infrastructure
cp infra/terraform.tfvars.example infra/terraform.tfvars
# Edit infra/terraform.tfvars — set your subscription_id

# 2. Run everything
.\scripts\Run-Benchmark-All.ps1
```

The orchestration script handles the full lifecycle:
1. **Deploy shared infrastructure** — resource group, VNet, subnet, NAT gateway, NSG, storage account
2. **For each batch of VMs** (default: 2 at a time):
   - Deploy VM via Terraform (NIC, VM, managed identity, role assignment, CustomScript extension)
   - CustomScript extension downloads benchmark scripts from GitHub and launches them in the background
   - Poll Azure Blob Storage for a `DONE` marker blob (uploaded by the VM when benchmarks finish)
   - Download results from blob storage locally
   - Destroy the batch VMs
3. **Score and compare** — parse results into a scored JSON + CSV summary (relative-to-best scoring, weighted composite)
4. **Destroy infrastructure** (unless `-SkipDestroy` is set)

### Options

```powershell
# Custom batch size (deploy 1 VM at a time)
.\scripts\Run-Benchmark-All.ps1 -BatchSize 1

# Only run specific suites
.\scripts\Run-Benchmark-All.ps1 -Suites "cpu,memory"

# Keep infrastructure after benchmarking (for debugging)
.\scripts\Run-Benchmark-All.ps1 -SkipDestroy

# Use a different git branch for benchmark scripts
.\scripts\Run-Benchmark-All.ps1 -GithubRef "dev"
```

### Manual / Step-by-Step

```powershell
# 1. Deploy shared infrastructure
cd infra
terraform init
terraform apply
cd ..

# 2. Deploy a single VM (uses a separate state file)
cd vm
terraform init
terraform apply \
  -state="../states/e64asv5.tfstate" \
  -var="vm_name=e64asv5" \
  -var="vm_size=Standard_E64as_v5" \
  -var="resource_group_name=rg-sap-benchmark" \
  -var="subnet_id=<subnet-id-from-infra-output>" \
  -var="storage_account_id=<storage-id>" \
  -var="storage_account_name=<storage-name>" \
  -var="storage_container_name=benchmark-results"

# 3. Wait for the DONE marker in blob storage, then download results
# 4. Destroy VM
terraform destroy -state="../states/e64asv5.tfstate"
cd ..

# 5. Collect and score results
.\scripts\Collect-Results.ps1

# 6. Destroy shared infrastructure
cd infra && terraform destroy
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
       │  (az storage blob)              │                     │
       │                                 │  CustomScript ext:  │
       │                                 │   - download scripts│
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
- **No SSH, no public IPs** — VMs have only private IPs behind a NAT gateway. Benchmarks execute autonomously via cloud-init + CustomScript extension.
- **GitHub-based script delivery** — The CustomScript extension downloads `vm-entrypoint.sh` from this GitHub repo, which then downloads the full repo tarball and extracts benchmark scripts. No storage account needed for scripts.
- **Blob-based result transfer** — VMs upload results using a system-assigned managed identity with `Storage Blob Data Contributor` role. The storage account uses Entra ID (AAD) authentication only — no shared access keys.
- **DONE marker polling** — Each VM writes a `{vm-name}/DONE` blob when benchmarks finish. The orchestrator polls for these markers rather than waiting on terraform.

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
├── infra/                           # Shared infrastructure (deploy once)
│   ├── providers.tf
│   ├── variables.tf
│   ├── main.tf                      # RG, VNet, subnet, NAT gateway, NSG, storage
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── vm/                              # Per-VM deployment (one state file each)
│   ├── providers.tf
│   ├── variables.tf
│   ├── main.tf                      # NIC, VM, role assignment, CustomScript ext
│   └── outputs.tf
├── scripts/
│   ├── cloud-init.yaml              # VM bootstrap (packages, sysbench from source)
│   ├── vm-entrypoint.sh             # CustomScript entrypoint (download + run + upload)
│   ├── run-benchmarks.sh            # Main benchmark runner with hardware metadata
│   ├── upload-results.sh            # Upload results to blob via managed identity
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

## Default VM Configurations

| Name | VM Size | vCPUs | Memory | Processor |
|------|---------|-------|--------|-----------|
| e64asv5 | Standard_E64as_v5 | 64 | 512 GiB | AMD EPYC 7763 |
| e64sv5 | Standard_E64s_v5 | 64 | 512 GiB | Intel Xeon Platinum 8370C |
| e96asv5 | Standard_E96as_v5 | 96 | 672 GiB | AMD EPYC 7763 |

To benchmark different VM sizes, edit the `$allVms` hashtable in `scripts/Run-Benchmark-All.ps1`.

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
