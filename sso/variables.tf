variable "name" {
  description = "Projektname aus project.yaml."
  type        = string
}

variable "environment" {
  description = "Umgebung, z. B. dev, test oder prod."
  type        = string
}

variable "spa_redirect_uris" {
  description = "Redirect-URIs des Frontends: URL der Static Web App, eigene Domains, in dev zusätzlich http://localhost:5173. Ohne Pfad ergänzt das Modul den abschließenden Schrägstrich; das Frontend meldet sich mit window.location.origin + \"/\" an. Leer bei Projekten ohne Frontend: Dann entsteht nur die API-Registrierung."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for uri in var.spa_redirect_uris : can(regex("^(https://|http://localhost)", uri))])
    error_message = "spa_redirect_uris: jeweils https:// oder http://localhost."
  }
}

variable "scope_name" {
  description = "Name der delegierten Berechtigung der API; erscheint im scp-Claim."
  type        = string
  default     = "access_as_user"
}

variable "additional_owners" {
  description = "Weitere Besitzer der App-Registrierungen (Object-IDs). Die ausführende Identität ist immer Besitzerin."
  type        = list(string)
  default     = []
}

variable "spa_redirect_bridge_path" {
  description = "Pfad der Bridge-Seite für die stille Anmeldung im iframe (MSAL 5), z. B. /redirect.html. Das Modul trägt sie je Origin der spa_redirect_uris als Redirect-URI ein und nennt sie in frontend_config als redirectBridgePath. null: keine Bridge-Seite, seed-web-auth erneuert dann per Umleitung."
  type        = string
  default     = null

  validation {
    condition     = var.spa_redirect_bridge_path == null || can(regex("^/[^?#]+$", var.spa_redirect_bridge_path))
    error_message = "spa_redirect_bridge_path: Pfad mit führendem Schrägstrich, z. B. /redirect.html."
  }
}
