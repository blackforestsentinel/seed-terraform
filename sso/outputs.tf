locals {
  api_identifier_uri = "api://${azuread_application.api.client_id}"
  api_scope          = "${local.api_identifier_uri}/${var.scope_name}"
}

output "tenant_id" {
  description = "Tenant-ID von Entra ID."
  value       = data.azuread_client_config.current.tenant_id
}

output "api_client_id" {
  description = "Client-ID der API-App-Registrierung."
  value       = azuread_application.api.client_id
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
  description = "ID der delegierten Berechtigung, z. B. für weitere Clients wie den Custom Connector."
  value       = local.scope_id
}

output "spa_client_id" {
  description = "Client-ID der SPA-App-Registrierung, null ohne Frontend."
  value       = one(azuread_application.spa[*].client_id)
}

output "app_settings" {
  description = "App-Settings für die Function; Bfs.Seed.Auth liest sie aus dem Abschnitt Auth."
  value = merge({
    Auth__TenantId = data.azuread_client_config.current.tenant_id
    Auth__ClientId = azuread_application.api.client_id
    Auth__Audience = local.api_identifier_uri
  }, local.mcp_app_settings)
}

# Ohne SPA bleibt die Map leer; config.json bekommt dann keinen Auth-Teil.
output "frontend_config" {
  description = "Auth-Teil der Laufzeitkonfiguration des Frontends (config.json), passend zu @blackforestsentinel/seed-web-auth. Leer ohne Frontend."
  value = {
    for spa in azuread_application.spa : "auth" => {
      clientId = spa.client_id
      tenantId = data.azuread_client_config.current.tenant_id
      apiScope = local.api_scope
    }
  }
}
