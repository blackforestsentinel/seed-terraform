output "project_id" {
  description = "ID des Azure-DevOps-Projekts, in dem Repo und Pipeline liegen."
  value       = data.azuredevops_project.this.id
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
