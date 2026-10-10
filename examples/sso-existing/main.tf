# Beispiel: vorhandene App-Registrierung aus einem anderen Tenant. Das Modul legt nichts an und
# reicht die Werte an Function und Frontend weiter. Alle IDs sind Platzhalter.

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
    azuread = {
      source  = "hashicorp/azuread"
      version = "3.10.0"
    }
  }
}

provider "azurerm" {
  features {}
  storage_use_azuread = true
}

provider "azapi" {}

provider "azuread" {}

module "sso" {
  source = "../../sso"

  name                     = "example"
  environment              = "prod"
  spa_redirect_uris        = [module.core.static_web_app_url]
  spa_redirect_bridge_path = "/redirect.html"
  existing_registration = {
    tenant_id     = "00000000-0000-0000-0000-000000000001"
    api_client_id = "00000000-0000-0000-0000-000000000002"
    spa_client_id = "00000000-0000-0000-0000-000000000003"
    api_scope     = "api://00000000-0000-0000-0000-000000000002/access_as_user"
  }
  app_roles = {
    Admin = { description = "Verwaltet die Anwendung" }
  }
}

module "core" {
  source = "../../core"

  name         = "example"
  environment  = "prod"
  app_settings = module.sso.app_settings
}

output "frontend_config" {
  value = merge({ apiBaseUrl = module.core.function_app_url }, module.sso.frontend_config)
}

# Was der Admin im anderen Tenant einträgt.
output "spa_redirect_uris" {
  value = module.sso.spa_redirect_uris
}

output "app_roles" {
  value = module.sso.app_roles
}
