variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "swedencentral"
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "rg-sap-benchmark"
}

variable "address_space" {
  description = "VNet address space"
  type        = string
  default     = "10.0.0.0/24"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    environment = "benchmark"
    project     = "sap-vm-benchmark"
  }
}
