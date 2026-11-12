# --- Projekt --------------------------------------------------------------------

# Neues Projekt (create_project): Die anlegende Identität wird dessen Projektadministrator. Das
# Standard-Repo bleibt leer; unter "Protect access to repositories in YAML pipelines" sieht das
# Job-Token es nicht und kann es nicht befüllen. Das zentrale Scaffold nutzt deshalb
# create_repository = false: Die Person klickt in Repos auf "Initialize", der nächste Lauf befüllt.
resource "azuredevops_project" "this" {
  count = var.create_project ? 1 : 0

  name            = var.ado_project
  description     = var.project_description
  visibility      = "private"
  version_control = "Git"

  # Nur, was ein Seed-Projekt braucht; Boards, Test Plans und Artifacts kann ein Projektadmin
  # später einschalten.
  features = {
    boards       = "disabled"
    repositories = "enabled"
    pipelines    = "enabled"
    testplans    = "disabled"
    artifacts    = "disabled"
  }

  lifecycle {
    # Mit dem Projekt verschwänden Repo, Pipelines und Historie. Entfernen nur von Hand.
    prevent_destroy = true
    # Beschreibung und Features pflegt danach das Projekt selbst.
    ignore_changes = [description, features]
  }
}

data "azuredevops_project" "this" {
  count = var.create_project ? 0 : 1

  name = var.ado_project
}

locals {
  project_id   = var.create_project ? azuredevops_project.this[0].id : data.azuredevops_project.this[0].id
  project_name = var.create_project ? azuredevops_project.this[0].name : data.azuredevops_project.this[0].name
}

# --- Service Connections --------------------------------------------------------

# Vorhandene Azure-Service-Connection (wie bis v0.19.0), nur zum Berechtigen der Pipeline.
data "azuredevops_serviceendpoint_azurerm" "this" {
  count                 = var.authorize_service_connections && !var.create_service_connection ? 1 : 0
  project_id            = local.project_id
  service_endpoint_name = var.service_connection
}

# Die GitHub-Service-Connection für die Templates bleibt vorhanden: Das zentrale Scaffold teilt sie
# aus seinem Projekt ins Zielprojekt, bevor das Modul läuft.
data "azuredevops_serviceendpoint_github" "this" {
  count                 = var.authorize_service_connections ? 1 : 0
  project_id            = local.project_id
  service_endpoint_name = var.github_connection
}

data "azuredevops_users" "approvers" {
  for_each       = toset(var.approvers)
  principal_name = each.value
}

# Gruppen der Organisation, ohne project_id gesucht
data "azuredevops_group" "approvers" {
  for_each = toset(var.approver_groups)
  name     = each.value
}

locals {
  approver_ids = concat(
    [for u in data.azuredevops_users.approvers : one(u.users).id],
    [for g in data.azuredevops_group.approvers : g.origin_id],
  )

  repository_name = coalesce(var.repository, var.name)

  # Je Umgebung: <name>-<env> für Infrastruktur (mit Freigabe), <name>-<env>-app für den App-Deploy.
  environments = merge(
    { for env in var.environments : "${env}-infra" => { name = "${var.name}-${env}", approval = length(local.approver_ids) > 0, description = "Infrastruktur ${env}: terraform apply" } },
    { for env in var.environments : "${env}-app" => { name = "${var.name}-${env}-app", approval = contains(var.app_approval_environments, env) && length(local.approver_ids) > 0, description = "App-Deploy ${env}" } },
  )

  branch = "refs/heads/main"

  # PR-Läufe ohne Deploy kennt web-app.yml erst ab seed-pipelines v0.5.0; mit einer älteren
  # Version würde die PR-Validierung den PR-Stand deployen.
  pipelines_semver  = try([for part in regex("^v(\\d+)\\.(\\d+)\\.(\\d+)$", var.pipelines_version) : tonumber(part)], null)
  pipelines_number  = local.pipelines_semver == null ? null : local.pipelines_semver[0] * 1000000 + local.pipelines_semver[1] * 1000 + local.pipelines_semver[2]
  pr_runs_supported = local.pipelines_number == null ? true : local.pipelines_number >= 5000
  # Den Parameter pool kennt web-app.yml erst ab v0.13.0; ältere Versionen lehnen ihn ab.
  pool_supported = local.pipelines_number == null ? true : local.pipelines_number >= 13000
  # treatWarningsAsErrors, allowBreakingConnectorChanges und checkConnectorConnections kennt
  # web-app.yml erst ab v0.17.0; ältere Versionen lehnen unbekannte Parameter ab, die Pipeline
  # startete dann gar nicht. Auch die auskommentierten Zeilen stehen nur ab dieser Version da.
  pipelines_v017 = local.pipelines_number == null ? true : local.pipelines_number >= 17000
}

