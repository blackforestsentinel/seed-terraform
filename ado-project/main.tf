data "azuredevops_project" "this" {
  name = var.ado_project
}

data "azuredevops_serviceendpoint_azurerm" "this" {
  count                 = var.authorize_service_connections ? 1 : 0
  project_id            = data.azuredevops_project.this.id
  service_endpoint_name = var.service_connection
}

data "azuredevops_serviceendpoint_github" "this" {
  count                 = var.authorize_service_connections ? 1 : 0
  project_id            = data.azuredevops_project.this.id
  service_endpoint_name = var.github_connection
}

data "azuredevops_users" "approvers" {
  for_each       = toset(var.approvers)
  principal_name = each.value
}

locals {
  approver_ids = [for u in data.azuredevops_users.approvers : one(u.users).id]

  # Je Umgebung: <name>-<env> für Infrastruktur (mit Freigabe), <name>-<env>-app für den App-Deploy.
  environments = merge(
    { for env in var.environments : "${env}-infra" => { name = "${var.name}-${env}", approval = length(local.approver_ids) > 0, description = "Infrastruktur ${env}: terraform apply" } },
    { for env in var.environments : "${env}-app" => { name = "${var.name}-${env}-app", approval = contains(var.app_approval_environments, env) && length(local.approver_ids) > 0, description = "App-Deploy ${env}" } },
  )

  branch = "refs/heads/main"

  # PR-Läufe ohne Deploy kennt web-app.yml erst ab seed-pipelines v0.5.0; mit einer älteren
  # Version würde die PR-Validierung den PR-Stand deployen. Branches (Tests) gelten als neu.
  pipelines_semver  = try([for part in regex("^v(\\d+)\\.(\\d+)\\.(\\d+)$", var.pipelines_version) : tonumber(part)], null)
  pr_runs_supported = local.pipelines_semver == null ? true : local.pipelines_semver[0] * 1000000 + local.pipelines_semver[1] * 1000 + local.pipelines_semver[2] >= 5000
}

# --- Repo aus dem Template ------------------------------------------------------

resource "azuredevops_git_repository" "this" {
  project_id     = data.azuredevops_project.this.id
  name           = var.name
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

# Projektspezifische Dateien einmalig schreiben; spätere Änderungen macht das Projekt selbst.
resource "azuredevops_git_repository_file" "project_yaml" {
  repository_id       = azuredevops_git_repository.this.id
  branch              = local.branch
  file                = "project.yaml"
  content             = templatefile("${path.module}/templates/project.yaml.tftpl", { name = var.name, features = var.features, frontend = var.frontend })
  commit_message      = "seed-scaffold: project.yaml für ${var.name}"
  overwrite_on_create = true

  lifecycle {
    ignore_changes = [content, commit_message]
  }
}

resource "azuredevops_git_repository_file" "pipeline" {
  repository_id = azuredevops_git_repository.this.id
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
  })
  commit_message      = "seed-scaffold: azure-pipelines.yml für ${var.name}"
  overwrite_on_create = true

  lifecycle {
    ignore_changes = [content, commit_message]
  }

  depends_on = [azuredevops_git_repository_file.project_yaml]
}

# --- Environments und Freigaben -------------------------------------------------

resource "azuredevops_environment" "this" {
  for_each = local.environments

  project_id  = data.azuredevops_project.this.id
  name        = each.value.name
  description = each.value.description
}

resource "azuredevops_check_approval" "this" {
  for_each = { for k, v in local.environments : k => v if v.approval }

  project_id                 = data.azuredevops_project.this.id
  target_resource_id         = azuredevops_environment.this[each.key].id
  target_resource_type       = "environment"
  approvers                  = local.approver_ids
  minimum_required_approvers = 1
  requester_can_approve      = true
  instructions               = "Plan im Log der Stage Plan prüfen, dann freigeben."
}

# --- Pipeline -------------------------------------------------------------------

resource "azuredevops_build_definition" "this" {
  project_id = data.azuredevops_project.this.id
  name       = var.name

  ci_trigger {
    use_yaml = true
  }

  repository {
    repo_type   = "TfsGit"
    repo_id     = azuredevops_git_repository.this.id
    branch_name = local.branch
    yml_path    = "azure-pipelines.yml"
  }

  depends_on = [azuredevops_git_repository_file.pipeline]
}

resource "azuredevops_pipeline_authorization" "endpoints" {
  for_each = var.authorize_service_connections ? {
    azure  = data.azuredevops_serviceendpoint_azurerm.this[0].id
    github = data.azuredevops_serviceendpoint_github.this[0].id
  } : {}

  project_id  = data.azuredevops_project.this.id
  resource_id = each.value
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.this.id
}

resource "azuredevops_pipeline_authorization" "environments" {
  for_each = azuredevops_environment.this

  project_id  = data.azuredevops_project.this.id
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

  project_id = data.azuredevops_project.this.id
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
      repository_id  = azuredevops_git_repository.this.id
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
