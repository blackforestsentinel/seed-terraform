# Beispiel: core mit storage, so wie ein Projekt mit features.storage = true sie verbindet.

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "5.9.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "2.13.0"
    }
  }
}

provider "azurerm" {
  features {}
  storage_use_azuread = true
}

provider "azapi" {}

module "core" {
  source = "../../core"

  name               = "example"
  environment        = "dev"
  static_web_app_sku = "None"
  app_settings       = merge({ Seed__Features__Storage = "true" }, module.storage.app_settings)
}

module "storage" {
  source = "../../storage"

  name                           = "example"
  environment                    = "dev"
  resource_group_name            = module.core.resource_group_name
  location                       = module.core.location
  function_identity_principal_id = module.core.function_identity_principal_id
  function_identity_client_id    = module.core.function_identity_client_id

  tables     = ["jobs"]
  queues     = ["jobs"]
  containers = ["uploads"]

  lifecycle_rules = [
    {
      name              = "uploads-90-tage"
      prefixes          = ["uploads/"]
      cool_after_days   = 30
      delete_after_days = 90
    },
  ]
}

output "storage_account_name" {
  value = module.storage.storage_account_name
}

output "function_app_url" {
  value = module.core.function_app_url
}
