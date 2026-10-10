# storage

Eigener Storage Account für die Daten eines Projekts, mit Tabellen, Queues und Containern, Versionierung, Soft Delete, Lifecycle-Regeln und Datenrollen für die Managed Identity der Function. Getrennt vom Host-Storage aus `core`: andere Rollen, eigene Aufbewahrung, und das eine lässt sich ändern oder ersetzen, ohne das andere zu treffen.

```hcl
module "storage" {
  source = "git::https://github.com/blackforestsentinel/seed-terraform.git//storage?ref=<version>"
  count  = local.cfg.features.storage ? 1 : 0

  name                           = local.cfg.project
  environment                    = var.environment
  resource_group_name            = module.core.resource_group_name
  location                       = module.core.location
  function_identity_principal_id = module.core.function_identity_principal_id
  function_identity_client_id    = module.core.function_identity_client_id

  tables     = ["jobs"]
  queues     = ["jobs"]
  containers = ["uploads"]

  lifecycle_rules = [
    { name = "uploads-90-tage", prefixes = ["uploads/"], cool_after_days = 30, delete_after_days = 90 },
  ]
}

module "core" {
  # ...
  app_settings = merge({ Seed__Features__Storage = "true" }, [for m in module.storage : m.app_settings]...)
}
```

Im Template übernimmt das `infra/storage.tf` aus dem Abschnitt `storage:` der `project.yaml`.

## Storage Account

- Name `st<projekt><umgebung>data<kürzel>` (Projekt und Umgebung zusammen auf 12 Zeichen gekürzt), Kürzel stabil je Subscription, Projekt und Umgebung. `data` unterscheidet ihn im Portal vom Host-Storage.
- Kein Shared Key (`shared_access_key_enabled = false`), Entra ID als Standard im Portal, TLS 1.2, nur HTTPS, kein öffentlicher Blob-Zugriff, keine Replikation in andere Tenants, keine lokalen Benutzer (SFTP).
- Öffentlicher Netzwerkzugang bleibt an: Flex Consumption ohne VNet erreicht den Account sonst nicht.
- Tabellen, Queues und Container entstehen über die Azure-Ressourcenverwaltung (`storage_account_id`). Die Pipeline-Identität braucht dafür keine Datenrollen, `Contributor` genügt.

## Rollen der Function

Die User-Assigned Managed Identity der Function bekommt auf dem Account:

| Rolle | Wofür |
| --- | --- |
| Storage Blob Data Contributor | Blobs lesen, schreiben, löschen; Container anlegen. Data Owner ist ohne ACLs (kein Data Lake) nicht nötig. |
| Storage Queue Data Contributor | Nachrichten senden und verarbeiten; der Host legt damit auch die Poison-Queue an. |
| Storage Table Data Contributor | Tabellen lesen und schreiben. |

Die Bedingung der Pipeline-Identität aus dem Tenant-Onboarding erlaubt genau die Storage-Datenrollen; das Modul braucht keine weiteren Rechte. Rollen wirken erst nach einigen Minuten. Der Output `app_settings` hängt deshalb an den Rollen: Die Function bekommt die Verbindung erst, wenn die Rollen vergeben sind.

## Verbindung `SeedStorage`

Der Output `app_settings` beschreibt eine identitätsbasierte Verbindung im Format der Functions-Erweiterungen:

| App-Setting | Wert |
| --- | --- |
| `SeedStorage__blobServiceUri` | Blob-Endpunkt |
| `SeedStorage__queueServiceUri` | Queue-Endpunkt |
| `SeedStorage__tableServiceUri` | Table-Endpunkt |
| `SeedStorage__credential` | `managedidentity` |
| `SeedStorage__clientId` | Client-ID der Managed Identity |

Der Name ist bewusst nicht `AzureWebJobsStorage`, damit Trigger und Code nie versehentlich den Host-Storage nutzen. Queue-Trigger verwenden `Connection = "SeedStorage"`, `Bfs.Seed.Storage` liest dieselben Settings.

## Aufbewahrung und Lifecycle

