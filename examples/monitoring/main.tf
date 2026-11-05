# Beispiel: core mit monitoring, so wie ein Projekt mit monitoring.recipients oder owner in
# project.yaml sie verbindet. Ohne Empfänger und ohne owner entfällt das Modul (count = 0). Mit
# features.keyVault meldet es auch, bevor ein Secret mit Ablaufdatum abläuft.

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
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
  storage_use_azuread = true

  # Logic App des Health-Checks und Event Grid für den Alarm zum Ablauf von Secrets.
  resource_providers_to_register = ["Microsoft.Logic", "Microsoft.EventGrid"]
}

provider "azapi" {}

locals {
  alert_emails = ["betrieb@example.org"]
  # owner in project.yaml: Tag owner an allen Ressourcen und zusätzlicher Empfänger der Alarme.
  owner     = "team@example.org"
  key_vault = true
}

module "core" {
  source = "../../core"

  name               = "example"
  environment        = "dev"
  static_web_app_sku = "None"
  log_daily_quota_gb = 0.5
  owner              = local.owner
  app_settings       = merge({}, [for m in module.keyvault : m.app_settings]...)
}

module "keyvault" {
  source = "../../keyvault"
  count  = local.key_vault ? 1 : 0

  name                           = "example"
  environment                    = "dev"
  resource_group_name            = module.core.resource_group_name
  location                       = module.core.location
  function_identity_principal_id = module.core.function_identity_principal_id
  secrets                        = ["stripe-key"]
  owner                          = local.owner
}

module "monitoring" {
  source = "../../monitoring"
  count  = length(local.alert_emails) > 0 || local.owner != null ? 1 : 0

  name                       = "example"
  environment                = "dev"
  owner                      = local.owner
  resource_group_name        = module.core.resource_group_name
  resource_group_id          = module.core.resource_group_id
  location                   = module.core.location
  application_insights_id    = module.core.application_insights_id
  log_analytics_workspace_id = module.core.log_analytics_workspace_id
  alert_emails               = local.alert_emails
  health_check_url           = "${module.core.function_app_url}/api/health"
  exception_threshold        = 5
  budget_amount              = 20
  # Fester Schlüssel statt der Vault-ID: Die Schlüssel stehen so schon im Plan fest, auch wenn
  # der Vault erst im selben Apply entsteht.
  key_vault_ids = { for m in module.keyvault : "keyvault" => m.key_vault_id }
}

output "action_group_id" {
  value = one(module.monitoring[*].action_group_id)
}
