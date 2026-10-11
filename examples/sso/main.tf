# Beispiel: core mit sso, so wie ein Projekt mit features.sso = true sie verbindet, dazu die
# Personen-Komponenten im Frontend (auth.directory) mit Teams-Status.

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

  name              = "example"
  environment       = "dev"
  spa_redirect_uris = [module.core.static_web_app_url, "http://localhost:5173"]

  # Delegierte Graph-Berechtigungen an der SPA; die Zustimmung erteilt ein Admin von Hand.
  directory = {
    enabled  = true
    presence = true
  }
}

module "core" {
  source = "../../core"

  name                 = "example"
  environment          = "dev"
  cors_allowed_origins = ["http://localhost:5173"]
  app_settings         = module.sso.app_settings
}

output "frontend_config" {
  value = merge({ apiBaseUrl = module.core.function_app_url }, module.sso.frontend_config)
}

# Was ein Admin nach dem Apply freigibt („Administratorzustimmung erteilen“).
output "directory_permissions" {
  value = module.sso.directory_permissions
}
