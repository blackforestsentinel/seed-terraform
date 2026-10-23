# terraform -chdir=ado-project init -backend=false && terraform -chdir=ado-project test
# Läuft gegen einen Mock des azuredevops-Providers, ohne Organisation und ohne Rechte.

mock_provider "azuredevops" {
  mock_data "azuredevops_project" {
    defaults = {
      id = "11111111-1111-1111-1111-111111111111"
    }
  }

  mock_data "azuredevops_users" {
    defaults = {
      users = [{
        id             = "55555555-5555-5555-5555-555555555555"
        descriptor     = "aad.dXNlcg"
        display_name   = "Freigabe"
        mail_address   = "freigabe@example.org"
        origin         = "aad"
        origin_id      = "22222222-2222-2222-2222-222222222222"
        principal_name = "freigabe@example.org"
        subject_kind   = "user"
      }]
    }
  }

  mock_data "azuredevops_group" {
    defaults = {
      origin_id = "66666666-6666-6666-6666-666666666666"
    }
  }

  mock_data "azuredevops_git_repository" {
    defaults = {
      id         = "77777777-7777-7777-7777-777777777777"
      remote_url = "https://dev.azure.com/org/projekt/_git/kundenportal"
      web_url    = "https://dev.azure.com/org/projekt/_git/kundenportal"
    }
  }

  mock_data "azuredevops_serviceendpoint_azurerm" {
    defaults = {
      id = "33333333-3333-3333-3333-333333333333"
    }
  }

  mock_data "azuredevops_serviceendpoint_github" {
    defaults = {
      id = "44444444-4444-4444-4444-444444444444"
    }
  }

  mock_data "azuredevops_agent_queue" {
    defaults = {
      id = 5
    }
  }

  mock_resource "azuredevops_git_repository" {
    defaults = {
      id = "88888888-8888-8888-8888-888888888888"
    }
  }

  mock_resource "azuredevops_build_definition" {
    defaults = {
      id = "12"
    }
  }

  mock_resource "azuredevops_environment" {
    defaults = {
      id = "7"
    }
  }
}

variables {
  ado_project        = "Kundenprojekte"
  name               = "kundenportal"
  environments       = ["dev", "prod"]
  approvers          = ["freigabe@example.org"]
  service_connection = "sc-seed"
  github_connection  = "github-example"
  pipelines_version  = "v0.13.0"
  terraform_state = {
    resource_group  = "rg-seed-tfstate"
    storage_account = "stseedtfstate"
    container       = "tfstate"
  }
}

run "standard_wie_bisher" {
  command = plan

  assert {
    condition     = length(azuredevops_git_repository.this) == 1 && length(data.azuredevops_git_repository.existing) == 0
    error_message = "Standard: Repo per Import anlegen, kein vorhandenes suchen."
  }

  assert {
    condition     = azuredevops_git_repository.this[0].name == "kundenportal"
    error_message = "Ohne repository heißt das Repo wie das Projekt."
  }

  assert {
    condition     = alltrue([for c in azuredevops_check_approval.this : c.requester_can_approve && toset(c.approvers) == toset(["55555555-5555-5555-5555-555555555555"])])
    error_message = "Standard: Freigabe durch die Personen aus approvers, auch durch die, die den Lauf ausgelöst hat."
  }

  assert {
    condition     = length(azuredevops_branch_policy_min_reviewers.this) == 0
    error_message = "Standard: keine Pflicht-Reviewer."
  }

  assert {
    condition     = !strcontains(azuredevops_git_repository_file.pipeline.content, "pool:") && length(azuredevops_pipeline_authorization.pool) == 0
    error_message = "Ohne pool bleibt azure-pipelines.yml bei Microsoft-gehosteten Agents, ohne Queue-Berechtigung."
  }
}

run "zentrales_scaffold" {
  command = plan

  variables {
    approver_groups       = ["Seed Infrastruktur-Freigabe"]
    requester_can_approve = false
    min_reviewers         = 1
    pool                  = "Default"
  }

  assert {
    condition     = alltrue([for c in azuredevops_check_approval.this : !c.requester_can_approve && toset(c.approvers) == toset(["55555555-5555-5555-5555-555555555555", "66666666-6666-6666-6666-666666666666"])])
    error_message = "Freigabe durch Personen und Gruppe, nicht durch die auslösende Person."
  }

  assert {
    condition = alltrue([
      one(azuredevops_branch_policy_min_reviewers.this).settings[0].reviewer_count == 1,
      !one(azuredevops_branch_policy_min_reviewers.this).settings[0].submitter_can_vote,
      one(azuredevops_branch_policy_min_reviewers.this).settings[0].last_pusher_cannot_approve,
    ])
    error_message = "Ein Reviewer, die eigene Stimme zählt nicht."
  }

  assert {
    condition     = strcontains(azuredevops_git_repository_file.pipeline.content, "\n    pool: Default\n")
    error_message = "pool landet in azure-pipelines.yml des Projekts."
  }

  assert {
    condition     = one(azuredevops_pipeline_authorization.pool).type == "queue" && data.azuredevops_agent_queue.pool[0].name == "Default"
    error_message = "Mit pool ist die Pipeline für dessen Queue berechtigt, kein Permit beim ersten Lauf."
  }
}

run "pool_mit_alter_version" {
  command = plan

  variables {
    pool              = "Default"
    pipelines_version = "v0.12.1"
  }

  expect_failures = [azuredevops_git_repository_file.pipeline]
}

# Als letzter Lauf: apply schreibt den State, den die Läufe davor sonst mitbenutzen würden.
run "vorhandenes_repo" {
  command = apply

  variables {
    create_repository = false
    repository        = "Kundenportal"
  }

  assert {
    condition     = length(azuredevops_git_repository.this) == 0
    error_message = "Mit create_repository = false entsteht kein Repo."
  }

  assert {
    condition     = data.azuredevops_git_repository.existing[0].name == "Kundenportal"
    error_message = "Das vorhandene Repo wird unter repository gesucht."
  }

  assert {
    condition = alltrue([
      azuredevops_git_repository_file.project_yaml.repository_id == "77777777-7777-7777-7777-777777777777",
      azuredevops_git_repository_file.pipeline.repository_id == "77777777-7777-7777-7777-777777777777",
      one(azuredevops_build_definition.this.repository).repo_id == "77777777-7777-7777-7777-777777777777",
      one(one(azuredevops_branch_policy_build_validation.this).settings[0].scope).repository_id == "77777777-7777-7777-7777-777777777777",
    ])
    error_message = "Dateien, Pipeline und Policy hängen am vorhandenen Repo."
  }

  assert {
    condition     = output.repository_web_url == "https://dev.azure.com/org/projekt/_git/kundenportal" && output.project_id == "11111111-1111-1111-1111-111111111111"
    error_message = "Outputs aus dem vorhandenen Repo und dem Projekt."
  }
}
