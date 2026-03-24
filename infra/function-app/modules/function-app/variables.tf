variable "name_suffix" {
  description = "Suffix for resource names"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "subscription_id" {
  description = "Azure subscription ID (for Contributor role scope)"
  type        = string
}

variable "results_storage_account_name" {
  description = "Name of the persistent results storage account"
  type        = string
}

variable "results_storage_account_id" {
  description = "Resource ID of the persistent results storage account"
  type        = string
}

variable "results_container_name" {
  description = "Name of the results blob container"
  type        = string
}

variable "durable_task_hub_name" {
  description = "Name of the Durable Task hub"
  type        = string
  default     = "sapbench"
}

variable "tags" {
  description = "Tags to apply"
  type        = map(string)
  default     = {}
}
