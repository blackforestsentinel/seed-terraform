# monitoring

Alarme und Budget für ein Seed-Projekt, je Umgebung. Das Modul baut auf `core` auf und wird nur eingebunden, wenn es Empfänger gibt (`alert_emails` oder `owner`); ohne Empfänger gibt es keine Alarme und kein Budget.

```hcl
module "monitoring" {
  source = "git::https://github.com/blackforestsentinel/seed-terraform.git//monitoring?ref=<version>"
  count  = length(local.alert_emails) > 0 || local.owner != null ? 1 : 0

  name                       = local.cfg.project
  environment                = var.environment
  owner                      = local.owner # owner in project.yaml oder null
  resource_group_name        = module.core.resource_group_name
  resource_group_id          = module.core.resource_group_id
  location                   = module.core.location
  application_insights_id    = module.core.application_insights_id
  log_analytics_workspace_id = module.core.log_analytics_workspace_id
  alert_emails               = local.alert_emails
  health_check_url           = "${module.core.function_app_url}/api/health"
  exception_threshold        = 5
  budget_amount              = 20
  # Alarm vor dem Ablauf von Secrets, nur mit Key Vault
  key_vault_ids = { for m in module.keyvault : "keyvault" => m.key_vault_id }
}
```

Im Template steuert der Abschnitt `monitoring:` in `project.yaml` die Eingaben.

## Was entsteht

