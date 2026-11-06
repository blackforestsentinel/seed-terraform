output "key_vault_id" {
  description = "Ressourcen-ID des Vaults, z. B. für weitere Rollen."
  value       = azurerm_key_vault.this.id
}

output "key_vault_name" {
  description = "Name des Vaults, für az keyvault secret set."
  value       = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  description = "URI des Vaults (https://<name>.vault.azure.net/)."
  value       = azurerm_key_vault.this.vault_uri
}

output "references" {
  description = "Key-Vault-Referenz je Secret-Name, für App-Settings mit eigenem Namen (z. B. Legacy__ApiToken)."
  value       = local.references
}

output "setting_names" {
  description = "App-Setting je Secret-Name, z. B. stripe-key => Secrets__StripeKey."
  value       = local.setting_names
}

# Erst nach Rolle und Platzhaltern: Die Plattform löst die Referenzen auf, sobald die App-Settings
# der Function sich ändern.
#
# Seed__KeyVaultUri: Zur Laufzeit enthalten die App-Settings nur die aufgelösten Werte, nicht die
# Referenzen. Ohne die URI kennt die App den Vault nicht und kann im Health-Report keine
# Ablaufdaten nennen. vault_uri statt eines selbst gebauten Namens: Azure liefert die URI mit der
# richtigen Endung, auch außerhalb der öffentlichen Cloud. Bei einem vorhandenen Vault steht sie im
# State und ist beim Plan bekannt; unbekannt ist sie nur, wenn der Vault im selben Apply entsteht,
# und dann ändern sich die App-Settings ohnehin.
output "app_settings" {
  description = "App-Settings für die Function: Secrets__<Name> als Key-Vault-Referenz je Secret und Seed__KeyVaultUri mit der URI des Vaults (für Ablaufdaten im Health-Report von Bfs.Seed.Functions.Core)."
  value = merge(
    { for s in var.secrets : local.setting_names[s] => local.references[s] },
    { Seed__KeyVaultUri = azurerm_key_vault.this.vault_uri },
  )

  depends_on = [azurerm_role_assignment.function, azapi_resource_action.placeholder]
}
