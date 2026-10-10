data "azurerm_client_config" "current" {}

locals {
  base = "${var.name}-${var.environment}"

  # Eigener Storage Account für die Daten des Projekts, getrennt vom Host-Storage der
  # Function (core): andere Rollen, eigene Aufbewahrung, und Löschen oder Ersetzen des einen
  # trifft nie den anderen. "data" im Namen unterscheidet ihn im Portal vom Host-Storage.
  suffix               = substr(sha256("${data.azurerm_client_config.current.subscription_id}/${local.base}/storage"), 0, 6)
  storage_account_name = "st${substr(replace(local.base, "-", ""), 0, 12)}data${local.suffix}"

  # Name der Verbindung in den App-Settings. Nicht AzureWebJobsStorage: Das ist der
  # Host-Storage; Trigger und Paket nutzen ausdrücklich diese Verbindung.
  connection_name = "SeedStorage"

  # Datenrollen der Function. Die Bedingung der Pipeline-Identität (Onboarding) erlaubt genau
  # diese Storage-Rollen; Blob Data Contributor reicht ohne ACLs (kein Data Owner nötig).
  data_roles = toset([
    "Storage Blob Data Contributor",
    "Storage Queue Data Contributor",
    "Storage Table Data Contributor",
  ])

  tags = merge(
    {
      "seed:project"     = var.name
      "seed:environment" = var.environment
      "seed:module"      = "storage"
    },
    var.tags,
  )
}

resource "azurerm_storage_account" "this" {
  name                             = local.storage_account_name
  resource_group_name              = var.resource_group_name
  location                         = var.location
  account_kind                     = "StorageV2"
  account_tier                     = "Standard"
  account_replication_type         = var.replication_type
  min_tls_version                  = "TLS1_2"
  https_traffic_only_enabled       = true
  shared_access_key_enabled        = false
  default_to_oauth_authentication  = true
  allow_nested_items_to_be_public  = false
  cross_tenant_replication_enabled = false
  local_user_enabled               = false
  tags                             = local.tags

  # Versionierung hält überschriebene und gelöschte Blobs als vorherige Version; die Regel
  # seed-previous-versions unten löscht sie nach blob_version_retention_days. Soft Delete hält
  # danach noch gelöschte Versionen und Container wiederherstellbar.
  blob_properties {
    versioning_enabled = var.blob_versioning_enabled

    delete_retention_policy {
      days = var.blob_soft_delete_days
    }

    container_delete_retention_policy {
      days = var.container_soft_delete_days
    }
  }
}

# --- Tabellen, Container, Queues (über ARM, die Pipeline braucht keine Datenrollen) ---------

resource "azurerm_storage_table" "this" {
  for_each = toset(var.tables)

  name               = each.value
  storage_account_id = azurerm_storage_account.this.id
}

resource "azurerm_storage_container" "this" {
  for_each = toset(var.containers)

  name                  = each.value
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# Die Poison-Queue <name>-poison legt der Functions-Host bei Bedarf selbst an.
resource "azurerm_storage_queue" "this" {
  for_each = toset(var.queues)

  name               = each.value
  storage_account_id = azurerm_storage_account.this.id
}

# --- Lifecycle ----------------------------------------------------------------

# Ohne Löschregel blieben vorherige Versionen für immer liegen, auch nach dem Löschen eines
# Blobs. Azure kennt kein "Tage seit Ablösung": Das Alter einer Version zählt ab ihrer
# Entstehung, also ab dem Schreiben des Inhalts. Eine Version verschwindet damit höchstens
# blob_version_retention_days nach dem Überschreiben oder Löschen (plus bis zu einem Tag, weil
# Azure die Regeln täglich auswertet) und liegt danach noch blob_soft_delete_days im Soft Delete.
resource "azurerm_storage_management_policy" "this" {
  count = var.blob_versioning_enabled || length(var.lifecycle_rules) > 0 ? 1 : 0

  storage_account_id = azurerm_storage_account.this.id

  dynamic "rule" {
    for_each = var.blob_versioning_enabled ? [1] : []

    content {
      name    = "seed-previous-versions"
      enabled = true

      filters {
        blob_types = ["blockBlob"]
      }

      actions {
        version {
          delete_after_days_since_creation = var.blob_version_retention_days
        }

        snapshot {
          delete_after_days_since_creation_greater_than = var.blob_version_retention_days
        }
      }
    }
  }

  dynamic "rule" {
    for_each = var.lifecycle_rules

    content {
      name    = rule.value.name
      enabled = true

      filters {
        blob_types   = ["blockBlob"]
        prefix_match = rule.value.prefixes
      }

      actions {
        base_blob {
          tier_to_cool_after_days_since_modification_greater_than = rule.value.cool_after_days
          delete_after_days_since_modification_greater_than       = rule.value.delete_after_days
        }
      }
    }
  }
}

# --- Löschsperre ----------------------------------------------------------------

# Sperren erbt alles unterhalb des Accounts: Mit Sperre scheitert auch das Löschen einer
# Tabelle, Queue oder eines Containers per Terraform. depends_on auf alles im Modul sorgt dafür,
# dass Terraform die Sperre beim Abbau zuerst entfernt (allow_data_deletion) und erst danach
# die Daten löscht. Datenebene (Blobs, Entitäten, Nachrichten) betrifft die Sperre nicht.
resource "azurerm_management_lock" "this" {
  count = var.deletion_lock && !var.allow_data_deletion ? 1 : 0

  name       = "seed-deletion-lock"
  scope      = azurerm_storage_account.this.id
  lock_level = "CanNotDelete"
  notes      = "Sentinel Seed: schützt die Daten von ${local.base}. Gewolltes Löschen nur über einen bestätigten Pipeline-Lauf (Datenlöschung bestätigen)."

  depends_on = [
    azurerm_storage_table.this,
    azurerm_storage_container.this,
    azurerm_storage_queue.this,
    azurerm_storage_management_policy.this,
    azurerm_role_assignment.function,
  ]
}

# --- Rollen der Function --------------------------------------------------------

resource "azurerm_role_assignment" "function" {
  for_each = local.data_roles

  scope                = azurerm_storage_account.this.id
  role_definition_name = each.value
  principal_id         = var.function_identity_principal_id
  principal_type       = "ServicePrincipal"
}