| Ressource | Inhalt |
| --- | --- |
| Aktionsgruppe `ag-<projekt>-<umgebung>` | Eine E-Mail je Empfänger im gemeinsamen Alarmschema; mit `owner` auch an den Besitzer, außer er steht schon in `alert_emails`. Alle Alarme und das Budget melden über diese Gruppe. Azure schickt jeder neuen Adresse einmal eine Mail, dass sie hinzugefügt wurde. |
| Alarm `alert-…-exceptions` | Abfrage auf Application Insights alle 15 Minuten über die letzte Stunde; meldet, sobald es `exception_threshold` (Default 5) Exceptions gab. Jede Exception zählt einmal, ob unbehandelt oder per `LogError` geloggt. Schweregrad 2. |
| Logic App `logic-…-health` und Alarm `alert-…-health-check` | Die Logic App ruft `health_check_url` alle `health_check_interval_hours` Stunden (Default 4) ohne Token auf. Bei Zeitüberschreitung, 408, 429 und 5xx wiederholt sie den Aufruf viermal; antwortet der Endpunkt auch dann nicht mit 2xx, scheitert der Lauf. Der Alarm prüft alle 15 Minuten, ob ein Lauf gescheitert ist. Schweregrad 1. Entfällt mit `health_check_url = null`. |
| Alarm `alert-…-daily-cap` | Meldet, wenn der Log Analytics Workspace sein Tageslimit (`core`: `log_daily_quota_gb`) erreicht hat. Bis 0 Uhr UTC kommt dann keine Telemetrie mehr an, und die übrigen Alarme bleiben still. Schweregrad 2. |
| System-Topic `egst-<projekt>-<umgebung>-<schlüssel>` und zwei Abonnements | Je Eintrag in `key_vault_ids`: Event Grid meldet Ereignisse des Key Vaults als Alarm in Azure Monitor an die Aktionsgruppe. `secret-near-expiry` 30 Tage vor dem Ablauf eines Secrets (Schweregrad 2), `secret-expired` beim Ablauf (Schweregrad 1). Secrets ohne Ablaufdatum lösen nichts aus. Details unter [Ablauf von Secrets](#ablauf-von-secrets). |
| Budget `budget-<projekt>-<umgebung>` | Monatsbudget der ganzen Resource Group in der Abrechnungswährung. Warnung bei 80 % der tatsächlichen Kosten und wenn die Prognose 100 % übersteigt. Entfällt mit `budget_amount = 0`. |

Alle Alarme außer denen zum Ablauf von Secrets lösen sich selbst auf, sobald die Bedingung nicht mehr zutrifft; je Vorfall kommt also eine Mail und eine Entwarnung. Beim Health-Check kommt die Entwarnung erst, wenn der letzte gescheiterte Lauf aus dem Fenster des Alarms fällt, mit dem Default 6 Stunden nach diesem Lauf.

## Entscheidungen

**Nur Zählwerte in den Meldungen.** Die Abfragen enden in einem einzigen `summarize count()`. Eine Alarm-Mail verlässt Azure; Nachrichten und Details von Exceptions können Mandantendaten enthalten und bleiben deshalb in Application Insights, hinter dessen Zugriffsschutz. Wer eigene Alarme ergänzt, hält es genauso.

**Health-Check von außen.** Flex Consumption fährt ohne Last auf null Instanzen herunter. Den Health-Check von App Service (`healthCheckPath`) gibt es dort nicht, und ein Alarm auf fehlende Requests oder Lebenszeichen würde bei jeder ruhigen App anschlagen. Ein Aufruf von außen prüft, ob die App antwortet, und startet sie dafür notfalls. Der Endpunkt muss ohne Token erfolgreich antworten; im Template ist das `/api/health` (`[AllowAnonymous]`).

**Alle 4 Stunden, per Logic App.** Jeder Aufruf nach einer Ruhephase startet eine Instanz, zählt gegen das Freikontingent der Function und schreibt die Startmeldungen des Hosts in die Logs. Bis v0.12.0 rief ein Webtest von Application Insights alle 15 Minuten aus zwei Standorten auf, rund 190 Mal am Tag; die Startmeldungen machten in einem migrierten Projekt einen großen Teil der Logs aus. Webtests laufen höchstens alle 15 Minuten, deshalb übernimmt eine Logic App mit Zeitplan. Ein Ausfall fällt so spätestens nach 4 Stunden und 15 Minuten auf; wer es früher wissen muss, setzt `health_check_interval_hours` kleiner.

**Ein Standort, dafür Wiederholungen.** Die Logic App ruft aus der Region des Projekts auf. Kurze Störungen und den Kaltstart überbrückt die Standard-Wiederholung (bis zu vier Wiederholungen, je Versuch bis zu zwei Minuten Timeout). Das Fenster des Alarms ist länger als der Abstand der Läufe: Scheitern zwei Läufe nacheinander, bleibt der Alarm bestehen, statt zwischendurch Entwarnung zu geben.

**Jede Exception zählt einmal.** Zu einer unbehandelten Exception in einer Function schreibt die Plattform neben dem Eintrag des Workers zwei weitere ohne SDK-Version und Vorgang. Die Abfrage lässt diese weg (`isnotempty(sdkVersion)`), sonst lösten schon zwei fehlgeschlagene Aufrufe den Alarm bei 5 aus.

**Exceptions statt fehlgeschlagener Requests.** Exceptions erfassen auch Fehler außerhalb von HTTP (Timer, Queues) und geloggte Fehler (`LogError` mit Exception). Ein Alarm auf fehlgeschlagene Requests würde nur HTTP sehen.

## Ablauf von Secrets

Trägt ein Secret im Key Vault ein Ablaufdatum (`exp`), meldet Key Vault über Event Grid zwei Ereignisse: `Microsoft.KeyVault.SecretNearExpiry` 30 Tage vorher und `Microsoft.KeyVault.SecretExpired` beim Ablauf. Das Modul abonniert beide am System-Topic des Vaults mit dem Ziel „Azure Monitor alert“: Jedes Ereignis wird ein Alarm in Azure Monitor und geht an die Aktionsgruppe, also an `alert_emails` und `owner`. Seed erzwingt kein Ablaufdatum; ohne `exp` passiert nichts.

```bash
# Ablaufdatum mit dem Wert setzen (neue Version) …
read -rs VALUE && az keyvault secret set --vault-name "$KV" --name stripe-key --value "$VALUE" \
  --expires 2027-06-30T00:00:00Z --output none; unset VALUE
# … oder an der aktuellen Version nachtragen
az keyvault secret set-attributes --vault-name "$KV" --name stripe-key --expires 2027-06-30T00:00:00Z
```

Welches Secret betroffen ist, zeigt der Alarm in seinen Details (Azure Monitor, Alarme): `ObjectName` und `EXP` aus den Daten des Ereignisses. Eine Entwarnung gibt es bei diesen Alarmen nicht, denn es gibt keine Bedingung, die wieder entfällt; nach dem Tausch des Secrets schließt man den Alarm im Portal.

**Warum Event Grid mit dem Ziel „Azure Monitor alert“.** Es ist der einfachste Weg ohne eigenen Code und ohne Zeitplan: Key Vault meldet das Ereignis selbst, Event Grid stellt es zu, die Aktionsgruppe verschickt die Mail. Microsoft bietet das Ziel für Ereignisse von Key Vault an, seit Anfang 2026 nicht mehr als Vorschau; die API-Version `2025-02-15` ist stabil. Verworfen:

- Logic App oder Function als Empfänger: mehr Teile, die ausfallen können; eine Logic App bräuchte für Mails zudem eine eigene Verbindung (Office 365 oder SMTP) mit Anmeldedaten.
- Abfrage-Alarm im Log Analytics Workspace: Das Audit-Log des Vaults enthält keine Ablaufdaten.
- Azure Policy („Secrets should have more than the specified number of days before expiration“): zeigt Compliance, meldet aber nicht.

azurerm kennt das Ziel bis Version 5 nicht. Das Abonnement entsteht deshalb per `azapi` (`Microsoft.EventGrid/systemTopics/eventSubscriptions@2025-02-15`), das System-Topic per azurerm. Das Ziel nimmt nur das CloudEvents-Schema an.

**Grenzen:**

- Es zählt die aktuelle Version. Wer einen neuen Wert ohne `--expires` setzt, bekommt keine Meldung mehr, auch wenn die alte Version ein Ablaufdatum hatte.
- Die Vorwarnung kommt fest 30 Tage vorher. Liegt das Ablaufdatum beim Setzen schon näher, ist nicht sicher, dass sie noch kommt; spätestens beim Ablauf meldet sich der zweite Alarm.
- Key Vault liefert ein abgelaufenes Secret weiter aus; das Ablaufdatum ist ein Hinweis, meist auf den Ablauf des Schlüssels beim Anbieter. Die Function läuft also weiter, bis der Anbieter den alten Schlüssel ablehnt.
- Je Vault gibt es höchstens ein System-Topic. Hat jemand im Portal unter „Ereignisse“ schon eines angelegt, scheitert der Apply; dann das vorhandene Topic löschen oder per `terraform import` übernehmen.
- Das System-Topic liegt in `location`; der Vault muss in derselben Region liegen, wie beim Modul `keyvault`.

**Testen:** Ein Secret mit Ablauf in wenigen Minuten anlegen (`az keyvault secret set --vault-name "$KV" --name expiry-test --value test --expires <in 5 Minuten, UTC>`). Nach dem Ablauf kommt der Alarm `secret-expired`. Danach `az keyvault secret delete --vault-name "$KV" --name expiry-test`.

## Nicht enthalten

- **Failure Anomalies:** Azure legt zu jeder neuen Application-Insights-Ressource selbst die Regel „Failure Anomalies“ an. Sie meldet an eine Aktionsgruppe „Application Insights Smart Detection“, die Azure in einer beliebigen Resource Group der Subscription anlegt oder wiederverwendet, und von dort an alle mit `Monitoring Contributor` oder `Monitoring Reader` auf der Subscription. Terraform verwaltet die Regel nicht; sie verschwindet mit der Resource Group.
- **Frontend-Telemetrie:** Ohne lokale Authentifizierung kann der Browser nicht direkt an Application Insights senden, weil er kein Entra-Token für die Ingestion bekommt.

## Kosten

Preise für Westeuropa, Stand Oktober 2026, ohne Gewähr:

| Posten | Kosten |
| --- | --- |
| Logic App (Health-Check) | zwei Ausführungen je Lauf (Zeitplan und Aufruf), mit dem Default unter einem Cent im Monat |
| Abfrage-Alarme (Exceptions, Tageslimit) | je rund 0,44 Euro im Monat |
| Metrik-Alarm (Health) | rund 0,09 Euro im Monat |
| System-Topic und Ereignisse (Ablauf von Secrets) | Event Grid berechnet Operationen, die ersten 100.000 im Monat sind frei; ein Vault kommt auf wenige im Jahr, also ohne Kosten |
| Alarme aus Event Grid | keine Alarmregel; Microsoft nennt dafür keinen eigenen Preis |
| Aktionsgruppe, E-Mails, Budget | ohne Kosten |

Jeder Health-Check ruft die Function auf, startet nach einer Ruhephase eine Instanz und erzeugt Telemetrie. Mit dem Default sind das 6 Aufrufe am Tag; der frühere Webtest kam auf rund 190 und kostete rund 3,50 Euro im Monat.

## Rechte

Die ausführende Identität braucht `Contributor` auf der Subscription bzw. Resource Group; das deckt Aktionsgruppe, Alarme, Logic App, System-Topic, Abonnements und Budget (`Microsoft.Consumption/budgets/write`) ab. Rollen vergibt das Modul nicht.

Die Ressourcenanbieter `Microsoft.Logic` (Health-Check) und, mit `key_vault_ids`, `Microsoft.EventGrid` müssen in der Subscription registriert sein. azurerm registriert seit Version 5 nichts mehr von selbst; das Template trägt sie deshalb in `resource_providers_to_register` des Providers ein. Ohne Template einmalig `az provider register --namespace Microsoft.Logic` bzw. `--namespace Microsoft.EventGrid`, sonst scheitert der Apply mit `MissingSubscriptionRegistration`.

Provider: azurerm und, für die Abonnements, azapi ab 2.13 (`provider "azapi" {}`).

Budgets gibt es nur für Subscriptions mit Cost Management (Pay-as-you-go, EA, Microsoft-Kundenvereinbarung). Bei Subscriptions über einen CSP-Partner kann das Anlegen scheitern; dann `budget_amount = 0` setzen.

## Eingaben

| Name | Bedeutung | Default |
| --- | --- | --- |
| `name`, `environment` | wie bei `core` | |
| `resource_group_name`, `resource_group_id`, `location`, `application_insights_id`, `log_analytics_workspace_id` | Outputs von `core` | |
| `alert_emails` | Empfänger; ohne sie und ohne `owner` das Modul weglassen | `[]` |
| `owner` | Besitzer: zusätzlicher Empfänger `owner` und Tag `owner` an allen Ressourcen ([README des Repos](../README.md#besitzer-owner)); `null` ohne | `null` |
| `exception_threshold` | Exceptions je Stunde, ab denen der Alarm kommt | `5` |
| `health_check_url` | URL für den Health-Check; `null` ohne Health-Check | `null` |
| `health_check_interval_hours` | Stunden zwischen den Läufen, 1 bis 12 | `4` |
| `budget_amount` | Monatsbudget; `0` ohne Budget | `0` |
| `key_vault_ids` | Key Vaults für den Alarm zum Ablauf von Secrets. Schlüssel frei wählbar (Kleinbuchstaben, Ziffern, Bindestriche; Teil der Namen), Wert die ID des Vaults (`key_vault_id` aus `keyvault`). Feste Schlüssel, damit der Plan sie kennt, auch wenn der Vault erst im selben Apply entsteht | `{}` |
| `tags` | zusätzliche Tags | `{}` |

Ausgabe: `action_group_id`, damit ein Projekt eigene Alarme an dieselben Empfänger schicken kann.
