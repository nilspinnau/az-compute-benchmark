output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.this.name
}

output "location" {
  description = "Azure region"
  value       = azurerm_resource_group.this.location
}

output "subnet_id" {
  description = "Subnet ID for benchmark VMs"
  value       = azurerm_subnet.this.id
}

output "storage_account_id" {
  description = "Storage account resource ID"
  value       = azurerm_storage_account.this.id
}

output "storage_account_name" {
  description = "Storage account name for benchmark results"
  value       = azurerm_storage_account.this.name
}

output "storage_container_name" {
  description = "Blob container name for benchmark results"
  value       = azurerm_storage_container.results.name
}
