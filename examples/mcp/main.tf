# Beispiel: sso mit MCP-Server, so wie ein Projekt mit features.mcp = true es verbindet.
# Die eigene Domain der Function muss im Tenant verifiziert sein.

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
  mcp               = true
  mcp_custom_domain = "mcp.example.org"
}

module "core" {
  source = "../../core"

  name               = "example"
  environment        = "dev"
  static_web_app_sku = "None"
  app_settings       = merge({ Seed__Features__Sso = "true", Seed__Features__Mcp = "true" }, module.sso.app_settings)
}

output "mcp_url" {
  value = coalesce(module.sso.mcp_resource, "${module.core.function_app_url}/api/mcp")
}

output "mcp_client_id" {
  value = module.sso.mcp_client_id
}
