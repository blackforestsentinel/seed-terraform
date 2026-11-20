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
  description = "ID der Azure-Service-Connection: der eigenen (create_service_connection) oder der vorhandenen, für die das Modul die Pipeline berechtigt. Sonst leer, auch mit environment_service_connections."
  value       = local.service_connection_id
}

output "workload_identity_federation_issuer" {
  description = "Issuer der eigenen Service Connection für das Federated Credential an der Identität des Projekts. Leer ohne create_service_connection und mit environment_service_connections."
  value       = var.create_service_connection && !local.per_environment ? azuredevops_serviceendpoint_azurerm.this[0].workload_identity_federation_issuer : ""
}

output "workload_identity_federation_subject" {
  description = "Subject der eigenen Service Connection für das Federated Credential an der Identität des Projekts. Leer ohne create_service_connection und mit environment_service_connections."
  value       = var.create_service_connection && !local.per_environment ? azuredevops_serviceendpoint_azurerm.this[0].workload_identity_federation_subject : ""
}

# --- Service Connection je Umgebung (ab v0.21.0) ---------------------------------
# Leere Maps statt null, wo es nichts gibt.

output "service_connection_ids" {
  description = "Mit environment_service_connections: Umgebung => ID der Azure-Service-Connection, der eigenen (create_service_connection) oder der vorhandenen, für die das Modul die Pipeline berechtigt. Sonst {}."
  value       = local.service_connection_ids
}

output "workload_identity_federation" {
  description = "Mit environment_service_connections und create_service_connection: Umgebung => { issuer, subject } der eigenen Service Connection für das Federated Credential an der Identität dieser Umgebung. Sonst {}."
  value = {
    for env, sc in azuredevops_serviceendpoint_azurerm.environments : env => {
      issuer  = sc.workload_identity_federation_issuer
      subject = sc.workload_identity_federation_subject
    }
  }
}
