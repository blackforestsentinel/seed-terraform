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
  description = "Key-Vault-Referenz je Secret-Name, für App-Settings mit eigenem Namen (z. B. Ffh__Weclapp__Token)."
  value       = local.references
}

output "setting_names" {
  description = "App-Setting je Secret-Name, z. B. stripe-key => Secrets__StripeKey."
  value       = local.setting_names
}

# Erst nach Rolle und Platzhaltern: Die Plattform löst die Referenzen auf, sobald die App-Settings
# der Function sich ändern.
output "app_settings" {
  description = "App-Settings für die Function: Secrets__<Name> als Key-Vault-Referenz je Secret."
  value       = { for s in var.secrets : local.setting_names[s] => local.references[s] }

  depends_on = [azurerm_role_assignment.function, azapi_resource_action.placeholder]
}
