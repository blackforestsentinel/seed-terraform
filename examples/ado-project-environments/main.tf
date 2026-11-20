# Beispiel: ein Projekt in Azure DevOps mit einer Service Connection je Umgebung, dev und prod in
# zwei Subscriptions, so wie das zentrale Scaffold es ab v0.21.0 tut. Die Identitäten
# id-kundenportal-dev und id-kundenportal-prod gibt es schon; die IDs sind Platzhalter.

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

  ado_project               = "Kundenprojekte"
  name                      = "kundenportal"
  features                  = { sso = true }
  environments              = ["dev", "prod"]
  approvers                 = ["freigabe@example.org"]
  github_connection         = "github-blackforestsentinel"
  create_service_connection = true
  environment_service_connections = {
    dev = {
      name = "sc-kundenportal-dev"
      identity = {
        tenant_id         = "00000000-0000-0000-0000-000000000000"
        subscription_id   = "00000000-0000-0000-0000-000000000001"
        subscription_name = "Seed Entwicklung"
        client_id         = "00000000-0000-0000-0000-000000000011"
      }
    }
    prod = {
      name = "sc-kundenportal-prod"
      identity = {
        tenant_id         = "00000000-0000-0000-0000-000000000000"
        subscription_id   = "00000000-0000-0000-0000-000000000002"
        subscription_name = "Seed Produktion"
        client_id         = "00000000-0000-0000-0000-000000000012"
      }
    }
  }
  terraform_state = {
    resource_group  = "rg-seed-tfstate"
    storage_account = "stseedtfstate"
    container       = "tfstate"
  }

  app_approval_environments = ["prod"]
}

# Je Umgebung Issuer und Subject für das Federated Credential an id-kundenportal-<env>.
output "workload_identity_federation" {
  value = module.project.workload_identity_federation
}
