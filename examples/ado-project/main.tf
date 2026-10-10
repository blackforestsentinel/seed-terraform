# Beispiel: ein Projekt in Azure DevOps anlegen, so wie die Scaffold-Pipeline es tut.

terraform {
  required_providers {
    azuredevops = {
      source  = "microsoft/azuredevops"
      version = "1.16.0"
    }
  }
}

# Organisation aus AZDO_ORG_SERVICE_URL, Anmeldung per OIDC (Pipeline) oder Azure CLI (lokal).
provider "azuredevops" {}

module "project" {
  source = "../../ado-project"

  ado_project        = "Kundenprojekte"
  name               = "kundenportal"
  features           = { sso = true }
  environments       = ["dev", "prod"]
  approvers          = ["freigabe@example.org"]
  service_connection = "sc-seed"
  github_connection  = "github-blackforestsentinel"
  terraform_state = {
    resource_group  = "rg-seed-tfstate"
    storage_account = "stseedtfstate"
    container       = "tfstate"
  }

  app_approval_environments = ["prod"]
}

output "repository_web_url" {
  value = module.project.repository_web_url
}
