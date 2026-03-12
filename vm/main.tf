locals {
  cloud_init = templatefile("${path.module}/../scripts/cloud-init.yaml", {
    admin_username   = var.admin_username
    storage_account  = var.storage_account_name
    container_name   = var.storage_container_name
    github_repo_url  = var.github_repo_url
    github_ref       = var.github_ref
    benchmark_suites = var.benchmark_suites
  })
}

resource "azurerm_network_interface" "this" {
  name                           = "nic-bench-${var.vm_name}"
  location                       = var.location
  resource_group_name            = var.resource_group_name
  accelerated_networking_enabled = true
  tags                           = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "this" {
  name                  = "vm-bench-${var.vm_name}"
  location              = var.location
  resource_group_name   = var.resource_group_name
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.this.id]

  custom_data = base64encode(local.cloud_init)

  identity {
    type = "SystemAssigned"
  }

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key_path)
  }

  os_disk {
    name                 = "osdisk-bench-${var.vm_name}"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = var.os_image.publisher
    offer     = var.os_image.offer
    sku       = var.os_image.sku
    version   = var.os_image.version
  }

  tags = merge(var.tags, {
    vm_size = var.vm_size
  })
}

resource "azurerm_role_assignment" "blob_contributor" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_virtual_machine.this.identity[0].principal_id
}
