output "storage_account_name" {
  description = "Name des Storage Accounts für die Daten des Projekts."
  value       = azurerm_storage_account.this.name
}

output "storage_account_id" {
  description = "Ressourcen-ID des Storage Accounts, z. B. für weitere Rollen."
  value       = azurerm_storage_account.this.id
}

output "blob_endpoint" {
  description = "Blob-Endpunkt, z. B. https://<konto>.blob.core.windows.net/."
  value       = azurerm_storage_account.this.primary_blob_endpoint
}

output "queue_endpoint" {
  description = "Queue-Endpunkt."
  value       = azurerm_storage_account.this.primary_queue_endpoint
}

output "table_endpoint" {
  description = "Table-Endpunkt."
  value       = azurerm_storage_account.this.primary_table_endpoint
}

output "connection_name" {
  description = "Name der Verbindung in den App-Settings, für Trigger (Connection = \"SeedStorage\") und Bfs.Seed.Storage."
  value       = local.connection_name
}

# Identitätsbasierte Verbindung im Format der Functions-Erweiterungen: Queue- und Blob-Trigger
# lesen <Verbindung>__queueServiceUri bzw. __blobServiceUri, Bfs.Seed.Storage alle drei.
# depends_on: Die Function bekommt die Verbindung erst, wenn ihre Rollen vergeben sind.
output "app_settings" {
  description = "App-Settings für die Function: Endpunkte der Verbindung SeedStorage, Anmeldung per Managed Identity."
  value = {
    "${local.connection_name}__blobServiceUri"  = azurerm_storage_account.this.primary_blob_endpoint
    "${local.connection_name}__queueServiceUri" = azurerm_storage_account.this.primary_queue_endpoint
    "${local.connection_name}__tableServiceUri" = azurerm_storage_account.this.primary_table_endpoint
    "${local.connection_name}__credential"      = "managedidentity"
    "${local.connection_name}__clientId"        = var.function_identity_client_id
  }
  depends_on = [azurerm_role_assignment.function]
}
