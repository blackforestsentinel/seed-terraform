# Modul keyvault

Key Vault je Projekt und Umgebung für Secrets von Drittanbietern (API-Keys, Passwörter). Terraform legt den Vault, die Rollen und je Secret einen Platzhalter an; den Wert setzt ein Mensch per CLI oder Portal. Die Function liest die Secrets über Key-Vault-Referenzen in ihren App-Settings, im Code steht kein Zugriff auf den Vault.

```hcl
module "keyvault" {
  source = "git::https://github.com/blackforestsentinel/seed-terraform.git//keyvault?ref=<version>"
  count  = local.cfg.features.keyVault ? 1 : 0

  name                           = local.cfg.project
  environment                    = var.environment
  resource_group_name            = module.core.resource_group_name
  location                       = module.core.location
  function_identity_principal_id = module.core.function_identity_principal_id
  secrets                        = ["stripe-key", "smtp-password"]
  secret_officers                = [] # Object-IDs von Personen oder Gruppen
}

module "core" {
  # ...
  app_settings = merge({}, [for m in module.keyvault : m.app_settings]...)
}
```

## Was entsteht

| Ressource | Einstellung | Warum |
| --- | --- | --- |
| Key Vault `kv-<projekt-umgebung, gekürzt>-<kürzel>` | Standard, nur Azure RBAC, öffentlich erreichbar | Die Function (Flex Consumption ohne VNet) erreicht den Vault nur öffentlich; Zugriff regelt RBAC |
| | Purge-Schutz an, Soft Delete 90 Tage | siehe unten |
| Rolle Key Vault Secrets User | UAMI der Function, nur auf diesem Vault | Auflösen der Referenzen |
| Rolle Key Vault Secrets Officer | `secret_officers`, nur auf diesem Vault | Werte setzen; Owner und Contributor dürfen das bei einem RBAC-Vault nicht |
| Secret je Name in `secrets` | Wert `seed-placeholder:<name>` | Die Referenz löst sich sofort auf, `Bfs.Seed.Functions.Core` erkennt den Platzhalter |

Der Name des Vaults ist stabil: `kv-` plus höchstens 14 Zeichen aus `<projekt>-<umgebung>` plus dasselbe Kürzel wie in `core` (aus Subscription, Projekt und Umgebung). So bleibt er unter 24 Zeichen, global eindeutig und ohne doppelte Bindestriche.

## Secrets und App-Settings

Je Secret setzt das Modul ein App-Setting mit einer versionslosen Key-Vault-Referenz:

```
Secrets__StripeKey = @Microsoft.KeyVault(VaultName=kv-…;SecretName=stripe-key)
```

Regel für die Namen:

- **Secret-Name** (Key Vault, `project.yaml`): Kleinbuchstaben und Ziffern, Wörter durch einzelne Bindestriche getrennt, jedes Wort beginnt mit einem Buchstaben, höchstens 127 Zeichen. Key Vault selbst erlaubt Buchstaben, Ziffern und Bindestriche; die engere Regel macht die Abbildung eindeutig und umkehrbar.
- **App-Setting:** `Secrets__` plus der Secret-Name, bei dem jedes Wort groß beginnt und die Bindestriche entfallen. App-Setting-Namen sollen nur Buchstaben, Ziffern, Punkte und Unterstriche enthalten, weil sie unter Linux Umgebungsvariablen werden.
- **Im Code:** `Secrets:StripeKey`, mit `Bfs.Seed.Functions.Core` einfacher `secrets.Get("stripe-key")`.

| Secret | App-Setting |
| --- | --- |
| `stripe-key` | `Secrets__StripeKey` |
| `openai-api-key` | `Secrets__OpenaiApiKey` |
| `smtp2-password` | `Secrets__Smtp2Password` |

Zwei Namen, die sich nur durch Bindestriche unterscheiden (`stripe-key`, `stripekey`), lehnt das Modul ab: App-Settings unterscheiden keine Groß- und Kleinschreibung.

Braucht der Code ein anderes Setting, etwa beim Umzug eines bestehenden Projekts, liefert der Output `references` die Referenz je Secret-Name:

```hcl
app_settings = { Ffh__Weclapp__Token = module.keyvault[0].references["weclapp-token"] }
```

`Bfs.Seed.Functions.Core` prüft beim Start alle App-Settings, nicht nur `Secrets__*`.

## Platzhalter

Die Platzhalter entstehen über Azure Resource Manager (`Microsoft.KeyVault/vaults/secrets` per `azapi_resource_action`), nicht über die Datenebene des Vaults:

- Dafür reicht `Contributor`. Die Pipeline braucht keine Rolle auf dem Vault und kann keine Werte lesen.
- ARM liefert Secret-Werte nie zurück. Ein von Hand gesetzter Wert landet weder im Terraform-State noch im Plan.

Ein Platzhalter überschreibt nie einen gesetzten Wert:

- Terraform schreibt ihn nur für Secrets, die es im Vault noch nicht gibt (Liste per ARM, nur Namen). Für vorhandene Secrets, etwa nach dem Wiederherstellen des Vaults oder wenn ein Name wieder in die Liste kommt, läuft stattdessen ein GET, das nichts ändert.
- Danach fasst Terraform den Platzhalter nicht mehr an (`ignore_changes = all`). Ein Update wäre ein PUT mit dem Platzhalter; Anlässe gäbe es genug, schon `az keyvault secret set` hängt das Tag `file-encoding` an.

**Secret aus der Liste nehmen:** Terraform entfernt nur das App-Setting. Das Secret bleibt im Vault, weil ARM Secrets nicht löschen kann (`405 DeleteNotSupported`); daher auch kein `azapi_resource`, sonst scheiterten Entfernen und `destroy`. Nicht mehr gebrauchte Secrets löscht ein Secrets Officer per `az keyvault secret delete`; mit Purge-Schutz bleiben sie bis zum Ende der Frist wiederherstellbar. Kommt ein soft-gelöschter Name wieder in die Liste, scheitert der Apply, bis jemand das Secret mit `az keyvault secret recover` zurückholt.