# --- Repo aus dem Template ------------------------------------------------------

resource "azuredevops_git_repository" "this" {
  count = var.create_repository ? 1 : 0

  project_id     = local.project_id
  name           = local.repository_name
  default_branch = local.branch

  initialization {
    init_type   = "Import"
    source_type = "Git"
    source_url  = var.template_url
  }

  # Nach dem Import gehört das Repo dem Projekt.
  lifecycle {
    ignore_changes = [initialization]
  }
}

# Bis v0.13.0 gab es das Repo immer, ohne count.
moved {
  from = azuredevops_git_repository.this
  to   = azuredevops_git_repository.this[0]
}

# Vorhandenes Repo: Das zentrale Scaffold darf keine Repos anlegen (Job-Token unter "Protect
# access to repositories"); die Person legt es an, die Pipeline führt seed-template vorher ein.
data "azuredevops_git_repository" "existing" {
  count = var.create_repository ? 0 : 1

  project_id = local.project_id
  name       = local.repository_name
}

locals {
  repository_id         = var.create_repository ? azuredevops_git_repository.this[0].id : data.azuredevops_git_repository.existing[0].id
  repository_remote_url = var.create_repository ? azuredevops_git_repository.this[0].remote_url : data.azuredevops_git_repository.existing[0].remote_url
  repository_web_url    = var.create_repository ? azuredevops_git_repository.this[0].web_url : data.azuredevops_git_repository.existing[0].web_url
}

# Projektspezifische Dateien einmalig schreiben; spätere Änderungen macht das Projekt selbst.
resource "azuredevops_git_repository_file" "project_yaml" {
  repository_id = local.repository_id
  branch        = local.branch
  file          = "project.yaml"
  content = templatefile("${path.module}/templates/project.yaml.tftpl", {
    name                   = var.name
    owner                  = var.owner == "" ? null : var.owner
    features               = var.features
    frontend               = var.frontend
    create_resource_groups = var.create_resource_groups
  })
  commit_message      = "seed-scaffold: project.yaml für ${var.name}"
  overwrite_on_create = true

  lifecycle {
    ignore_changes = [content, commit_message]
  }
}

resource "azuredevops_git_repository_file" "pipeline" {
  repository_id = local.repository_id
  branch        = local.branch
  file          = "azure-pipelines.yml"
  content = templatefile("${path.module}/templates/azure-pipelines.yml.tftpl", {
    name               = var.name
    frontend           = var.frontend
    environments       = var.environments
    service_connection = var.service_connection
    github_connection  = var.github_connection
    pipelines_version  = var.pipelines_version
    terraform_state    = var.terraform_state
    pool               = var.pool
    pipelines_v017     = local.pipelines_v017
  })
  commit_message      = "seed-scaffold: azure-pipelines.yml für ${var.name}"
  overwrite_on_create = true

  lifecycle {
    ignore_changes = [content, commit_message]

    precondition {
      condition     = var.pool == "" || local.pool_supported
      error_message = "pool braucht pipelines_version ab v0.13.0."
    }
  }

  depends_on = [azuredevops_git_repository_file.project_yaml]
}

# --- Environments und Freigaben -------------------------------------------------

resource "azuredevops_environment" "this" {
  for_each = local.environments

  project_id  = local.project_id
  name        = each.value.name
  description = each.value.description
}

resource "azuredevops_check_approval" "this" {
  for_each = { for k, v in local.environments : k => v if v.approval }

  project_id                 = local.project_id
  target_resource_id         = azuredevops_environment.this[each.key].id
  target_resource_type       = "environment"
  approvers                  = local.approver_ids
  minimum_required_approvers = 1
  requester_can_approve      = var.requester_can_approve
  instructions               = "Plan im Log der Stage Plan prüfen, dann freigeben."
}

