resource "random_string" "storage" {
  length  = 8
  special = false
  upper   = false
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# --- Storage account for result collection ---

resource "azurerm_storage_account" "this" {
  name                     = "stbench${random_string.storage.result}"
  location                 = azurerm_resource_group.this.location
  resource_group_name      = azurerm_resource_group.this.name
  account_tier             = "Standard"
  account_replication_type = "LRS"

  shared_access_key_enabled       = false
  public_network_access_enabled   = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  local_user_enabled              = false
  tags                            = var.tags

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }

  lifecycle {
    ignore_changes = [public_network_access_enabled, network_rules[0].default_action]
  }
}

resource "azurerm_storage_container" "results" {
  name                  = "benchmark-results"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# Grant current user data-plane access to blob storage
data "azurerm_client_config" "current" {}

resource "azurerm_role_assignment" "client_blob_contributor" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# --- Networking (no public IPs) ---

resource "azurerm_virtual_network" "this" {
  name                = "vnet-benchmark"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "this" {
  name                 = "snet-benchmark"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.address_space, 1, 0)]
}

resource "azurerm_subnet" "pe" {
  name                 = "snet-privateendpoints"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.address_space, 5, 16)]
}

# --- NAT Gateway for outbound internet (GitHub, blob storage) ---

resource "azurerm_public_ip" "nat" {
  name                = "pip-nat-benchmark"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  name                    = "nat-benchmark"
  location                = azurerm_resource_group.this.location
  resource_group_name     = azurerm_resource_group.this.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "this" {
  subnet_id      = azurerm_subnet.this.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

# --- NSG ---

resource "azurerm_network_security_group" "this" {
  name                = "nsg-benchmark"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "this" {
  subnet_id                 = azurerm_subnet.this.id
  network_security_group_id = azurerm_network_security_group.this.id
}

# --- Private endpoint for blob storage ---

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  name                  = "link-blob-benchmark"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.blob.name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "blob" {
  name                = "pe-stbench-blob"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-stbench-blob"
    private_connection_resource_id = azurerm_storage_account.this.id
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }
}
