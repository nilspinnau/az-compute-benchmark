resource "random_string" "storage" {
  length  = 8
  special = false
  upper   = false
}

resource "azurerm_storage_account" "results" {
  name                            = "stbenchres${random_string.storage.result}"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true
  local_user_enabled              = false
  tags                            = var.tags

  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }
}

resource "azurerm_storage_container" "results" {
  name                  = "benchmark-results"
  storage_account_id    = azurerm_storage_account.results.id
  container_access_type = "private"
}

# Grant current deployer access to results storage
data "azurerm_client_config" "current" {}

resource "azurerm_role_assignment" "deployer_blob_contributor" {
  scope                = azurerm_storage_account.results.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}
