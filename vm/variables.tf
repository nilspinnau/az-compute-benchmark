variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the existing resource group (from infra)"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for the VM NIC (from infra)"
  type        = string
}

variable "storage_account_id" {
  description = "Storage account resource ID for role assignment (from infra)"
  type        = string
}

variable "storage_account_name" {
  description = "Storage account name (from infra)"
  type        = string
}

variable "storage_container_name" {
  description = "Blob container name (from infra)"
  type        = string
}

variable "vm_name" {
  description = "Short name for the VM (used in resource names, e.g. 'e64asv5')"
  type        = string
}

variable "vm_size" {
  description = "Azure VM size (e.g. 'Standard_E64as_v5')"
  type        = string
}

variable "admin_username" {
  description = "Admin username for the VM"
  type        = string
  default     = "azureadmin"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key file"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "os_image" {
  description = "OS image for the benchmark VM"
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = {
    publisher = "SUSE"
    offer     = "sles-sap-15-sp5"
    sku       = "gen2"
    version   = "latest"
  }
}

variable "os_disk_size_gb" {
  description = "OS disk size in GB"
  type        = number
  default     = 64
}

variable "os_disk_type" {
  description = "OS disk storage account type"
  type        = string
  default     = "Premium_LRS"
}

variable "github_repo_url" {
  description = "GitHub repository URL (HTTPS) for benchmark scripts"
  type        = string
  default     = "https://github.com/nilspinnau/az-compute-benchmark"
}

variable "github_ref" {
  description = "Git branch, tag, or commit hash to use for benchmark scripts"
  type        = string
  default     = "main"
}

variable "benchmark_suites" {
  description = "Comma-separated benchmark suites to run"
  type        = string
  default     = "cpu,memory,disk,network,system"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    environment = "benchmark"
    project     = "sap-vm-benchmark"
  }
}
