variable "ado_project" {
  description = "Azure-DevOps-Projekt, in dem Repo, Pipeline und Environments entstehen (Name oder ID); mit create_project der Name des neuen Projekts."
  type        = string

  validation {
    condition     = !var.create_project || can(regex("^[A-Za-z0-9]([A-Za-z0-9 ._-]{0,62}[A-Za-z0-9_-])?$", var.ado_project))
    error_message = "ado_project: Mit create_project ein Projektname aus höchstens 64 Buchstaben, Ziffern, Leerzeichen, Punkt, Unterstrich und Bindestrich, beginnt mit Buchstabe oder Ziffer, endet nicht mit Punkt oder Leerzeichen."
  }
}

variable "name" {
  description = "Projektname, wird zu project.yaml, Repo- und Pipeline-Name sowie Präfix der Environments."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.name))
    error_message = "name: 3-20 Zeichen, Kleinbuchstaben, Ziffern und Bindestriche, beginnt mit einem Buchstaben."
  }
}

variable "owner" {
  description = "Besitzer und Ansprechpartner des Projekts als E-Mail-Adresse, z. B. team@example.org; steht als owner in project.yaml. null oder leer: owner: \"\" mit TODO(onboarding), wie im Template."
  type        = string
  default     = null

  validation {
    condition     = var.owner == null || var.owner == "" || can(regex("^[^@\\s]+@[^@\\s]+[.][^@\\s]+$", var.owner))
    error_message = "owner: eine E-Mail-Adresse, z. B. team@example.org, oder leer."
  }
}

variable "features" {
  description = "Feature-Auswahl für project.yaml."
  type = object({
    sso     = optional(bool, false)
    mcp     = optional(bool, false)
    storage = optional(bool, false)
  })
  default = {}
}

variable "frontend" {
  description = "Projekt mit Frontend (Static Web App). false: nur API; project.yaml bekommt hosting.staticWebApp: none und azure-pipelines.yml frontend: false."
  type        = bool
  default     = true
}

variable "environments" {
  description = "Umgebungen in Deploy-Reihenfolge."
  type        = list(string)
  default     = ["dev"]

  # Wie alle Werte, die in azure-pipelines.yml landen, ohne Zeichen, die das YAML verändern könnten.
  validation {
    condition     = length(var.environments) > 0 && alltrue([for env in var.environments : can(regex("^[a-z0-9][a-z0-9-]{0,19}$", env))])
    error_message = "environments: mindestens eine Umgebung, jeweils Kleinbuchstaben, Ziffern und Bindestriche, höchstens 20 Zeichen, z. B. dev oder prod."
  }
}

variable "approvers" {
  description = "Principal Names (E-Mail) der Personen, die Infrastruktur-Änderungen freigeben. Leer und ohne approver_groups: keine Freigabe."
  type        = list(string)
  default     = []
}

variable "approver_groups" {
  description = "Gruppen der Organisation (Name), deren Mitglieder Infrastruktur-Änderungen ebenfalls freigeben, zusätzlich zu approvers. Im zentralen Scaffold eine feste Gruppe, damit nicht jede Person ihre eigene Infrastruktur allein freigibt."
  type        = list(string)
  default     = []
}

variable "requester_can_approve" {
  description = "Darf die Person, die einen Lauf ausgelöst hat, dessen Infrastruktur-Änderung selbst freigeben? Im zentralen Scaffold false."
  type        = bool
  default     = true
}

variable "app_approval_environments" {
  description = "Umgebungen, in denen auch der App-Deploy eine Freigabe braucht, z. B. [\"prod\"]."
  type        = list(string)
  default     = []
}

variable "service_connection" {
  description = "Name der Azure-Service-Connection (Workload Identity Federation) im Projekt; mit create_service_connection der Name der neuen, etwa sc-<name>."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._ -]*$", var.service_connection))
    error_message = "service_connection: Buchstaben, Ziffern, Punkt, Unterstrich, Bindestrich und Leerzeichen, beginnt mit Buchstabe oder Ziffer."
  }
}

