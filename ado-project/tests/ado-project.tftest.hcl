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

  mock_data "azuredevops_client_config" {
    defaults = {
      name = "example-org"
    }
  }

  # Build-Service-Identität des Projekts: Deskriptor mit :Build:<Projekt-ID>.
  mock_data "azuredevops_identity_user" {
    defaults = {
      id                 = "99999999-9999-9999-9999-999999999999"
      descriptor         = "Microsoft.TeamFoundation.ServiceIdentity;00000000-0000-0000-0000-000000000001:Build:11111111-1111-1111-1111-111111111111"
      subject_descriptor = "svc.YnVpbGQtc2VydmljZQ"
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

run "repo_rechte_eingeschraenkt" {
  command = plan

  override_data {
    target = data.azuredevops_group.contributors
    values = {
      descriptor = "vssgp.Y29udHJpYnV0b3Jz"
    }
  }

  assert {
    condition = (
      azuredevops_git_permissions.repository["contributors"].principal == "vssgp.Y29udHJpYnV0b3Jz" &&
      azuredevops_git_permissions.repository["build_service"].principal == "svc.YnVpbGQtc2VydmljZQ"
    )
    error_message = "Standard: Rechte für Contributors und die Build-Service-Identität des Projekts."
  }

  assert {
    condition = alltrue([
      for p in azuredevops_git_permissions.repository : p.permissions == tomap({
        CreateTag               = "Deny"
        ForcePush               = "Deny"
        PolicyExempt            = "Deny"
        PullRequestBypassPolicy = "Deny"
        EditPolicies            = "Deny"
      }) && p.replace == false && p.branch_name == null && p.project_id == "11111111-1111-1111-1111-111111111111"
    ])
    error_message = "Deny für Create tag, Force push, Bypass policies (Push und PR) und Edit policies am ganzen Repo, ohne andere Einträge zu ersetzen."
  }

  assert {
    condition     = data.azuredevops_group.contributors[0].name == "Contributors" && data.azuredevops_group.contributors[0].project_id == "11111111-1111-1111-1111-111111111111"
    error_message = "Contributors ist die Gruppe des Projekts, nicht der Organisation."
  }

  assert {
    condition     = data.azuredevops_identity_user.build_service[0].name == "Kundenprojekte Build Service (example-org)"
    error_message = "Die Build-Service-Identität heißt <Projekt> Build Service (<Organisation>)."
  }
}

run "repo_rechte_aus" {
  command = plan

  variables {
    protect_repository = false
  }

  assert {
    condition     = length(azuredevops_git_permissions.repository) == 0 && length(data.azuredevops_identity_user.build_service) == 0 && length(data.azuredevops_group.contributors) == 0
    error_message = "protect_repository = false lässt die Rechte am Repo unverändert und sucht keine Identitäten."
  }
}

run "repo_rechte_falsche_build_identitaet" {
  command = plan

  override_data {
    target = data.azuredevops_identity_user.build_service
    values = {
      descriptor = "Microsoft.TeamFoundation.ServiceIdentity;00000000-0000-0000-0000-000000000001:Build:00000000-0000-0000-0000-000000000002"
    }
  }

  expect_failures = [data.azuredevops_identity_user.build_service]
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
      alltrue([for p in azuredevops_git_permissions.repository : p.repository_id == "77777777-7777-7777-7777-777777777777"]),
    ])
    error_message = "Dateien, Pipeline, Policy und Rechte hängen am vorhandenen Repo."
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

# Werte, die in azure-pipelines.yml landen: Ein Zeilenumbruch oder ": " darf das YAML nicht
# umschreiben, etwa confirmDataDeletion setzen oder ein Repo ergänzen.
run "pipelines_version_nur_tag" {
  command = plan

  variables {
    pipelines_version = "v0.17.0\n    confirmDataDeletion: true"
  }

  expect_failures = [var.pipelines_version]
}

run "github_connection_ohne_zeilenumbruch" {
  command = plan

  variables {
    github_connection = "github-example\n    - repository: fremd"
  }

  expect_failures = [var.github_connection]
}

run "service_connection_ohne_doppelpunkt" {
  command = plan

  variables {
    service_connection = "sc-seed\n    confirmDataDeletion: true"
  }

  expect_failures = [var.service_connection]
}

run "pool_ohne_zeilenumbruch" {
  command = plan

  variables {
    pool = "Default\n    confirmDataDeletion: true"
  }

  expect_failures = [var.pool]
}

run "terraform_state_nur_namen" {
  command = plan

  variables {
    terraform_state = {
      resource_group  = "rg-seed-tfstate\n    confirmDataDeletion: true"
      storage_account = "StSeed-TfState"
      container       = "tfstate: x"
    }
  }

  expect_failures = [var.terraform_state]
}

run "environments_nur_namen" {
  command = plan

  variables {
    environments = ["dev", "prod\n    confirmDataDeletion: true"]
  }

  expect_failures = [var.environments]
}

run "pool_mit_leerzeichen" {
  command   = plan
  state_key = "pool"

  variables {
    pool = "Azure Pipelines"
  }

  assert {
    condition     = yamldecode(azuredevops_git_repository_file.pipeline.content).extends.parameters.pool == "Azure Pipelines"
    error_message = "Pool-Namen mit Leerzeichen bleiben erlaubt."
  }
}

# --- Selbstbedienung: Projekt, eigene Service Connection, Mitglieder (ab v0.20.0) ---------
# Eigener State: Die Läufe oben haben mit vorhandenes_repo schon angelegt.

run "selbstbedienung_aus_wie_bisher" {
  command   = plan
  state_key = "selbstbedienung"

  assert {
    condition     = length(azuredevops_project.this) == 0 && length(data.azuredevops_project.this) == 1 && output.project_id == "11111111-1111-1111-1111-111111111111"
    error_message = "Standard: vorhandenes Projekt, kein neues."
  }

  assert {
    condition = alltrue([
      length(azuredevops_serviceendpoint_azurerm.this) == 0,
      length(azuredevops_check_branch_control.service_connection) == 0,
      length(azuredevops_check_required_template.service_connection) == 0,
      length(data.azuredevops_serviceendpoint_azurerm.this) == 1,
      azuredevops_pipeline_authorization.endpoints["azure"].resource_id == "33333333-3333-3333-3333-333333333333",
      output.service_connection_id == "33333333-3333-3333-3333-333333333333",
      output.workload_identity_federation_issuer == "",
      output.workload_identity_federation_subject == "",
    ])
    error_message = "Standard: vorhandene Service Connection berechtigen, keine eigene, keine Checks; Issuer und Subject leer."
  }

  assert {
    condition     = length(azuredevops_group_membership.contributors) == 0 && length(azuredevops_group_membership.project_administrators) == 0 && length(data.azuredevops_users.members) == 0
    error_message = "Standard: keine Mitglieder."
  }

  assert {
    condition = alltrue([
      one(azuredevops_branch_policy_min_reviewers.this).settings[0].reviewer_count == 1,
      !one(azuredevops_branch_policy_min_reviewers.this).settings[0].submitter_can_vote,
    ])
    error_message = "Standard: ein Pflicht-Reviewer, die eigene Stimme zählt nicht."
  }
}

run "selbstbedienung_ohne_berechtigung" {
  command   = plan
  state_key = "selbstbedienung"

  variables {
    authorize_service_connections = false
  }

  assert {
    condition     = length(data.azuredevops_serviceendpoint_azurerm.this) == 0 && length(azuredevops_pipeline_authorization.endpoints) == 0 && output.service_connection_id == ""
    error_message = "Ohne Berechtigung und ohne eigene Service Connection: keine Suche, keine Berechtigung, service_connection_id leer."
  }
}

run "projekt_anlegen" {
  command   = plan
  state_key = "selbstbedienung"

  variables {
    create_project      = true
    project_description = "Seed-Projekt kundenportal"
  }

  assert {
    condition     = length(data.azuredevops_project.this) == 0
    error_message = "Mit create_project kein vorhandenes Projekt suchen."
  }

  assert {
    condition = alltrue([
      azuredevops_project.this[0].name == "Kundenprojekte",
      azuredevops_project.this[0].description == "Seed-Projekt kundenportal",
      azuredevops_project.this[0].visibility == "private",
      azuredevops_project.this[0].version_control == "Git",
      azuredevops_project.this[0].work_item_template == null,
    ])
    error_message = "Neues Projekt: Name aus ado_project, privat, Git, Prozess wie Provider-Standard."
  }

  assert {
    condition = azuredevops_project.this[0].features == tomap({
      boards       = "disabled"
      repositories = "enabled"
      pipelines    = "enabled"
      testplans    = "disabled"
      artifacts    = "disabled"
    })
    error_message = "Neues Projekt: nur Repos und Pipelines."
  }

  assert {
    condition     = data.azuredevops_identity_user.build_service[0].name == "Kundenprojekte Build Service (example-org)"
    error_message = "Die Build-Service-Identität heißt auch im neuen Projekt <Projekt> Build Service (<Organisation>)."
  }
}

run "projekt_anlegen_nur_mit_namen" {
  command   = plan
  state_key = "selbstbedienung"

  variables {
    create_project = true
    ado_project    = "Kunden/Projekte"
  }

  expect_failures = [var.ado_project]
}

run "eigene_service_connection" {
  command   = apply
  state_key = "service_connection"

  variables {
    pipelines_version         = "v0.20.0"
    service_connection        = "sc-kundenportal"
    create_service_connection = true
    service_connection_identity = {
      tenant_id         = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      subscription_id   = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
      subscription_name = "Seed Beispiel"
      client_id         = "cccccccc-cccc-cccc-cccc-cccccccccccc"
    }
  }

  override_resource {
    target = azuredevops_serviceendpoint_azurerm.this
    values = {
      id                                   = "dddddddd-dddd-dddd-dddd-dddddddddddd"
      workload_identity_federation_issuer  = "https://login.microsoftonline.com/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/v2.0"
      workload_identity_federation_subject = "/eid1/c/pub/t/beispiel/a/beispiel/sc/beispiel/dddddddd-dddd-dddd-dddd-dddddddddddd"
    }
  }

  assert {
    condition     = length(data.azuredevops_serviceendpoint_azurerm.this) == 0
    error_message = "Mit create_service_connection keine vorhandene Service Connection suchen."
  }

  assert {
    condition = alltrue([
      azuredevops_serviceendpoint_azurerm.this[0].service_endpoint_name == "sc-kundenportal",
      azuredevops_serviceendpoint_azurerm.this[0].project_id == "11111111-1111-1111-1111-111111111111",
      azuredevops_serviceendpoint_azurerm.this[0].service_endpoint_authentication_scheme == "WorkloadIdentityFederation",
      azuredevops_serviceendpoint_azurerm.this[0].credentials[0].serviceprincipalid == "cccccccc-cccc-cccc-cccc-cccccccccccc",
      azuredevops_serviceendpoint_azurerm.this[0].credentials[0].serviceprincipalkey == null,
      azuredevops_serviceendpoint_azurerm.this[0].azurerm_spn_tenantid == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      azuredevops_serviceendpoint_azurerm.this[0].azurerm_subscription_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      azuredevops_serviceendpoint_azurerm.this[0].azurerm_subscription_name == "Seed Beispiel",
      azuredevops_serviceendpoint_azurerm.this[0].features[0].validate == false,
    ])
    error_message = "Eigene Service Connection: Workload Identity Federation, manuell mit der client_id der Projekt-Identität, ohne Secret und ohne Prüfung beim Anlegen."
  }

  assert {
    condition = alltrue([
      azuredevops_check_branch_control.service_connection[0].target_resource_id == "dddddddd-dddd-dddd-dddd-dddddddddddd",
      azuredevops_check_branch_control.service_connection[0].target_resource_type == "endpoint",
      azuredevops_check_branch_control.service_connection[0].allowed_branches == "refs/heads/main,refs/tags/v*",
      azuredevops_check_branch_control.service_connection[0].verify_branch_protection == false,
      azuredevops_check_branch_control.service_connection[0].ignore_unknown_protection_status == false,
      azuredevops_check_branch_control.service_connection[0].timeout == null,
    ])
    error_message = "Branch-Prüfung an der eigenen Service Connection: main und seed-pipelines am eingebundenen Tag, Timeout wie Provider-Standard."
  }

  assert {
    condition = alltrue([
      azuredevops_check_required_template.service_connection[0].target_resource_id == "dddddddd-dddd-dddd-dddd-dddddddddddd",
      azuredevops_check_required_template.service_connection[0].target_resource_type == "endpoint",
      azuredevops_check_required_template.service_connection[0].required_template[0].repository_type == "github",
      azuredevops_check_required_template.service_connection[0].required_template[0].repository_name == "blackforestsentinel/seed-pipelines",
      azuredevops_check_required_template.service_connection[0].required_template[0].repository_ref == "refs/tags/v0.20.0",
      azuredevops_check_required_template.service_connection[0].required_template[0].template_path == "templates/web-app.yml",
      length(azuredevops_check_required_template.service_connection[0].required_template) == 1,
    ])
    error_message = "Required template: templates/web-app.yml aus seed-pipelines am Tag pipelines_version."
  }

  assert {
    condition     = azuredevops_pipeline_authorization.endpoints["azure"].resource_id == "dddddddd-dddd-dddd-dddd-dddddddddddd" && azuredevops_pipeline_authorization.endpoints["github"].resource_id == "44444444-4444-4444-4444-444444444444"
    error_message = "Die Pipeline ist für die eigene Service Connection berechtigt, die GitHub-Service-Connection bleibt die vorhandene."
  }

  assert {
    condition = alltrue([
      output.service_connection_id == "dddddddd-dddd-dddd-dddd-dddddddddddd",
      output.workload_identity_federation_issuer == "https://login.microsoftonline.com/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/v2.0",
      output.workload_identity_federation_subject == "/eid1/c/pub/t/beispiel/a/beispiel/sc/beispiel/dddddddd-dddd-dddd-dddd-dddddddddddd",
    ])
    error_message = "Outputs: ID, Issuer und Subject der eigenen Service Connection für das Federated Credential."
  }
}

run "eigene_service_connection_fork" {
  command   = plan
  state_key = "selbstbedienung"

  variables {
    create_service_connection    = true
    required_template_repository = "beispiel-org/seed-pipelines"
    service_connection_identity = {
      tenant_id         = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      subscription_id   = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
      subscription_name = "Seed Beispiel"
      client_id         = "cccccccc-cccc-cccc-cccc-cccccccccccc"
    }
  }

  assert {
    condition     = azuredevops_check_required_template.service_connection[0].required_template[0].repository_name == "beispiel-org/seed-pipelines" && azuredevops_check_required_template.service_connection[0].required_template[0].repository_ref == "refs/tags/v0.13.0"
    error_message = "required_template_repository ersetzt seed-pipelines im Check, etwa für einen Fork."
  }
}

run "eigene_service_connection_ohne_identitaet" {
  command   = plan
  state_key = "selbstbedienung"

  variables {
    create_service_connection = true
  }

  expect_failures = [var.service_connection_identity]
}

run "eigene_service_connection_identitaet_als_guid" {
  command   = plan
  state_key = "selbstbedienung"

  variables {
    create_service_connection = true
    service_connection_identity = {
      tenant_id         = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      subscription_id   = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
      subscription_name = "Seed Beispiel"
      client_id         = "id-kundenportal"
    }
  }

  expect_failures = [var.service_connection_identity]
}

run "template_repo_nur_besitzer_und_name" {
  command   = plan
  state_key = "selbstbedienung"

  variables {
    required_template_repository = "https://github.com/beispiel-org/seed-pipelines"
  }

  expect_failures = [var.required_template_repository]
}

run "mitglieder" {
  command   = plan
  state_key = "selbstbedienung"

  variables {
    protect_repository     = false
    contributors           = ["freigabe@example.org"]
    project_administrators = ["freigabe@example.org"]
  }

  override_data {
    target = data.azuredevops_group.contributors
    values = {
      descriptor = "vssgp.Y29udHJpYnV0b3Jz"
    }
  }

  override_data {
    target = data.azuredevops_group.project_administrators
    values = {
      descriptor = "vssgp.cHJvamVjdC1hZG1pbnM"
    }
  }

  assert {
    condition = alltrue([
      data.azuredevops_group.contributors[0].name == "Contributors",
      data.azuredevops_group.contributors[0].project_id == "11111111-1111-1111-1111-111111111111",
      data.azuredevops_group.project_administrators[0].name == "Project Administrators",
      data.azuredevops_group.project_administrators[0].project_id == "11111111-1111-1111-1111-111111111111",
    ])
    error_message = "Contributors und Project Administrators sind Gruppen des Projekts, auch ohne protect_repository gesucht."
  }

  assert {
    condition = alltrue([
      azuredevops_group_membership.contributors[0].group == "vssgp.Y29udHJpYnV0b3Jz",
      azuredevops_group_membership.contributors[0].members == toset(["aad.dXNlcg"]),
      azuredevops_group_membership.contributors[0].mode == "add",
      azuredevops_group_membership.project_administrators[0].group == "vssgp.cHJvamVjdC1hZG1pbnM",
      azuredevops_group_membership.project_administrators[0].members == toset(["aad.dXNlcg"]),
      azuredevops_group_membership.project_administrators[0].mode == "add",
    ])
    error_message = "Die genannten Personen werden Mitglied der Gruppen; weitere Mitglieder bleiben (mode add)."
  }

  assert {
    condition     = length(azuredevops_git_permissions.repository) == 0
    error_message = "contributors schaltet die Rechte am Repo nicht ein."
  }
}

run "mitglied_unbekannt" {
  command   = plan
  state_key = "selbstbedienung"

  variables {
    contributors = ["unbekannt@example.org"]
  }

  override_data {
    target = data.azuredevops_users.members
    values = {
      users = []
    }
  }

  expect_failures = [data.azuredevops_users.members]
}

run "mitglieder_nur_principal_names" {
  command   = plan
  state_key = "selbstbedienung"

  variables {
    contributors           = ["Freigabe Person"]
    project_administrators = ["freigabe@example.org", "keine mail"]
  }

  expect_failures = [var.contributors, var.project_administrators]
}

# So ruft das zentrale Scaffold das Modul auf.
run "zentrales_scaffold_selbstbedienung" {
  command   = plan
  state_key = "selbstbedienung"

  variables {
    create_project            = true
    create_repository         = false
    create_service_connection = true
    service_connection        = "sc-kundenportal"
    service_connection_identity = {
      tenant_id         = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      subscription_id   = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
      subscription_name = "Seed Beispiel"
      client_id         = "cccccccc-cccc-cccc-cccc-cccccccccccc"
    }
    contributors           = ["freigabe@example.org"]
    approver_groups        = ["Seed Infrastruktur-Freigabe"]
    requester_can_approve  = false
    create_resource_groups = false
  }

  assert {
    condition     = length(azuredevops_project.this) == 1 && length(azuredevops_serviceendpoint_azurerm.this) == 1 && length(azuredevops_git_repository.this) == 0
    error_message = "Neues Projekt mit eigener Service Connection, Repo vorhanden."
  }

  assert {
    condition = alltrue([
      length(azuredevops_check_branch_control.service_connection) == 1,
      length(azuredevops_check_required_template.service_connection) == 1,
      length(azuredevops_group_membership.contributors) == 1,
      length(azuredevops_group_membership.project_administrators) == 0,
    ])
    error_message = "Checks an der Service Connection, die Person als Contributor, keine Projektadministratoren."
  }

  assert {
    condition = alltrue([
      alltrue([for c in azuredevops_check_approval.this : !c.requester_can_approve]),
      one(azuredevops_branch_policy_min_reviewers.this).settings[0].reviewer_count == 1,
      !one(azuredevops_branch_policy_min_reviewers.this).settings[0].submitter_can_vote,
      one(azuredevops_branch_policy_min_reviewers.this).settings[0].last_pusher_cannot_approve,
      one(azuredevops_branch_policy_min_reviewers.this).settings[0].on_push_reset_approved_votes,
    ])
    error_message = "Freigabe nicht durch die auslösende Person, ein Reviewer, die eigene Stimme zählt nicht."
  }
}

run "project_yaml_mit_resource_groups_wie_bisher" {
  command   = plan
  state_key = "scaffold_files"

  assert {
    condition     = !strcontains(azuredevops_git_repository_file.project_yaml.content, "createResourceGroups") && !contains(keys(yamldecode(azuredevops_git_repository_file.project_yaml.content)), "createResourceGroups")
    error_message = "Standard: project.yaml ohne createResourceGroups, wie im Template."
  }
}

run "project_yaml_ohne_resource_groups" {
  command   = plan
  state_key = "scaffold_files"

  variables {
    create_resource_groups = false
    owner                  = "team@example.org"
  }

  assert {
    condition     = yamldecode(azuredevops_git_repository_file.project_yaml.content).createResourceGroups == false
    error_message = "create_resource_groups = false: createResourceGroups: false auf oberster Ebene von project.yaml."
  }

  assert {
    condition = alltrue([
      strcontains(azuredevops_git_repository_file.project_yaml.content, "# Die Resource Groups rg-<project>-<umgebung> legt das Scaffold vorab an"),
      yamldecode(azuredevops_git_repository_file.project_yaml.content).owner == "team@example.org",
      yamldecode(azuredevops_git_repository_file.project_yaml.content).features.sso == false,
    ])
    error_message = "Mit Kommentar; owner und die übrigen Schlüssel bleiben."
  }
}
