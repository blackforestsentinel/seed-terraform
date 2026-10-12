# Beispiel: sso mit Client-Registrierung für einen Power-Platform-Custom-Connector, so wie ein
# Projekt mit features.customConnector = true es verbindet. Den Connector selbst legt die Pipeline
# an (seed-pipelines) und trägt dabei Redirect-URI und Federated Credential an der Registrierung ein.

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
  connector   = true
}

module "core" {
  source = "../../core"

  name               = "example"
  environment        = "dev"
  static_web_app_sku = "None"
  app_settings       = merge({ Seed__Features__Sso = "true" }, module.sso.app_settings)
}

# Was der Pipeline-Schritt für den Connector braucht.
output "custom_connector" {
  value = {
    clientId    = module.sso.connector_client_id
    tenantId    = module.sso.tenant_id
    resourceUri = module.sso.api_identifier_uri
    functionUrl = module.core.function_app_url
  }
}
