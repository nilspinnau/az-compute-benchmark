output "storage_account_name" {
  description = "Name of the results storage account"
  value       = azurerm_storage_account.results.name
}

output "storage_account_id" {
  description = "Resource ID of the results storage account"
  value       = azurerm_storage_account.results.id
}

output "container_name" {
  description = "Name of the results blob container"
  value       = azurerm_storage_container.results.name
}
