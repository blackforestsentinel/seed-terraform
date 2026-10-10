# Vorhandene App-Registrierung, auch aus einem anderen Tenant (etwa beim Kunden). Dann legt das
# Modul nichts an und reicht nur die Werte an Function und Frontend weiter; Redirect-URIs,
# Vorautorisierung und App-Rollen pflegt der Admin dort (README, Abschnitt sso).

variable "existing_registration" {
  description = "Vorhandene App-Registrierungen statt neuer: tenant_id, api_client_id, api_scope (vollständig, z. B. api://<client-id>/access_as_user), spa_client_id (null ohne Frontend) und optional audience (Application ID URI der API, Default: api_scope ohne den letzten Teil). null legt die Registrierungen im eigenen Tenant an."
  type = object({
    tenant_id     = string
    api_client_id = string
    api_scope     = string
    spa_client_id = optional(string)
    audience      = optional(string)
  })
  default = null

  validation {
    condition     = var.existing_registration == null || can(regex("^.+/[^/]+$", var.existing_registration.api_scope))
    error_message = "existing_registration.api_scope: vollständiger Name der Berechtigung, z. B. api://<client-id>/access_as_user."
  }
}

locals {
  create   = var.existing_registration == null
  existing = local.create ? null : var.existing_registration

  # Die Werte, mit denen Function und Frontend arbeiten, gleich ob angelegt oder vorhanden.
  tenant_id     = local.create ? data.azuread_client_config.current.tenant_id : local.existing.tenant_id
  api_client_id = local.create ? azuread_application.api[0].client_id : local.existing.api_client_id
  api_identifier_uri = local.create ? "api://${azuread_application.api[0].client_id}" : coalesce(
    local.existing.audience, regex("^(.+)/[^/]+$", local.existing.api_scope)[0],
  )
  api_scope_name = local.create ? var.scope_name : regex("[^/]+$", local.existing.api_scope)
  api_scope      = local.create ? "${local.api_identifier_uri}/${var.scope_name}" : local.existing.api_scope
  spa_client_id  = !local.spa ? null : local.create ? one(azuread_application.spa[*].client_id) : local.existing.spa_client_id

  # Schon beim Plan bekannt, auch wenn die Client-ID erst beim Apply entsteht.
  spa_client = local.spa && (local.create || try(local.existing.spa_client_id, null) != null)
}
