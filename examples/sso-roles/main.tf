# Beispiel: sso mit App-Rollen aus auth.roles, Zuweisungspflicht und Bridge-Seite für die stille
# Anmeldung, so wie das Template es aus project.yaml verbindet.

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

locals {
  # Entspricht auth.roles in project.yaml; die Capabilities liest nur die API.
  roles = {
    Reader = { description = "Liest Rechnungen", memberTypes = ["User"], capabilities = ["invoices.read"] }
    Sync   = { description = "Nächtlicher Abgleich", memberTypes = ["Application"], capabilities = ["invoices.sync"] }
  }
}

module "sso" {
  source = "../../sso"

  name                     = "example"
  environment              = "dev"
  spa_redirect_uris        = [module.core.static_web_app_url, "http://localhost:5173"]
  spa_redirect_bridge_path = "/redirect.html"
  assignment_required      = true
  app_roles = {
    for name, role in local.roles : name => {
      description          = role.description
      allowed_member_types = role.memberTypes
    }
  }
}

module "core" {
  source = "../../core"

  name                 = "example"
  environment          = "dev"
  cors_allowed_origins = ["http://localhost:5173"]
  app_settings         = module.sso.app_settings
}

output "app_roles" {
  value = module.sso.app_roles
}