# --- Pipeline -------------------------------------------------------------------

resource "azuredevops_build_definition" "this" {
  project_id = local.project_id
  name       = var.name

  ci_trigger {
    use_yaml = true
  }

  repository {
    repo_type   = "TfsGit"
    repo_id     = local.repository_id
    branch_name = local.branch
    yml_path    = "azure-pipelines.yml"
  }

  depends_on = [azuredevops_git_repository_file.pipeline]
}

# Mit create_service_connection erst, wenn die Checks an der Service Connection stehen.
resource "azuredevops_pipeline_authorization" "endpoints" {
  for_each = var.authorize_service_connections ? {
    azure  = local.service_connection_id
    github = data.azuredevops_serviceendpoint_github.this[0].id
  } : {}

  project_id  = local.project_id
  resource_id = each.value
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.this.id

  depends_on = [
    azuredevops_check_branch_control.service_connection,
    azuredevops_check_required_template.service_connection,
  ]
}

# Eigener Pool: Dessen Queue ist im Projekt meist nicht für alle Pipelines freigegeben; ohne
# Berechtigung wartete der erste Lauf auf "Permit".
data "azuredevops_agent_queue" "pool" {
  count = var.pool != "" ? 1 : 0

  project_id = local.project_id
  name       = var.pool
}

resource "azuredevops_pipeline_authorization" "pool" {
  count = var.pool != "" ? 1 : 0

  project_id  = local.project_id
  resource_id = data.azuredevops_agent_queue.pool[0].id
  type        = "queue"
  pipeline_id = azuredevops_build_definition.this.id
}

resource "azuredevops_pipeline_authorization" "environments" {
  for_each = azuredevops_environment.this

  project_id  = local.project_id
  resource_id = each.value.id
  type        = "environment"
  pipeline_id = azuredevops_build_definition.this.id
}

# --- PR-Validierung -------------------------------------------------------------

# Pull Requests auf main brauchen einen erfolgreichen Lauf der Projekt-Pipeline. Sie erkennt
# PR-Läufe selbst und baut, testet und scannt dann nur, ohne Deploy und Service Connection;
# eine zweite Pipeline-Definition mit eigenen Freigaben ist so nicht nötig. Als Pflicht-Policy
# sperrt sie direkte Pushes auf main, deshalb entsteht sie erst nach den Dateien oben.
resource "azuredevops_branch_policy_build_validation" "this" {
  count = var.pr_validation ? 1 : 0

  project_id = local.project_id
  enabled    = true
  blocking   = true

  settings {
    display_name        = "PR-Validierung"
    build_definition_id = azuredevops_build_definition.this.id
    # Ein Ergebnis gilt 12 Stunden, auch wenn sich main ändert: Mit einem parallelen Job soll
    # nicht jeder Merge alle offenen PRs neu bauen.
    queue_on_source_update_only = true
    valid_duration              = 720

    scope {
      repository_id  = local.repository_id
      repository_ref = local.branch
      match_type     = "Exact"
    }
  }

  lifecycle {
    precondition {
      condition     = local.pr_runs_supported
      error_message = "pr_validation braucht pipelines_version ab v0.5.0: Ältere Versionen von seed-pipelines deployen auch in PR-Läufen."
    }
  }
}

# Pflicht-Reviewer auf main: Die Stage Plan nutzt die Service Connection vor jeder Freigabe; ohne
# Review könnte eine Person ihre eigene Pipeline-Änderung mergen und damit die Rechte der
# Deployment-Identität nutzen. Die eigene Stimme zählt nicht, neue Pushes setzen Zustimmungen zurück.
resource "azuredevops_branch_policy_min_reviewers" "this" {
  count = var.min_reviewers > 0 ? 1 : 0

  project_id = local.project_id
  enabled    = true
  blocking   = true

  settings {
    reviewer_count               = var.min_reviewers
    submitter_can_vote           = false
    last_pusher_cannot_approve   = true
    on_push_reset_approved_votes = true

    scope {
      repository_id  = local.repository_id
      repository_ref = local.branch
      match_type     = "Exact"
    }
  }

  # Wie die PR-Validierung erst nach den Dateien, die das Modul direkt auf main schreibt.
  depends_on = [azuredevops_git_repository_file.pipeline]
}

