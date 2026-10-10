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
  description = "Redirect-URIs der SPA samt Bridge-Seite; bei existing_registration die URIs, die der Admin im anderen Tenant einträgt."
  value       = local.spa ? concat(local.spa_redirect_uris, local.spa_bridge_uris) : []
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
  )
}

# Ohne SPA bleibt die Map leer; config.json bekommt dann keinen Auth-Teil.
output "frontend_config" {
  description = "Auth-Teil der Laufzeitkonfiguration des Frontends (config.json), passend zu @blackforestsentinel/seed-web-auth. Leer ohne Frontend."
  value = {
    for key in local.spa_client ? ["auth"] : [] : key => merge(
      {
        clientId = local.spa_client_id
        tenantId = local.tenant_id
        apiScope = local.api_scope
      },
      var.spa_redirect_bridge_path == null ? {} : { redirectBridgePath = var.spa_redirect_bridge_path },
    )
  }
}
