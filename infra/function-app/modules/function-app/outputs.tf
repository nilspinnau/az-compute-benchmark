output "function_app_name" {
  description = "Name of the Function App"
  value       = azurerm_function_app_flex_consumption.orchestrator.name
}

output "function_app_url" {
  description = "URL of the Function App"
  value       = "https://${azurerm_function_app_flex_consumption.orchestrator.default_hostname}"
}

output "managed_identity_client_id" {
  description = "Client ID of the managed identity"
  value       = azurerm_user_assigned_identity.this.client_id
}

output "managed_identity_principal_id" {
  description = "Principal ID of the managed identity"
  value       = azurerm_user_assigned_identity.this.principal_id
}

output "managed_identity_id" {
  description = "Resource ID of the managed identity (for attaching to VMs)"
  value       = azurerm_user_assigned_identity.this.id
}
