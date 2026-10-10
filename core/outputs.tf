output "resource_group_name" {
  description = "Name der Resource Group des Projekts."
  value       = azurerm_resource_group.this.name
}

output "resource_group_id" {
  description = "ID der Resource Group, z. B. als Geltungsbereich des Budgets im Modul monitoring."
  value       = azurerm_resource_group.this.id
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

# Ohne Static Web App leer statt null: Die Pipeline liest die Werte mit terraform output -raw.
output "static_web_app_name" {
  description = "Name der Static Web App, Ziel des Frontend-Deployments. Leer ohne Frontend (static_web_app_sku = None)."
  value       = local.static_web_app ? azurerm_static_web_app.this[0].name : ""
}

output "static_web_app_url" {
  description = "Öffentliche URL des Frontends unter der Standard-Domain von Azure. Leer ohne Frontend."
  value       = local.static_web_app ? "https://${azurerm_static_web_app.this[0].default_host_name}" : ""
}

output "custom_domain_dns_records" {
  description = "DNS-Einträge je eigener Domain: TXT-Eintrag für die Validierung (txt_name, txt_value) und das Ziel für den Datenverkehr (cname; bei einer Apex-Domain als ALIAS, ANAME oder per CNAME-Flattening)."
  value = {
    for domain in local.custom_domains : domain => {
      txt_name  = "_dnsauth.${domain}"
      txt_value = terraform_data.custom_domain_token[domain].output
      cname     = azurerm_static_web_app.this[0].default_host_name
    }
  }
}

output "application_insights_id" {
  description = "ID von Application Insights, für Alarme und Webtests im Modul monitoring."
  value       = azurerm_application_insights.this.id
}

output "log_analytics_workspace_id" {
  description = "ID des Log Analytics Workspace."
  value       = azurerm_log_analytics_workspace.this.id
}

output "application_insights_connection_string" {
  description = "Connection String von Application Insights."
  value       = azurerm_application_insights.this.connection_string
  sensitive   = true
}
