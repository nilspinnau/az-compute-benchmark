locals {
  tags = merge(var.tags, {
    managed_by = "terraform"
    component  = "benchmark-orchestrator"
  })
}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

module "storage" {
  source = "./modules/storage"

  name_suffix         = var.name_suffix
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
}

module "function_app" {
  source = "./modules/function-app"

  name_suffix                  = var.name_suffix
  resource_group_name          = azurerm_resource_group.main.name
  location                     = azurerm_resource_group.main.location
  subscription_id              = var.subscription_id
  results_storage_account_name = module.storage.storage_account_name
  results_storage_account_id   = module.storage.storage_account_id
  results_container_name       = module.storage.container_name
  durable_task_hub_name        = var.durable_task_hub_name
  tags                         = local.tags
}