| Einstellung | Default | Wirkung |
| --- | --- | --- |
| `blob_versioning_enabled` | `true` | Überschreiben und Löschen hinterlassen eine vorherige Version. |
| `blob_version_retention_days` | 7 | Die Regel `seed-previous-versions` löscht vorherige Versionen und Snapshots nach so vielen Tagen ab ihrer Entstehung. |
| `blob_soft_delete_days` | 7 | Gelöschte Blobs und Versionen bleiben so lange wiederherstellbar. |
| `container_soft_delete_days` | 7 | Ein gelöschter Container bleibt samt Inhalt so lange wiederherstellbar. |
| `lifecycle_rules` | keine | Eigene Regeln: Präfixe (`<container>/<pfad>`), `cool_after_days`, `delete_after_days`, jeweils ab der letzten Änderung. |

Azure kennt für Versionen kein „Tage seit Ablösung“; das Alter zählt ab dem Schreiben des Inhalts. Gelöschte oder überschriebene Daten sind deshalb spätestens nach `blob_version_retention_days` + 1 Tag (Azure wertet die Regeln täglich aus) + `blob_soft_delete_days` endgültig weg, mit den Defaults nach 15 Tagen. Wer Löschfristen zusagt (etwa in Datenschutzhinweisen), rechnet mit dieser Summe. Löscht eine eigene Regel Blobs, kommt deren Frist davor.

Tabellen und Queues haben weder Versionierung noch Soft Delete. Ein Backup gehört nicht zum Modul.

## Schutz vor dem Löschen

Fällt ein Name aus `tables`, `queues` oder `containers` heraus, würde der nächste Apply die Tabelle, Queue oder den Container samt Inhalt löschen; mit `features.storage: false` den ganzen Account. Container bleiben `container_soft_delete_days` lang wiederherstellbar, Tabellen und Queues nicht. Davor stehen zwei Schichten:

1. **Löschsperre** (`deletion_lock`, Default `true`): `CanNotDelete` auf dem Account. Sie verhindert das Löschen im Portal, per CLI und zusammen mit der Resource Group. Sperren gelten auch für alles unterhalb des Accounts; ein Apply, der eine Tabelle, Queue oder einen Container entfernt, scheitert deshalb an der Sperre. Blobs, Entitäten und Nachrichten (Datenebene) betrifft sie nicht.
2. **Bestätigung in der Pipeline** (seed-pipelines ab v0.5.0): Ein Plan, der Storage-Ressourcen löscht oder ersetzt, endet vor der Freigabe. Weiter geht es nur mit einem von Hand gestarteten Lauf mit „Datenlöschung bestätigen“. Dieser Lauf setzt `allow_data_deletion = true`; das Modul hebt die Sperre dann auf und entfernt sie vor allem anderen (`depends_on`), danach löscht der Apply die Daten. Der nächste Lauf ohne Bestätigung setzt die Sperre wieder und braucht dafür eine Freigabe.

Sperren setzen und entfernen darf `Contributor` nicht. Die Pipeline-Identität bekommt dafür beim Tenant-Onboarding die Rolle `Sentinel Seed Lock Contributor`, die nur Sperren verwalten darf. Mit `deletion_lock = false` (im Template `storage.deletionLock: false`) entfällt die Sperre, etwa für Wegwerf-Umgebungen; die Bestätigung in der Pipeline bleibt.

## Queues und Poison-Queue

Die Poison-Queue `<name>-poison` legt der Functions-Host selbst an, wenn eine Nachricht nach `maxDequeueCount` Versuchen (Default 5, `host.json`) nicht verarbeitet ist. Deshalb sind Queue-Namen auf 56 Zeichen begrenzt, damit `-poison` noch passt. Nachrichten in der Poison-Queue verarbeitet niemand automatisch; sie verfallen nach 7 Tagen. Terraform verwaltet die Poison-Queue nicht; entfernt man die Queue, bleibt sie stehen.

## Ausgaben

`app_settings`, `connection_name` (`SeedStorage`), `storage_account_name`, `storage_account_id`, `blob_endpoint`, `queue_endpoint`, `table_endpoint`.
