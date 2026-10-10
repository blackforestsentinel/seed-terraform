# Minimalbeispiel für das Modul core, dient auch als Validierungsziel in der CI.

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

  name                 = "example"
  environment          = "dev"
  cors_allowed_origins = ["http://localhost:5173"]
  custom_domains       = ["app.example.org"]
}

output "function_app_url" {
  value = module.core.function_app_url
}

output "static_web_app_url" {
  value = module.core.static_web_app_url
}

output "custom_domain_dns_records" {
  value = module.core.custom_domain_dns_records
}