# --- Rechte am Repo -------------------------------------------------------------

# Die Projekt-Defaults erlauben Contributors "Create tag"; je nach Projekt auch mehr. Ein Tag
# v... im Projekt-Repo passte zur Branch-Prüfung der Service Connection (refs/tags/v* für
# seed-pipelines) und käme ohne Review an die Deployment-Identität. Force push, Bypass policies
# und Edit policies hebelten Reviewer-Pflicht und PR-Validierung aus. Deny gilt für die Gruppe
# Contributors und für das Job-Token der Pipelines des Projekts (<Projekt> Build Service), nicht
# für Project Administrators. replace = false lässt andere Einträge am Repo stehen.
data "azuredevops_client_config" "this" {
  count = var.protect_repository ? 1 : 0
}

# Auch für contributors (Mitglieder des Projekts, unten).
data "azuredevops_group" "contributors" {
  count = var.protect_repository || length(var.contributors) > 0 ? 1 : 0

  project_id = local.project_id
  name       = "Contributors"
}

# Die Build-Service-Identität ist ein Dienstkonto, kein Benutzer der Organisation. Mit
# search_filter = "DisplayName" fände der Provider sie nicht: Er vergleicht mit dem
# Anzeigenamen des Anbieters, und das ist bei ihr die Projekt-ID. "General" nimmt den ersten
# Treffer; die Postcondition prüft, dass er zum Projekt gehört.
data "azuredevops_identity_user" "build_service" {
  count = var.protect_repository ? 1 : 0

  name          = "${local.project_name} Build Service (${data.azuredevops_client_config.this[0].name})"
  search_filter = "General"

  # Ein neues Projekt (create_project) und seine Build-Service-Identität gibt es erst im Apply.
  depends_on = [azuredevops_project.this]

  lifecycle {
    postcondition {
      condition     = endswith(lower(self.descriptor), lower(":Build:${local.project_id}"))
      error_message = "Die Build-Service-Identität des Projekts wurde nicht eindeutig gefunden; protect_repository = false und die Rechte von Hand setzen (README)."
    }
  }
}

locals {
  repository_denied_permissions = {
    for permission in ["CreateTag", "ForcePush", "PolicyExempt", "PullRequestBypassPolicy", "EditPolicies"] : permission => "Deny"
  }

  # Feste Schlüssel, damit for_each schon im Plan feststeht.
  repository_principals = var.protect_repository ? {
    contributors  = data.azuredevops_group.contributors[0].descriptor
    build_service = data.azuredevops_identity_user.build_service[0].subject_descriptor
  } : {}
}

resource "azuredevops_git_permissions" "repository" {
  for_each = local.repository_principals

  project_id    = local.project_id
  repository_id = local.repository_id
  principal     = each.value
  permissions   = local.repository_denied_permissions
  replace       = false

  # Erst nach Dateien und Policies: Ist die anlegende Identität selbst Contributor, dürfte sie
  # danach keine Policies mehr anlegen.
  depends_on = [
    azuredevops_git_repository_file.pipeline,
    azuredevops_branch_policy_build_validation.this,
    azuredevops_branch_policy_min_reviewers.this,
  ]
}

# --- Eigene Service Connection des Projekts --------------------------------------

