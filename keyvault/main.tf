data "azurerm_client_config" "current" {}

locals {
  base = "${var.name}-${var.environment}"

  # Dasselbe Kürzel wie in core: stabil je Subscription, Projekt und Umgebung.
  suffix = substr(sha256("${data.azurerm_client_config.current.subscription_id}/${local.base}"), 0, 6)

  # Vault-Namen sind global eindeutig, 3-24 Zeichen, ohne doppelte Bindestriche. Der Name bleibt
  # stabil, damit ein Apply nach einem Löschen den soft-gelöschten Vault wiederherstellt, statt
  # an dessen Namen zu scheitern.
  key_vault_name = "kv-${trimsuffix(substr(replace(local.base, "/-+/", "-"), 0, 14), "-")}-${local.suffix}"

  # Bfs.Seed.Functions.Core erkennt Platzhalter an diesem Präfix und nennt den Secret-Namen
  # dahinter im Health-Report.
  placeholder_prefix = "seed-placeholder:"

  # stripe-key -> Secrets__StripeKey: keine Bindestriche im Namen (unter Linux Umgebungsvariablen),
  # und .NET liest den Wert als Secrets:StripeKey.
  setting_names = {
    for s in var.secrets : s => "Secrets__${join("", [for w in split("-", s) : "${upper(substr(w, 0, 1))}${substr(w, 1, -1)}"])}"
  }

  # Versionslos: Die Plattform nimmt immer die aktuelle Version des Secrets. VaultName statt
  # SecretUri, weil der Text so schon beim Plan feststeht.
  references = {
    for s in var.secrets : s => "@Microsoft.KeyVault(VaultName=${local.key_vault_name};SecretName=${s})"
  }

  tags = merge(
    {
      "seed:project"     = var.name
      "seed:environment" = var.environment
      "seed:module"      = "keyvault"
    },
    var.tags,
  )
}

resource "azurerm_key_vault" "this" {
  name                = local.key_vault_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
  tags                = local.tags

  # Zugriff nur per Azure RBAC, keine Access Policies.
  rbac_authorization_enabled = true

  # Soft Delete ist bei Key Vault immer an; der Purge-Schutz verhindert zusätzlich, dass jemand
  # einen gelöschten Vault oder ein gelöschtes Secret vor Ablauf der Frist endgültig entfernt.
  purge_protection_enabled   = true
  soft_delete_retention_days = var.soft_delete_retention_days
}

# --- Rollen -------------------------------------------------------------------

# Die Function liest die Secrets über Key-Vault-Referenzen mit ihrer UAMI (core setzt dafür
# keyVaultReferenceIdentity).
resource "azurerm_role_assignment" "function" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.function_identity_principal_id
  principal_type       = "ServicePrincipal"
}

# Personen oder Gruppen, die Werte setzen. Owner und Contributor dürfen das bei einem
# RBAC-Vault nicht.
resource "azurerm_role_assignment" "secret_officers" {
  for_each = toset([for id in var.secret_officers : lower(id)])

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}

# --- Platzhalter --------------------------------------------------------------

# Über Azure Resource Manager statt über die Datenebene: Dafür reicht Contributor, die Pipeline
# braucht keine Rolle auf dem Vault, und ARM liefert Secret-Werte nie zurück. Ein von Hand
# gesetzter Wert landet also weder im State noch im Plan.
#
# Die Liste enthält nur Namen; die Pipeline liest sie bei jedem Plan.
data "azapi_resource_list" "secrets" {
  type      = "Microsoft.KeyVault/vaults/secrets@2024-11-01"
  parent_id = azurerm_key_vault.this.id

  response_export_values = { names = "value[].name" }
}

locals {
  # Key Vault unterscheidet bei Namen nicht zwischen Groß- und Kleinschreibung.
  listed_secrets   = try(data.azapi_resource_list.secrets.output.names, null)
  existing_secrets = toset([for n in coalesce(local.listed_secrets, []) : lower(n)])
}

# Ein Platzhalter darf nie einen gesetzten Wert überschreiben. Deshalb:
# - PUT nur für Secrets, die es im Vault noch nicht gibt; sonst ein GET, das nichts ändert. Das
#   greift nach einem wiederhergestellten Vault und bei einem Namen, der wieder in die Liste kommt.
# - ignore_changes = all: Die Aktion läuft einmal beim Anlegen, nie bei späteren Plänen.
# - Kein azapi_resource: ARM kann Secrets nicht löschen (405 DeleteNotSupported). Ein Name, der
#   aus der Liste fällt, bleibt deshalb im Vault, bis ihn jemand per CLI löscht.
resource "azapi_resource_action" "placeholder" {
  for_each = toset(var.secrets)

  type        = "Microsoft.KeyVault/vaults/secrets@2024-11-01"
  resource_id = "${azurerm_key_vault.this.id}/secrets/${each.value}"
  method      = contains(local.existing_secrets, each.value) ? "GET" : "PUT"
  body = contains(local.existing_secrets, each.value) ? null : {
    properties = {
      value = "${local.placeholder_prefix}${each.value}"
    }
  }

  response_export_values = []

  lifecycle {
    ignore_changes       = all
    replace_triggered_by = [azurerm_key_vault.this.id]
  }
}
