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
  public_network_access_enabled   = true
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  local_user_enabled              = false
  tags                            = var.tags
}

resource "azurerm_storage_container" "results" {
  name                  = "benchmark-results"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
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
  address_prefixes     = [var.address_space]
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
