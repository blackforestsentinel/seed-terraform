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
    sso = optional(bool, false)
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
  description = "Principal Names (E-Mail) der Personen, die Infrastruktur-Änderungen freigeben. Leer: keine Freigabe."
  type        = list(string)
  default     = []
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

variable "authorize_service_connections" {
  description = "Pipeline für beide Service Connections berechtigen. Braucht die Administrator-Rolle an den Service Connections; seed-scaffold lässt das aus, dort gibt ein Admin beim ersten Lauf frei."
  type        = bool
  default     = true
}

variable "template_url" {
  description = "Git-URL des Projekt-Templates, aus dem das Repo importiert wird."
  type        = string
  default     = "https://github.com/blackforestsentinel/seed-template.git"
}

variable "pipelines_version" {
  description = "Tag von seed-pipelines, den das Projekt einbindet."
  type        = string
  default     = "v0.4.0"
}
