output "repository_url" {
  description = "Clone-URL des neuen Repos."
  value       = azuredevops_git_repository.this.remote_url
}

output "repository_web_url" {
  description = "Web-Ansicht des neuen Repos."
  value       = azuredevops_git_repository.this.web_url
}

output "pipeline_id" {
  description = "ID der Pipeline des Projekts."
  value       = azuredevops_build_definition.this.id
}

output "environments" {
  description = "Angelegte Environments."
  value       = sort([for e in azuredevops_environment.this : e.name])
}