## Werte setzen

Nötig ist `Key Vault Secrets Officer` auf dem Vault, über `secret_officers` oder einmalig von Hand (Owner der Subscription darf die Rolle vergeben):

```bash
KV=<key_vault_name>
az role assignment create --assignee <object-id oder upn> --role "Key Vault Secrets Officer" \
  --scope "$(az keyvault show --name "$KV" --query id -o tsv)"

read -rs VALUE && az keyvault secret set --vault-name "$KV" --name stripe-key --value "$VALUE" --output none; unset VALUE

# Neue Werte sofort übernehmen (Contributor oder Website Contributor auf der Function App)
az rest --method post --url "https://management.azure.com$(az functionapp show --name <function_app_name>   --resource-group <resource_group_name> --query id -o tsv)/config/configreferences/appsettings/refresh?api-version=2022-03-01"
```

`read -rs` hält den Wert aus der Shell-History, `--output none` aus der Ausgabe (sonst gibt die CLI das Secret samt Wert zurück).

## Wann neue Werte wirken (Flex Consumption)

Key-Vault-Referenzen funktionieren auf Flex Consumption, wenn `keyVaultReferenceIdentity` auf die UAMI zeigt (setzt `core`). Gemessen im Oktober 2026:

| Auslöser | Wirkung |
| --- | --- |
| App-Settings ändern sich (Apply mit neuem Secret) | Referenzen sofort aufgelöst, 30 Sekunden nach der Rollenvergabe |
| `…/config/configreferences/appsettings/refresh` (siehe oben) | neuer Wert nach rund 15 Sekunden |
| Deploy der Function (`az functionapp deployment source config-zip`, also jeder Pipeline-Lauf) | neuer Wert direkt nach dem Deploy |
| `az functionapp restart` | **keine**: Die laufende Instanz startete nicht neu, auch nach 3,5 Minuten kam der alte Wert |
| nichts | laut Microsoft spätestens nach 24 Stunden; nach 6 Minuten im Test noch der alte Wert |

Den Status jeder Referenz zeigt `GET …/config/configreferences/appsettings?api-version=2022-03-01` (`Resolved`, `SecretNotFound`, `AccessToKeyVaultDenied` …); jedes Setting erscheint dort zusätzlich als `APPSETTING_<Name>`. Einen Platzhalter meldet ARM als `Resolved`; den erkennt erst `Bfs.Seed.Functions.Core`.

## Soft Delete und Purge-Schutz

Beides ist immer an. Ein gelöschter Vault und jedes gelöschte Secret bleiben bis zum Ende der Frist wiederherstellbar; vorher kann niemand sie endgültig entfernen, auch kein Owner.

**Aufbewahrung 90 Tage** (`soft_delete_retention_days`, 7 bis 90):

- Der Wert lässt sich nach dem Anlegen nicht mehr ändern. Lieber die längste Frist, als später festzustellen, dass sie zu kurz war.
- Ein gelöschter Vault kostet nichts; die Frist schützt vor versehentlichem `terraform destroy`, gelöschten Secrets und Löschungen, die erst nach Urlaub oder Monatsabschluss auffallen.
- Der Nachteil, ein blockierter Name, entfällt durch den stabilen Namen und die Wiederherstellung (siehe unten).
- Für Wegwerf-Umgebungen und Tests sind 7 Tage sinnvoll.

**Gleichnamiger Vault nach dem Löschen:** Der Name hängt nur an Subscription, Projekt und Umgebung. Ein Apply nach einem `destroy` (oder nach `keyVault: false` und wieder `true`) trifft deshalb auf den soft-gelöschten Vault. Mit `recover_soft_deleted_key_vaults = true` (Default von azurerm) stellt Terraform ihn wieder her, samt Secrets und Werten; die Platzhalter überschreiben nichts (getestet). Ohne diese Einstellung scheitert der Apply, bis die Frist abgelaufen ist. Liegt der soft-gelöschte Vault in einer anderen Region als der neue, scheitert der Apply ebenfalls bis zum Ablauf der Frist. `purge_soft_delete_on_destroy = false` vermeidet beim `destroy` den Versuch, den Vault endgültig zu löschen; mit Purge-Schutz ginge das ohnehin nicht.

```hcl
provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
  storage_use_azuread = true
}
```

## Rechte der ausführenden Identität

| Recht | Wofür |
| --- | --- |
| `Contributor` | Vault anlegen, wiederherstellen, löschen; Secrets per ARM auflisten (nur Namen) und Platzhalter anlegen |
| `Role Based Access Control Administrator`, Bedingung erlaubt `Key Vault Secrets User` (`4633458b-17de-408a-b874-0445c86b69e6`) | Rolle der Function |
| dieselbe Bedingung erlaubt `Key Vault Secrets Officer` (`b86a8fe4-44ce-4948-aee5-eccb2c155cd7`) | nur mit `secret_officers` |

Eine Datenrolle auf dem Vault braucht die ausführende Identität nicht.

## Ein- und Ausgaben

Eingaben: `name`, `environment`, `resource_group_name`, `location`, `function_identity_principal_id`, `secrets`, `secret_officers`, `soft_delete_retention_days` (Default 90), `tags`.

Ausgaben: `app_settings` (`Secrets__<Name>` als Referenz, erst nach Rolle und Platzhaltern), `references` (Referenz je Secret-Name), `setting_names` (App-Setting je Secret-Name), `key_vault_name`, `key_vault_uri`, `key_vault_id`.
