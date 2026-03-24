# SAP VM Benchmark Orchestrator

An Azure Function App that benchmarks Azure VM SKUs for SAP workloads. Triggered via HTTP, it deploys ephemeral VMs, runs comprehensive benchmarks, scores results, and cleans up automatically.

## Architecture

```
POST /api/HttpStart
       |
       v  (202 + status polling URL)
 +-------------------------------------------------------------+
 |  Durable Functions Orchestrator                              |
 |                                                              |
 |  1. Create ephemeral resource group                          |
 |  2. Deploy shared infra (VNet, NAT, storage, NSG, PE)        |
 |  3. Fan-out: deploy N benchmark VMs in parallel              |
 |  4. Poll blob storage for DONE markers (durable timer)       |
 |  5. Collect + score results (relative 0-100 scoring)         |
 |  6. Upload results to persistent storage                     |
 |  7. Delete ephemeral resource group                          |
 +-------------------------------------------------------------+
```

### What Each VM Runs (via cloud-init)

| Suite | Tool | Key Metrics |
|-------|------|-------------|
| CPU | sysbench | Single/multi-thread events/sec, latency, context switching, mutex |
| Memory | sysbench + STREAM | Sequential/random bandwidth, STREAM Triad, NUMA |
| Disk | fio | Random/sequential IOPS, throughput, P99 latencies |
| Network | iperf3 + ethtool | Loopback throughput, NIC accelerated networking |
| System | UnixBench | Composite system score |

## Prerequisites

- Azure subscription with Contributor access
- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
- [Terraform >= 1.5](https://www.terraform.io/downloads)
- [Azure Functions Core Tools v4](https://docs.microsoft.com/en-us/azure/azure-functions/functions-run-local)
- PowerShell 7+

## Deployment

### 1. Deploy Infrastructure

```bash
cd infra/function-app
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your subscription ID

terraform init
terraform apply
```

### 2. Download Az Modules (one-time)

```powershell
.\scripts\Install-FunctionModules.ps1
```

### 3. Publish Function App

```powershell
.\scripts\Publish-FunctionApp.ps1 `
    -FunctionAppName "func-bench-sapbench" `
    -ResourceGroupName "rg-sap-benchmark-orchestrator"
```

## Usage

### Trigger a Benchmark Run

```bash
curl -X POST 'https://<function-app>.azurewebsites.net/api/HttpStart?code=<function-key>' \
  -H 'Content-Type: application/json' \
  -d '{
    "location": "swedencentral",
    "benchmarkSuites": "cpu,memory,disk,network,system",
    "vms": {
      "e8asv5": { "vmSize": "Standard_E8as_v5" },
      "e8sv5":  { "vmSize": "Standard_E8s_v5" },
      "e8asv6": { "vmSize": "Standard_E8as_v6" }
    }
  }'
```

### Response (202 Accepted)

```json
{
  "id": "<instance-id>",
  "statusQueryGetUri": "https://.../instances/<instance-id>",
  "terminatePostUri": "https://.../instances/<instance-id>/terminate"
}
```

Poll `statusQueryGetUri` until `runtimeStatus` is `Completed`. The `output` field contains the scored results.

### Request Schema

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `vms` | object | **Yes** | - | Map of VM key to `{ vmSize: "Standard_..." }` |
| `location` | string | No | `swedencentral` | Azure region |
| `benchmarkSuites` | string | No | `cpu,memory,disk,network,system` | Comma-separated suites |
| `githubRef` | string | No | `main` | Git branch/tag for benchmark scripts |
| `maxWaitMinutes` | int | No | `120` | Max wait for benchmarks (1-240) |
| `addressSpace` | string | No | `10.0.0.0/24` | VNet CIDR for ephemeral network |

See `config/benchmark-request.example.json` for a full example.

### Scoring

Results are scored relative-to-best (0-100 per metric), with weighted categories:
- **CPU**: 40%
- **Memory**: 30%
- **Disk**: 20%
- **System**: 10%

## Security

- **No public IPs** on benchmark VMs - outbound only via NAT gateway
- **Managed identity** authentication everywhere (no shared keys)
- **Private endpoints** for all storage accounts
- **NSG deny-all inbound** on benchmark subnet
- **Ephemeral resources** - automatically deleted after each run
- **Input validation** - VM sizes, GitHub URLs, locations all sanitized
- **Function-level auth** - HTTP endpoint requires function key
- **No SSH access** - NSG blocks all inbound traffic; VMs are fully ephemeral

## Project Structure

```
function-app/              # PowerShell Durable Functions app
  HttpStart/               # HTTP POST trigger
  Orchestrator/            # Main orchestration logic
  Activity-CreateResourceGroup/
  Activity-DeployInfra/    # VNet, NAT, storage, NSG, PE
  Activity-DeployVM/       # VM + cloud-init + role assignment
  Activity-PollCompletion/ # Check blob DONE markers
  Activity-CollectResults/ # Download, parse, score, upload
  Activity-Cleanup/        # Delete ephemeral RG

infra/function-app/        # Terraform for persistent infra
  modules/function-app/    # Function App, managed identity, VNet
  modules/storage/         # Results storage account

scripts/                   # Deployment and VM benchmark scripts
  Publish-FunctionApp.ps1  # Publish function code
  Install-FunctionModules.ps1  # Download Az modules
  run-benchmarks.sh        # Main benchmark runner (on VMs)
  upload-results.sh        # Upload results to blob (on VMs)
  suites/                  # Individual benchmark suites (on VMs)

config/                    # Example request payloads
```

## License

See [LICENSE](LICENSE).
