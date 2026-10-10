# Beispiel: core mit keyvault, so wie ein Projekt mit features.keyVault = true sie verbindet.

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
  features {
    key_vault {
      # Mit Purge-Schutz lässt sich ein gelöschter Vault ohnehin nicht endgültig entfernen; ein
      # gleichnamiger, soft-gelöschter Vault wird beim nächsten Apply wiederhergestellt.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
  storage_use_azuread = true
}

provider "azapi" {}

module "core" {
  source = "../../core"

  name         = "example"
  environment  = "dev"
  app_settings = merge({ Seed__Features__KeyVault = "true" }, module.keyvault.app_settings)
}

module "keyvault" {
  source = "../../keyvault"

  name                           = "example"
  environment                    = "dev"
  resource_group_name            = module.core.resource_group_name
  location                       = module.core.location
  function_identity_principal_id = module.core.function_identity_principal_id
  secrets                        = ["stripe-key", "smtp-password"]
  secret_officers                = ["00000000-0000-0000-0000-000000000000"]
}

output "key_vault_name" {
  value = module.keyvault.key_vault_name
}

output "setting_names" {
  value = module.keyvault.setting_names
}
