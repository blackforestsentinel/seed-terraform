variable "name" {
  description = "Projektname aus project.yaml. Kleinbuchstaben, Ziffern und Bindestriche."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.name))
    error_message = "name: 3-20 Zeichen, Kleinbuchstaben, Ziffern und Bindestriche, beginnt mit einem Buchstaben."
  }
}

variable "environment" {
  description = "Umgebung, z. B. dev, test oder prod."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.environment))
    error_message = "environment: 2-8 Zeichen, Kleinbuchstaben und Ziffern."
  }
}

variable "location" {
  description = "Azure-Region für Function App, Storage und Monitoring."
  type        = string
  default     = "westeurope"
}

variable "static_web_app_location" {
  description = "Azure-Region der Static Web App. Free-Tier gibt es nur in wenigen Regionen."
  type        = string
  default     = "westeurope"
}

variable "runtime_version" {
  description = "Version der dotnet-isolated-Runtime."
  type        = string
  default     = "10.0"
}

variable "instance_memory_mb" {
  description = "Speicher pro Instanz der Flex-Consumption-Function (512, 2048 oder 4096)."
  type        = number
  default     = 2048
}

variable "maximum_instance_count" {
  description = "Obergrenze für das Hochskalieren der Function."
  type        = number
  default     = 40
}

variable "app_settings" {
  description = "Zusätzliche App-Settings der Function, z. B. Auth__TenantId aus dem sso-Modul."
  type        = map(string)
  default     = {}
}

variable "cors_allowed_origins" {
  description = "Zusätzliche CORS-Origins. Die URL der Static Web App ist immer freigegeben."
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  description = "Aufbewahrung im Log Analytics Workspace."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Zusätzliche Tags für alle Ressourcen."
  type        = map(string)
  default     = {}
}
