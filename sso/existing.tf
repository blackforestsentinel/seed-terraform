# Vorhandene App-Registrierung, auch aus einem anderen Tenant (etwa beim Kunden). Dann legt das
# Modul nichts an und reicht nur die Werte an Function und Frontend weiter; Redirect-URIs,
# Vorautorisierung und App-Rollen pflegt der Admin dort (README, Abschnitt sso).

variable "existing_registration" {
  description = "Vorhandene App-Registrierungen statt neuer: tenant_id, api_client_id, api_scope (vollständig, z. B. api://<client-id>/access_as_user), spa_client_id (null ohne Frontend) und optional audience (Application ID URI der API, Default: api_scope ohne den letzten Teil). Optional die Client-IDs weiterer Clients aus dem anderen Tenant: connector_client_id (mit connector), mcp_client_id (mit mcp Pflicht) und mcp_preauthorized_client_ids (für mcp_access vorautorisierte Clients, etwa VS Code). Sie stehen mit dem passenden Schalter (Frontend, connector, mcp) in Auth__AllowedClientIds, die SPA vorn. null legt die Registrierungen im eigenen Tenant an."
  type = object({
    tenant_id                    = string
    api_client_id                = string
    api_scope                    = string
    spa_client_id                = optional(string)
    audience                     = optional(string)
    connector_client_id          = optional(string)
    mcp_client_id                = optional(string)
    mcp_preauthorized_client_ids = optional(list(string), [])
  })
  default = null

  validation {
    condition     = var.existing_registration == null || can(regex("^.+/[^/]+$", var.existing_registration.api_scope))
    error_message = "existing_registration.api_scope: vollständiger Name der Berechtigung, z. B. api://<client-id>/access_as_user."
  }

  # Bfs.Seed.Auth startet nicht mit einem Eintrag in Auth__AllowedClientIds, der keine GUID ist.
  validation {
    condition = var.existing_registration == null || alltrue([
      for id in concat(
        [var.existing_registration.tenant_id, var.existing_registration.api_client_id],
        compact([
          var.existing_registration.spa_client_id,
          var.existing_registration.connector_client_id,
          var.existing_registration.mcp_client_id,
        ]),
        var.existing_registration.mcp_preauthorized_client_ids,
      ) : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))
    ])
    error_message = "existing_registration: tenant_id und alle Client-IDs (api_client_id, spa_client_id, connector_client_id, mcp_client_id, mcp_preauthorized_client_ids) jeweils als GUID."
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

  # Zugelassene Clients aus der vorhandenen Registrierung (main.tf), wie bei eigenen
  # Registrierungen je nach Schalter: SPA mit Frontend, Connector-Client mit connector, MCP-Client
  # und seine vorautorisierten Clients mit mcp. Alles schon im Plan bekannt.
  existing_own_client_ids = local.create ? [] : [
    for id in compact([
      local.spa_client_id,
      var.connector ? local.existing.connector_client_id : null,
      var.mcp ? local.existing.mcp_client_id : null,
    ]) : lower(id)
  ]
  existing_preauthorized_client_ids = local.create || !var.mcp ? [] : local.existing.mcp_preauthorized_client_ids
}
