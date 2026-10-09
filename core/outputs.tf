output "resource_group_name" {
  description = "Name der Resource Group des Projekts."
  value       = azurerm_resource_group.this.name
}

output "location" {
  description = "Region von Function, Storage und Monitoring."
  value       = var.location
}

output "function_app_name" {
  description = "Name der Function App, Ziel des Deployments."
  value       = azapi_resource.function_app.name
}

output "function_app_url" {
  description = "Basis-URL der Function App."
  value       = "https://${azapi_resource.function_app.output.properties.defaultHostName}"
}

output "function_identity_principal_id" {
  description = "Principal-ID der Managed Identity der Function, für RBAC in weiteren Modulen."
  value       = azurerm_user_assigned_identity.function.principal_id
}

output "function_identity_client_id" {
  description = "Client-ID der Managed Identity der Function."
  value       = azurerm_user_assigned_identity.function.client_id
}

output "static_web_app_name" {
  description = "Name der Static Web App, Ziel des Frontend-Deployments."
  value       = azurerm_static_web_app.this.name
}

output "static_web_app_url" {
  description = "Öffentliche URL des Frontends."
  value       = "https://${azurerm_static_web_app.this.default_host_name}"
}

output "application_insights_connection_string" {
  description = "Connection String von Application Insights."
  value       = azurerm_application_insights.this.connection_string
  sensitive   = true
}
