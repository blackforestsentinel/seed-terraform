# Beispiel: core mit sso, so wie ein Projekt mit features.sso = true sie verbindet.

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
