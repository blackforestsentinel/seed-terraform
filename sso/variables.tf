variable "name" {
  description = "Projektname aus project.yaml."
  type        = string
}

variable "environment" {
  description = "Umgebung, z. B. dev, test oder prod."
  type        = string
}

variable "spa_redirect_uris" {
  description = "Redirect-URIs des Frontends: URL der Static Web App, in dev zusätzlich http://localhost:5173. Ohne abschließenden Schrägstrich, so wie window.location.origin."
  type        = list(string)

  validation {
    condition     = length(var.spa_redirect_uris) > 0 && alltrue([for uri in var.spa_redirect_uris : can(regex("^(https://|http://localhost)", uri))])
    error_message = "spa_redirect_uris: mindestens eine URI, jeweils https:// oder http://localhost."
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