variable "github_connection" {
  description = "Name der GitHub-Service-Connection, über die die Pipeline-Templates gelesen werden."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._ -]*$", var.github_connection))
    error_message = "github_connection: Buchstaben, Ziffern, Punkt, Unterstrich, Bindestrich und Leerzeichen, beginnt mit Buchstabe oder Ziffer."
  }
}

variable "terraform_state" {
  description = "Ablage des Terraform-States im Tenant."
  type = object({
    resource_group  = string
    storage_account = string
    container       = string
  })

  validation {
    condition     = can(regex("^[A-Za-z0-9._()-]{1,90}$", var.terraform_state.resource_group))
    error_message = "terraform_state.resource_group: Name einer Resource Group, höchstens 90 Zeichen aus Buchstaben, Ziffern, Punkt, Unterstrich, Bindestrich und Klammern."
  }

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.terraform_state.storage_account))
    error_message = "terraform_state.storage_account: Name eines Storage Accounts, 3-24 Kleinbuchstaben und Ziffern."
  }

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.terraform_state.container))
    error_message = "terraform_state.container: Name eines Blob-Containers, 3-63 Kleinbuchstaben, Ziffern und Bindestriche."
  }
}

variable "pr_validation" {
  description = "Branch-Policy auf main: Pull Requests brauchen einen erfolgreichen PR-Lauf der Pipeline (Build, Tests, Secret-Scan). Pflicht, sperrt damit direkte Pushes auf main. Braucht die Berechtigung \"Edit policies\" am Repo."
  type        = bool
  default     = true
}

variable "authorize_service_connections" {
  description = "Pipeline für beide Service Connections berechtigen. Braucht die Administrator-Rolle an den Service Connections: Das zentrale Scaffold hat sie, weil es die Service Connections selbst ins Projekt teilt; seed-scaffold im eigenen Projekt lässt das aus, dort gibt ein Admin beim ersten Lauf frei. Mit create_service_connection hat die anlegende Identität die Rolle an der eigenen Service Connection."
  type        = bool
  default     = true
}

variable "min_reviewers" {
  description = "Pull Requests auf main brauchen so viele Zustimmungen anderer Personen; die eigene Stimme zählt nicht. Standard 1, weil die Stage Plan die Service Connection vor jeder Freigabe nutzt. 0: keine Pflicht. Sperrt wie pr_validation direkte Pushes auf main."
  type        = number
  default     = 1

  validation {
    condition     = var.min_reviewers >= 0 && var.min_reviewers <= 10 && floor(var.min_reviewers) == var.min_reviewers
    error_message = "min_reviewers: ganze Zahl von 0 bis 10."
  }
}

variable "create_repository" {
  description = "Repo aus template_url importieren. false: Das Repo gibt es schon (repository), etwa für das zentrale Scaffold, dessen Job-Token keine Repos anlegen darf; seed-template führt dann die Pipeline vorher ein."
  type        = bool
  default     = true
}

variable "repository" {
  description = "Name des Repos; leer: name."
  type        = string
  default     = ""
}

variable "pool" {
  description = "Agent-Pool der Projekt-Pipeline (Parameter pool von web-app.yml ab seed-pipelines v0.13.0); leer: Microsoft-gehostete Agents."
  type        = string
  default     = ""

  validation {
    condition     = var.pool == "" || can(regex("^[A-Za-z0-9][A-Za-z0-9._ -]*$", var.pool))
    error_message = "pool: leer oder Name eines Agent-Pools aus Buchstaben, Ziffern, Punkt, Unterstrich, Bindestrich und Leerzeichen, beginnt mit Buchstabe oder Ziffer."
  }
}

variable "template_url" {
  description = "Git-URL des Projekt-Templates, aus dem das Repo importiert wird."
  type        = string
  default     = "https://github.com/blackforestsentinel/seed-template.git"
}

variable "pipelines_version" {
  description = "Tag von seed-pipelines, den das Projekt einbindet, z. B. v0.17.0."
  type        = string
  default     = "v0.5.0"

  validation {
    condition     = can(regex("^v\\d+\\.\\d+\\.\\d+$", var.pipelines_version))
    error_message = "pipelines_version: ein Release-Tag von seed-pipelines, z. B. v0.17.0."
  }
}

