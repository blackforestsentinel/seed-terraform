# Beispiel: core mit monitoring, so wie ein Projekt mit monitoring.recipients in project.yaml
# sie verbindet. Ohne Empfänger entfällt das Modul (count = 0).

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

locals {
  alert_emails = ["betrieb@example.org"]
}

module "core" {
  source = "../../core"

  name               = "example"
  environment        = "dev"
  static_web_app_sku = "None"
  log_daily_quota_gb = 0.5
}

module "monitoring" {
  source = "../../monitoring"
  count  = length(local.alert_emails) > 0 ? 1 : 0

  name                       = "example"
  environment                = "dev"
  resource_group_name        = module.core.resource_group_name
  resource_group_id          = module.core.resource_group_id
  location                   = module.core.location
  application_insights_id    = module.core.application_insights_id
  log_analytics_workspace_id = module.core.log_analytics_workspace_id
  alert_emails               = local.alert_emails
  health_check_url           = "${module.core.function_app_url}/api/health"
  exception_threshold        = 5
  budget_amount              = 20
}

output "action_group_id" {
  value = one(module.monitoring[*].action_group_id)
}
