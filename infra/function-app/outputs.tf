output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.main.name
}

output "function_app_name" {
  description = "Name of the Function App"
  value       = module.function_app.function_app_name
}

output "function_app_url" {
  description = "URL of the Function App"
  value       = module.function_app.function_app_url
}

output "storage_account_name" {
  description = "Name of the persistent results storage account"
  value       = module.storage.storage_account_name
}

output "managed_identity_client_id" {
  description = "Client ID of the managed identity"
  value       = module.function_app.managed_identity_client_id
}
