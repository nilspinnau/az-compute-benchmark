variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group for the Function App infrastructure"
  type        = string
  default     = "rg-sap-benchmark-orchestrator"
}

variable "location" {
  description = "Azure region for all persistent resources"
  type        = string
  default     = "swedencentral"
}

variable "name_suffix" {
  description = "Suffix for resource names to ensure uniqueness"
  type        = string
  default     = "sapbench"
}

variable "durable_task_hub_name" {
  description = "Name of the Durable Task hub"
  type        = string
  default     = "sapbench"

  validation {
    condition     = can(regex("^[a-zA-Z0-9]+$", var.durable_task_hub_name))
    error_message = "Durable task hub name must be alphanumeric only."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    environment = "benchmark"
    project     = "sap-vm-benchmark"
  }
}
