variable "ado_project" {
  description = "Azure-DevOps-Projekt, in dem Repo, Pipeline und Environments entstehen (Name oder ID)."
  type        = string
}

variable "name" {
  description = "Projektname, wird zu project.yaml, Repo- und Pipeline-Name sowie Präfix der Environments."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.name))
    error_message = "name: 3-20 Zeichen, Kleinbuchstaben, Ziffern und Bindestriche, beginnt mit einem Buchstaben."
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
  description = "Name der Azure-Service-Connection (Workload Identity Federation) im Projekt."
  type        = string
}

variable "github_connection" {
  description = "Name der GitHub-Service-Connection, über die die Pipeline-Templates gelesen werden."
  type        = string
}

variable "terraform_state" {
  description = "Ablage des Terraform-States im Tenant."
  type = object({
    resource_group  = string
    storage_account = string
    container       = string
  })
}

variable "pr_validation" {
  description = "Branch-Policy auf main: Pull Requests brauchen einen erfolgreichen PR-Lauf der Pipeline (Build, Tests, Secret-Scan). Pflicht, sperrt damit direkte Pushes auf main. Braucht die Berechtigung \"Edit policies\" am Repo."
  type        = bool
  default     = true
}

variable "authorize_service_connections" {
  description = "Pipeline für beide Service Connections berechtigen. Braucht die Administrator-Rolle an den Service Connections: Das zentrale Scaffold hat sie, weil es die Service Connections selbst ins Projekt teilt; seed-scaffold im eigenen Projekt lässt das aus, dort gibt ein Admin beim ersten Lauf frei."
  type        = bool
  default     = true
}

variable "min_reviewers" {
  description = "Pull Requests auf main brauchen so viele Zustimmungen anderer Personen; die eigene Stimme zählt nicht. 0: keine Pflicht. Sperrt wie pr_validation direkte Pushes auf main."
  type        = number
  default     = 0

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
}

variable "template_url" {
  description = "Git-URL des Projekt-Templates, aus dem das Repo importiert wird."
  type        = string
  default     = "https://github.com/blackforestsentinel/seed-template.git"
}

variable "pipelines_version" {
  description = "Tag von seed-pipelines, den das Projekt einbindet."
  type        = string
  default     = "v0.5.0"
}
