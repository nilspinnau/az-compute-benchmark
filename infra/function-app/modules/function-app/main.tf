# --- Managed Identity ---

resource "azurerm_user_assigned_identity" "this" {
  name                = "id-bench-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# Contributor at subscription scope (needed to create ephemeral RGs, VMs, networking)
resource "azurerm_role_assignment" "contributor" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# Storage Blob Data Contributor at subscription scope (needed to poll/access ephemeral storage accounts)
resource "azurerm_role_assignment" "subscription_blob_contributor" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# Storage Blob Data Contributor on results storage
resource "azurerm_role_assignment" "results_blob_contributor" {
  scope                = var.results_storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# --- VNet for Function App integration ---

resource "azurerm_virtual_network" "func" {
  name                = "vnet-func-bench-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = ["10.200.0.0/24"]
  tags                = var.tags
}

resource "azurerm_subnet" "func_integration" {
  name                 = "snet-func-integration"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.func.name
  address_prefixes     = ["10.200.0.0/25"]

  delegation {
    name = "func-delegation"
    service_delegation {
      name = "Microsoft.App/environments"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/action",
      ]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.func.name
  address_prefixes     = ["10.200.0.128/25"]
}

# --- Storage account for Function App runtime ---

resource "random_string" "func_storage" {
  length  = 8
  special = false
  upper   = false
}

resource "azurerm_storage_account" "func" {
  name                            = "stfuncbn${random_string.func_storage.result}"
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
}

# Role assignments for function app on its own storage
resource "azurerm_role_assignment" "func_storage_blob" {
  scope                = azurerm_storage_account.func.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_role_assignment" "func_storage_table" {
  scope                = azurerm_storage_account.func.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_role_assignment" "func_storage_queue" {
  scope                = azurerm_storage_account.func.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

# --- Private DNS zones + endpoints for function storage ---

locals {
  storage_dns_zones = {
    blob  = "privatelink.blob.core.windows.net"
    table = "privatelink.table.core.windows.net"
    queue = "privatelink.queue.core.windows.net"
  }
}

resource "azurerm_private_dns_zone" "storage" {
  for_each            = local.storage_dns_zones
  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage" {
  for_each              = local.storage_dns_zones
  name                  = "link-${each.key}-func"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.storage[each.key].name
  virtual_network_id    = azurerm_virtual_network.func.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "func_storage" {
  for_each            = local.storage_dns_zones
  name                = "pe-funcst-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-funcst-${each.key}"
    private_connection_resource_id = azurerm_storage_account.func.id
    is_manual_connection           = false
    subresource_names              = [each.key]
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage[each.key].id]
  }
}

# Private endpoint for results storage (so the Function App can access it via VNet)
resource "azurerm_private_endpoint" "results_storage_blob" {
  name                = "pe-resultsst-blob"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-resultsst-blob"
    private_connection_resource_id = var.results_storage_account_id
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage["blob"].id]
  }
}

# --- Flex Consumption Plan + Function App ---

resource "azurerm_service_plan" "func" {
  name                = "asp-bench-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = var.tags
}

resource "azurerm_function_app_flex_consumption" "orchestrator" {
  name                = "func-bench-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  service_plan_id     = azurerm_service_plan.func.id
  tags                = var.tags

  https_only = true

  storage_container_type              = "blobContainer"
  storage_container_endpoint          = "${azurerm_storage_account.func.primary_blob_endpoint}function-releases"
  storage_authentication_type         = "UserAssignedIdentity"
  storage_user_assigned_identity_id   = azurerm_user_assigned_identity.this.id

  runtime_name    = "powershell"
  runtime_version = "7.4"

  virtual_network_subnet_id = azurerm_subnet.func_integration.id

  site_config {}

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.this.id]
  }

  app_settings = {
    "AZURE_CLIENT_ID"                        = azurerm_user_assigned_identity.this.client_id
    "RESULTS_STORAGE_ACCOUNT_NAME"           = var.results_storage_account_name
    "RESULTS_CONTAINER_NAME"                 = var.results_container_name
    "DURABLE_TASK_HUB_NAME"                  = var.durable_task_hub_name
    "VM_IDENTITY_RESOURCE_ID"                = azurerm_user_assigned_identity.this.id
    "VM_IDENTITY_CLIENT_ID"                  = azurerm_user_assigned_identity.this.client_id
    "WEBSITE_VNET_ROUTE_ALL"                 = "1"
    "AzureWebJobsStorage__accountName"       = azurerm_storage_account.func.name
    "AzureWebJobsStorage__credential"        = "managedidentity"
    "AzureWebJobsStorage__clientId"          = azurerm_user_assigned_identity.this.client_id
  }

  depends_on = [
    azurerm_storage_container.function_releases,
    azurerm_private_endpoint.func_storage,
    azurerm_role_assignment.func_storage_blob,
    azurerm_role_assignment.func_storage_table,
    azurerm_role_assignment.func_storage_queue,
  ]
}

resource "azurerm_storage_container" "function_releases" {
  name                  = "function-releases"
  storage_account_id    = azurerm_storage_account.func.id
  container_access_type = "private"
}
