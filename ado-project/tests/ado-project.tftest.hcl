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
    condition     = one(azuredevops_branch_policy_min_reviewers.this).settings[0].reviewer_count == 1
    error_message = "Standard: ein Pflicht-Reviewer."
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

run "ohne_pflicht_reviewer" {
  command = plan

  variables {
    min_reviewers = 0
  }

  assert {
    condition     = length(azuredevops_branch_policy_min_reviewers.this) == 0
    error_message = "min_reviewers = 0 schaltet die Pflicht-Reviewer ab."
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

# Eigener State: Frühere Läufe haben die Dateien schon angelegt, und ignore_changes hielte den
# alten Inhalt fest.
run "project_yaml_ohne_owner" {
  command   = plan
  state_key = "scaffold_files"

  assert {
    condition     = strcontains(azuredevops_git_repository_file.project_yaml.content, "# TODO(onboarding): Adresse eintragen.\nowner: \"\"\n")
    error_message = "Ohne owner steht in project.yaml ein leerer Eintrag mit TODO(onboarding), wie im Template."
  }

  assert {
    condition     = yamldecode(azuredevops_git_repository_file.project_yaml.content).owner == ""
    error_message = "owner ist ohne Angabe ein leerer Text."
  }
}

run "project_yaml_mit_leerem_owner" {
  command   = plan
  state_key = "scaffold_files"

  variables {
    owner = ""
  }

  assert {
    condition     = strcontains(azuredevops_git_repository_file.project_yaml.content, "# TODO(onboarding): Adresse eintragen.\nowner: \"\"\n")
    error_message = "Ein leerer owner wirkt wie null: owner: \"\" mit TODO(onboarding)."
  }
}

run "project_yaml_mit_owner" {
  command   = plan
  state_key = "scaffold_files"

  variables {
    owner = "team@example.org"
  }

  assert {
    condition     = strcontains(azuredevops_git_repository_file.project_yaml.content, "\nowner: \"team@example.org\"\n") && !strcontains(azuredevops_git_repository_file.project_yaml.content, "TODO(onboarding): Adresse")
    error_message = "owner steht auf oberster Ebene in project.yaml, ohne TODO."
  }

  assert {
    condition     = yamldecode(azuredevops_git_repository_file.project_yaml.content).owner == "team@example.org"
    error_message = "project.yaml bleibt gültiges YAML, owner ist ein Schlüssel der obersten Ebene."
  }
}

# Stand wie project.yaml in seed-template: dieselben Schlüssel und Standardwerte.
run "project_yaml_wie_im_template" {
  command   = plan
  state_key = "scaffold_files"

  variables {
    features = { sso = true, mcp = false, storage = true }
    frontend = false
  }

  assert {
    condition = alltrue([
      yamldecode(azuredevops_git_repository_file.project_yaml.content).project == "kundenportal",
      yamldecode(azuredevops_git_repository_file.project_yaml.content).features == { sso = true, mcp = false, storage = true, keyVault = false, customConnector = false },
      yamldecode(azuredevops_git_repository_file.project_yaml.content).hosting == { staticWebApp = "none", customDomains = [], corsAllowedOrigins = [] },
      yamldecode(azuredevops_git_repository_file.project_yaml.content).auth.assignmentRequired == true,
      yamldecode(azuredevops_git_repository_file.project_yaml.content).auth.roles.Admin.capabilities == ["settings.manage", "status.read", "jobs.run"],
      yamldecode(azuredevops_git_repository_file.project_yaml.content).monitoring.recipients == [],
      yamldecode(azuredevops_git_repository_file.project_yaml.content).storage.deletionLock == true,
    ])
    error_message = "project.yaml hat die Schlüssel und Standardwerte des Templates, mit Features und Frontend aus den Variablen; Admin hat jobs.run für das Beispiel CreateJob und GetJob."
  }

  assert {
    condition = alltrue([
      for text in ["#   servicePrincipals: false", "# build:", "#   prereleasePackages:", "#   ignoreAdvisories:", "#     hosting:", "solche mit [AllowWithoutRole] nicht. Ohne Angabe gilt false."] :
      strcontains(azuredevops_git_repository_file.project_yaml.content, text)
    ])
    error_message = "Die Kommentare und auskommentierten Abschnitte des Templates sind dabei, etwa build, auth.directory.servicePrincipals und der Hinweis zu assignmentRequired."
  }
}

run "pipeline_ohne_connector_parameter_bei_alter_version" {
  command   = plan
  state_key = "scaffold_files"

  assert {
    condition = alltrue([
      for text in ["allowBreakingConnectorChanges", "checkConnectorConnections", "treatWarningsAsErrors"] :
      !strcontains(azuredevops_git_repository_file.pipeline.content, text)
    ])
    error_message = "Vor seed-pipelines v0.17.0 keine neuen Parameter, auch nicht auskommentiert; ältere Versionen lehnen sie ab."
  }

  assert {
    condition     = yamldecode(azuredevops_git_repository_file.pipeline.content).extends.parameters.confirmDataDeletion == "$${{ parameters.confirmDataDeletion }}"
    error_message = "confirmDataDeletion wird weiter durchgereicht."
  }
}

run "pipeline_mit_connector_parametern" {
  command   = plan
  state_key = "scaffold_files"

  variables {
    pipelines_version = "v0.17.0"
  }

  assert {
    condition     = [for p in yamldecode(azuredevops_git_repository_file.pipeline.content).parameters : p.name] == ["confirmDataDeletion", "allowBreakingConnectorChanges"]
    error_message = "Laufzeitparameter wie im Template: Datenlöschung bestätigen und Breaking Changes am Custom Connector zulassen."
  }

  assert {
    condition     = yamldecode(azuredevops_git_repository_file.pipeline.content).parameters[1] == { name = "allowBreakingConnectorChanges", displayName = "Breaking Changes am Custom Connector zulassen", type = "boolean", default = false }
    error_message = "allowBreakingConnectorChanges ist ein Boolean mit Default false."
  }

  assert {
    condition     = yamldecode(azuredevops_git_repository_file.pipeline.content).extends.parameters.allowBreakingConnectorChanges == "$${{ parameters.allowBreakingConnectorChanges }}"
    error_message = "allowBreakingConnectorChanges wird wie confirmDataDeletion an web-app.yml durchgereicht."
  }

  assert {
    condition     = strcontains(azuredevops_git_repository_file.pipeline.content, "\n    # checkConnectorConnections: true\n") && !contains(keys(yamldecode(azuredevops_git_repository_file.pipeline.content).extends.parameters), "checkConnectorConnections")
    error_message = "checkConnectorConnections steht nur auskommentiert da (Opt-in)."
  }

  assert {
    condition     = strcontains(azuredevops_git_repository_file.pipeline.content, "\n    # treatWarningsAsErrors: false\n") && !contains(keys(yamldecode(azuredevops_git_repository_file.pipeline.content).extends.parameters), "treatWarningsAsErrors")
    error_message = "treatWarningsAsErrors bleibt beim Standard true und steht nur auskommentiert da."
  }
}

run "owner_nur_als_mail" {
  command = plan

  variables {
    owner = "kein Postfach"
  }

  expect_failures = [var.owner]
}
