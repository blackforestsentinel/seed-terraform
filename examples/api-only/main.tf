# Beispiel: Projekt ohne Frontend (nur API) mit sso, so wie ein Projekt mit
# hosting.staticWebApp: none sie verbindet. Keine Static Web App, keine SPA-Registrierung.

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

  name        = "example"
  environment = "dev"
}

module "core" {
  source = "../../core"

  name               = "example"
  environment        = "dev"
  static_web_app_sku = "None"
  app_settings       = module.sso.app_settings
}

output "function_app_url" {
  value = module.core.function_app_url
}

output "api_scope" {
  value = module.sso.api_scope
}