# Service Connection des Projekts (create_service_connection) mit Workload Identity Federation,
# manuell: Die Identität (User-Assigned Managed Identity des Projekts) gibt es schon, das
# Federated Credential daran legt der Aufrufer danach aus den Outputs issuer und subject an.
# Sie entsteht erst, wenn Dateien, Branch-Policies und Rechte am Repo stehen; berechtigt wird die
# Pipeline erst, wenn auch die Checks daran stehen.
resource "azuredevops_serviceendpoint_azurerm" "this" {
  count = var.create_service_connection ? 1 : 0

  project_id                             = local.project_id
  service_endpoint_name                  = var.service_connection
  description                            = "Deployment-Identität des Seed-Projekts ${var.name}, nur für dessen Pipeline"
  service_endpoint_authentication_scheme = "WorkloadIdentityFederation"
  azurerm_spn_tenantid                   = var.service_connection_identity.tenant_id
  azurerm_subscription_id                = var.service_connection_identity.subscription_id
  azurerm_subscription_name              = var.service_connection_identity.subscription_name

  credentials {
    serviceprincipalid = var.service_connection_identity.client_id
  }

  # Das Federated Credential entsteht erst nach der Service Connection (Issuer und Subject).
  features {
    validate = false
  }

  depends_on = [
    azuredevops_git_repository_file.pipeline,
    azuredevops_branch_policy_build_validation.this,
    azuredevops_branch_policy_min_reviewers.this,
    azuredevops_git_permissions.repository,
  ]
}

locals {
  service_connection_id = (
    var.create_service_connection ? azuredevops_serviceendpoint_azurerm.this[0].id :
    var.authorize_service_connections ? data.azuredevops_serviceendpoint_azurerm.this[0].id : ""
  )

  # Die Branch-Prüfung vergleicht jedes Repo des Laufs mit derselben Liste, auch seed-pipelines,
  # das die Pipeline am Tag pipelines_version einbindet.
  service_connection_allowed_refs = ["refs/heads/main", "refs/tags/${var.pipelines_version}"]
}

# Nur Läufe von main (und seed-pipelines am eingebundenen Tag) bekommen die Identität.
resource "azuredevops_check_branch_control" "service_connection" {
  count = var.create_service_connection ? 1 : 0

  project_id                       = local.project_id
  display_name                     = "Nur main"
  target_resource_id               = azuredevops_serviceendpoint_azurerm.this[0].id
  target_resource_type             = "endpoint"
  allowed_branches                 = join(",", local.service_connection_allowed_refs)
  verify_branch_protection         = false
  ignore_unknown_protection_status = false
}

# Nur Läufe, die templates/web-app.yml aus seed-pipelines am Tag pipelines_version per extends
# einbinden. Eine neue Version von seed-pipelines braucht einen neuen Lauf des Moduls.
resource "azuredevops_check_required_template" "service_connection" {
  count = var.create_service_connection ? 1 : 0

  project_id           = local.project_id
  target_resource_id   = azuredevops_serviceendpoint_azurerm.this[0].id
  target_resource_type = "endpoint"

  required_template {
    repository_type = "github"
    repository_name = var.required_template_repository
    repository_ref  = "refs/tags/${var.pipelines_version}"
    template_path   = "templates/web-app.yml"
  }
}

# --- Mitglieder des Projekts ----------------------------------------------------

data "azuredevops_users" "members" {
  for_each       = toset(concat(var.contributors, var.project_administrators))
  principal_name = each.value

  lifecycle {
    postcondition {
      condition     = length(self.users) == 1
      error_message = "Kein eindeutiges Konto der Organisation zu ${each.value}; contributors und project_administrators nennen Principal Names (E-Mail) von Mitgliedern der Organisation."
    }
  }
}

data "azuredevops_group" "project_administrators" {
  count = length(var.project_administrators) > 0 ? 1 : 0

  project_id = local.project_id
  name       = "Project Administrators"
}

# mode = "add": Weitere Mitglieder der Gruppe bleiben, das Modul verwaltet nur die genannten.
resource "azuredevops_group_membership" "contributors" {
  count = length(var.contributors) > 0 ? 1 : 0

  group   = data.azuredevops_group.contributors[0].descriptor
  members = [for p in var.contributors : one(data.azuredevops_users.members[p].users).descriptor]
  mode    = "add"
}

# Ein Projektadministrator kann Branch-Policies, Rechte am Repo, Checks und Freigaben des Projekts
# aufheben; deshalb standardmäßig niemand (README).
resource "azuredevops_group_membership" "project_administrators" {
  count = length(var.project_administrators) > 0 ? 1 : 0

  group   = data.azuredevops_group.project_administrators[0].descriptor
  members = [for p in var.project_administrators : one(data.azuredevops_users.members[p].users).descriptor]
  mode    = "add"
}
