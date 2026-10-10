variable "name" {
  description = "Projektname aus project.yaml, wie bei core."
  type        = string
}

variable "environment" {
  description = "Umgebung, z. B. dev, test oder prod."
  type        = string
}

variable "resource_group_name" {
  description = "Resource Group des Projekts (Output resource_group_name von core)."
  type        = string
}

variable "location" {
  description = "Azure-Region des Vaults (Output location von core)."
  type        = string
}

variable "function_identity_principal_id" {
  description = "Principal-ID der Managed Identity der Function (Output function_identity_principal_id von core). Sie bekommt Key Vault Secrets User auf dem Vault."
  type        = string
}

variable "secrets" {
  description = "Namen der Secrets, z. B. [\"stripe-key\"]. Je Name legt das Modul einen Platzhalter an und setzt das App-Setting Secrets__<Name in PascalCase> als Key-Vault-Referenz (stripe-key: Secrets__StripeKey, im Code Secrets:StripeKey)."
  type        = list(string)
  default     = []

  # Key Vault erlaubt Buchstaben, Ziffern und Bindestriche. Enger gefasst, damit die Abbildung
  # auf App-Settings eindeutig und umkehrbar ist: Jedes Wort beginnt mit einem Buchstaben, der
  # im Setting-Namen groß wird.
  validation {
    condition     = alltrue([for s in var.secrets : can(regex("^[a-z][a-z0-9]*(-[a-z][a-z0-9]*)*$", s)) && length(s) <= 127])
    error_message = "secrets: Kleinbuchstaben und Ziffern, Wörter durch einzelne Bindestriche getrennt, jedes Wort beginnt mit einem Buchstaben, höchstens 127 Zeichen (z. B. stripe-key, smtp-password)."
  }

  # App-Settings unterscheiden nicht zwischen Groß- und Kleinschreibung: stripe-key und
  # stripekey ergäben dasselbe Setting.
  validation {
    condition     = length(distinct([for s in var.secrets : replace(s, "-", "")])) == length(var.secrets)
    error_message = "secrets: Jeder Name nur einmal, und Namen müssen sich auch ohne Bindestriche unterscheiden (stripe-key und stripekey ergäben beide Secrets__StripeKey)."
  }
}

variable "secret_officers" {
  description = "Object-IDs von Personen oder Gruppen in Entra ID, die Werte setzen dürfen. Sie bekommen Key Vault Secrets Officer auf diesem Vault."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.secret_officers : can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", lower(id)))])
    error_message = "secret_officers: Object-IDs (GUID) aus Entra ID, keine Namen oder E-Mail-Adressen."
  }
}

variable "soft_delete_retention_days" {
  description = "Aufbewahrung gelöschter Secrets und des Vaults in Tagen (7 bis 90). Lässt sich nach dem Anlegen nicht mehr ändern; mit Purge-Schutz kann niemand vorher endgültig löschen."
  type        = number
  default     = 90

  validation {
    condition     = var.soft_delete_retention_days >= 7 && var.soft_delete_retention_days <= 90
    error_message = "soft_delete_retention_days: 7 bis 90."
  }
}

variable "tags" {
  description = "Zusätzliche Tags für den Vault."
  type        = map(string)
  default     = {}
}
