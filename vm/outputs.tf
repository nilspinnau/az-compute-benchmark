output "vm_name" {
  description = "Name of the deployed VM"
  value       = azurerm_linux_virtual_machine.this.name
}

output "vm_size" {
  description = "Size of the deployed VM"
  value       = azurerm_linux_virtual_machine.this.size
}

output "vm_principal_id" {
  description = "Managed identity principal ID"
  value       = azurerm_linux_virtual_machine.this.identity[0].principal_id
}
