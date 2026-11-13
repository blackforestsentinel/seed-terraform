output "project_id" {
  description = "ID des Azure-DevOps-Projekts, in dem Repo und Pipeline liegen."
  value       = local.project_id
}

output "repository_url" {
  description = "Clone-URL des Repos."
  value       = local.repository_remote_url
}

output "repository_web_url" {
  description = "Web-Ansicht des Repos."
  value       = local.repository_web_url
}

output "pipeline_id" {
  description = "ID der Pipeline des Projekts."
  value       = azuredevops_build_definition.this.id
}

output "environments" {
  description = "Angelegte Environments."
  value       = sort([for e in azuredevops_environment.this : e.name])
}

# Leer statt null, wo es nichts gibt: Die Pipeline liest die Werte mit terraform output -raw.
output "service_connection_id" {
  description = "ID der Azure-Service-Connection: der eigenen (create_service_connection) oder der vorhandenen, für die das Modul die Pipeline berechtigt. Sonst leer."
  value       = local.service_connection_id
}

output "workload_identity_federation_issuer" {
  description = "Issuer der eigenen Service Connection für das Federated Credential an der Identität des Projekts. Leer ohne create_service_connection."
  value       = var.create_service_connection ? azuredevops_serviceendpoint_azurerm.this[0].workload_identity_federation_issuer : ""
}

output "workload_identity_federation_subject" {
  description = "Subject der eigenen Service Connection für das Federated Credential an der Identität des Projekts. Leer ohne create_service_connection."
  value       = var.create_service_connection ? azuredevops_serviceendpoint_azurerm.this[0].workload_identity_federation_subject : ""
}