variable "protect_repository" {
  description = "Rechte am Repo einschränken: Contributors des Projekts und <Projekt> Build Service bekommen Deny für Create tag, Force push, Bypass policies when pushing, Bypass policies when completing pull requests und Edit policies. Braucht die Berechtigung \"Manage permissions\" am Repo (README). false: Projekt-Defaults, wie bis v0.17.0."
  type        = bool
  default     = true
  nullable    = false
}

# --- Selbstbedienung: Projekt, Identität und Mitglieder (ab v0.20.0) ---------------

variable "create_project" {
  description = "Projekt ado_project neu anlegen (privat, Git, nur Repos und Pipelines). Die anlegende Identität wird dessen Projektadministrator. false (Standard): Das Projekt gibt es schon."
  type        = bool
  default     = false
  nullable    = false
}

variable "project_description" {
  description = "Beschreibung eines neuen Projekts (create_project); null: keine."
  type        = string
  default     = null
}

variable "create_service_connection" {
  description = "Azure-Service-Connection service_connection im Projekt selbst anlegen (Workload Identity Federation, manuell) für die Identität aus service_connection_identity, mit Branch-Prüfung und Required-Template-Check. false (Standard): Sie gibt es schon, etwa als geteilte Service Connection."
  type        = bool
  default     = false
  nullable    = false
}

variable "service_connection_identity" {
  description = "Identität hinter der Service Connection (create_service_connection): Tenant, Subscription (ID und Name) und client_id der User-Assigned Managed Identity des Projekts."
  type = object({
    tenant_id         = string
    subscription_id   = string
    subscription_name = string
    client_id         = string
  })
  default = null

  validation {
    condition     = !var.create_service_connection || var.service_connection_identity != null
    error_message = "service_connection_identity: Mit create_service_connection Pflicht."
  }

  validation {
    condition = var.service_connection_identity == null ? true : alltrue([
      for id in [var.service_connection_identity.tenant_id, var.service_connection_identity.subscription_id, var.service_connection_identity.client_id] :
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))
    ]) && trimspace(var.service_connection_identity.subscription_name) != ""
    error_message = "service_connection_identity: tenant_id, subscription_id und client_id als GUID, subscription_name nicht leer."
  }
}

variable "required_template_repository" {
  description = "GitHub-Repo (Besitzer/Name) mit templates/web-app.yml, das der Required-Template-Check an der eigenen Service Connection verlangt; für Forks von seed-pipelines."
  type        = string
  default     = "blackforestsentinel/seed-pipelines"
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$", var.required_template_repository))
    error_message = "required_template_repository: GitHub-Repo als Besitzer/Name, z. B. blackforestsentinel/seed-pipelines."
  }
}

variable "contributors" {
  description = "Principal Names (E-Mail) von Personen der Organisation, die Mitglied der Gruppe Contributors des Projekts werden."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for p in var.contributors : can(regex("^[^@\\s]+@[^@\\s]+$", p))])
    error_message = "contributors: Principal Names wie person@example.org."
  }
}

variable "project_administrators" {
  description = "Principal Names (E-Mail) von Personen, die Mitglied der Gruppe Project Administrators des Projekts werden. Vorsicht: Ein Projektadministrator kann Branch-Policies, Rechte am Repo, Checks und Freigaben des Projekts aufheben. Standard: niemand."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for p in var.project_administrators : can(regex("^[^@\\s]+@[^@\\s]+$", p))])
    error_message = "project_administrators: Principal Names wie person@example.org."
  }
}

variable "create_resource_groups" {
  description = "false: project.yaml bekommt createResourceGroups: false; die Projekt-Pipeline legt die Resource Groups rg-<name>-<umgebung> dann nicht an, weil der Aufrufer (zentrales Scaffold) sie vorab anlegt. Standard true: wie bisher."
  type        = bool
  default     = true
  nullable    = false
}
