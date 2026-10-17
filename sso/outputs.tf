output "tenant_id" {
  description = "Tenant-ID von Entra ID, bei existing_registration die des anderen Tenants."
  value       = local.tenant_id
}

output "api_client_id" {
  description = "Client-ID der API-App-Registrierung."
  value       = local.api_client_id
}

output "api_identifier_uri" {
  description = "Application ID URI der API."
  value       = local.api_identifier_uri
}

output "api_scope" {
  description = "Vollständiger Name der delegierten Berechtigung, den Clients anfordern."
  value       = local.api_scope
}

output "api_scope_id" {
  description = "ID der delegierten Berechtigung, z. B. für weitere Clients wie den Custom Connector; null bei existing_registration."
  value       = local.create ? local.scope_id : null
}

output "spa_client_id" {
  description = "Client-ID der SPA-App-Registrierung, null ohne Frontend."
  value       = local.spa_client_id
}

output "spa_redirect_uris" {
  description = "Redirect-URIs der SPA samt Bridge-Seite und spa_extra_redirect_uris; bei existing_registration die URIs, die der Admin im anderen Tenant einträgt."
  value       = local.spa ? local.spa_all_redirect_uris : []
}

output "app_settings" {
  description = "App-Settings für die Function; Bfs.Seed.Auth liest sie aus dem Abschnitt Auth."
  value = merge(
    {
      Auth__TenantId = local.tenant_id
      Auth__ClientId = local.api_client_id
      Auth__Audience = local.api_identifier_uri
    },
    # Nur bei einer anderen Berechtigung als dem Default von Bfs.Seed.Auth, damit sich bestehende
    # Function Apps nicht ändern.
    local.api_scope_name == "access_as_user" ? {} : { Auth__RequiredScope = local.api_scope_name },
    local.mcp_app_settings,
  )
}

# Ohne SPA bleibt die Map leer; config.json bekommt dann keinen Auth-Teil.
output "frontend_config" {
  description = "Auth-Teil der Laufzeitkonfiguration des Frontends (config.json), passend zu @blackforestsentinel/seed-web-auth; mit directory zusätzlich directory für @blackforestsentinel/seed-web-people. Leer ohne Frontend."
  value = {
    for key in local.spa_client ? ["auth"] : [] : key => merge(
      {
        clientId = local.spa_client_id
        tenantId = local.tenant_id
        apiScope = local.api_scope
      },
      # Nur mit Bridge-URIs, nicht für eine SPA allein aus spa_extra_redirect_uris. Aus den
      # Variablen statt aus spa_bridge_uris, damit schon beim Plan bekannt.
      var.spa_redirect_bridge_path == null || length(var.spa_redirect_uris) == 0 ? {} : { redirectBridgePath = var.spa_redirect_bridge_path },
      local.directory_frontend_config,
    )
  }
}
