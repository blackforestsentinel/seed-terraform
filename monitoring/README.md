# monitoring

Alarme und Budget für ein Seed-Projekt, je Umgebung. Das Modul baut auf `core` auf und wird nur eingebunden, wenn es Empfänger gibt; ohne Empfänger gibt es keine Alarme und kein Budget.

```hcl
module "monitoring" {
  source = "git::https://github.com/blackforestsentinel/seed-terraform.git//monitoring?ref=<version>"
  count  = length(local.alert_emails) > 0 ? 1 : 0

  name                       = local.cfg.project
  environment                = var.environment
  resource_group_name        = module.core.resource_group_name
  resource_group_id          = module.core.resource_group_id
  location                   = module.core.location
  application_insights_id    = module.core.application_insights_id
  log_analytics_workspace_id = module.core.log_analytics_workspace_id
  alert_emails               = local.alert_emails
  health_check_url           = "${module.core.function_app_url}/api/health"
  exception_threshold        = 5
  budget_amount              = 20
}
```

Im Template steuert der Abschnitt `monitoring:` in `project.yaml` die Eingaben.

## Was entsteht

| Ressource | Inhalt |
| --- | --- |
| Aktionsgruppe `ag-<projekt>-<umgebung>` | Eine E-Mail je Empfänger im gemeinsamen Alarmschema. Alle Alarme und das Budget melden über diese Gruppe. Azure schickt jeder neuen Adresse einmal eine Mail, dass sie hinzugefügt wurde. |
| Alarm `alert-…-exceptions` | Abfrage auf Application Insights alle 15 Minuten über die letzte Stunde; meldet, sobald es `exception_threshold` (Default 5) Exceptions gab. Jede Exception zählt einmal, ob unbehandelt oder per `LogError` geloggt. Schweregrad 2. |
| Webtest `webtest-…-health` und Alarm `alert-…-health` | Standard-Webtest auf `health_check_url` (ohne Token, erwartet 200, 60 Sekunden Timeout, Wiederholung bei Fehlschlag) aus zwei EU-Standorten. Der Alarm kommt, wenn alle Standorte ausfallen. Schweregrad 1. Entfällt mit `health_check_url = null`. |
| Alarm `alert-…-daily-cap` | Meldet, wenn der Log Analytics Workspace sein Tageslimit (`core`: `log_daily_quota_gb`) erreicht hat. Bis 0 Uhr UTC kommt dann keine Telemetrie mehr an, und die übrigen Alarme bleiben still. Schweregrad 2. |
| Budget `budget-<projekt>-<umgebung>` | Monatsbudget der ganzen Resource Group in der Abrechnungswährung. Warnung bei 80 % der tatsächlichen Kosten und wenn die Prognose 100 % übersteigt. Entfällt mit `budget_amount = 0`. |

Alle Alarme lösen sich selbst auf, sobald die Bedingung nicht mehr zutrifft; je Vorfall kommt also eine Mail und eine Entwarnung.

## Entscheidungen

**Nur Zählwerte in den Meldungen.** Die Abfragen enden in einem einzigen `summarize count()`. Eine Alarm-Mail verlässt Azure; Nachrichten und Details von Exceptions können Mandantendaten enthalten und bleiben deshalb in Application Insights, hinter dessen Zugriffsschutz. Wer eigene Alarme ergänzt, hält es genauso.

**Health-Check als Webtest.** Flex Consumption fährt ohne Last auf null Instanzen herunter. Den Health-Check von App Service (`healthCheckPath`) gibt es dort nicht, und ein Alarm auf fehlende Requests oder Lebenszeichen würde bei jeder ruhigen App anschlagen. Ein Standard-Webtest prüft von außen, ob die App antwortet, und startet sie dafür notfalls. Der Endpunkt muss ohne Token mit 200 antworten; im Template ist das `/api/health` (`[AllowAnonymous]`). Klassische URL-Ping-Tests hat Microsoft abgekündigt.

**Zwei Standorte, beide müssen ausfallen.** Eine Netzstörung an einem Standort ist kein Ausfall der App. Das Fenster des Alarms umfasst mindestens zwei Läufe je Standort.

**Jede Exception zählt einmal.** Zu einer unbehandelten Exception in einer Function schreibt die Plattform neben dem Eintrag des Workers zwei weitere ohne SDK-Version und Vorgang. Die Abfrage lässt diese weg (`isnotempty(sdkVersion)`), sonst lösten schon zwei fehlgeschlagene Aufrufe den Alarm bei 5 aus.

**Exceptions statt fehlgeschlagener Requests.** Exceptions erfassen auch Fehler außerhalb von HTTP (Timer, Queues) und geloggte Fehler (`LogError` mit Exception). Ein Alarm auf fehlgeschlagene Requests würde nur HTTP sehen.

## Nicht enthalten

- **Failure Anomalies:** Azure legt zu jeder neuen Application-Insights-Ressource selbst die Regel „Failure Anomalies“ an. Sie meldet an eine Aktionsgruppe „Application Insights Smart Detection“, die Azure in einer beliebigen Resource Group der Subscription anlegt oder wiederverwendet, und von dort an alle mit `Monitoring Contributor` oder `Monitoring Reader` auf der Subscription. Terraform verwaltet die Regel nicht; sie verschwindet mit der Resource Group.
- **Frontend-Telemetrie:** Ohne lokale Authentifizierung kann der Browser nicht direkt an Application Insights senden, weil er kein Entra-Token für die Ingestion bekommt.

## Kosten

Preise für Westeuropa, Stand Oktober 2026, ohne Gewähr:

| Posten | Kosten |
| --- | --- |
| Webtest | rund 0,0006 Euro je Lauf und Standort; mit dem Default (alle 15 Minuten, 2 Standorte) rund 3,50 Euro im Monat, mit `health_check_frequency = 300` rund 10,40 Euro |
| Abfrage-Alarme (Exceptions, Tageslimit) | je rund 0,44 Euro im Monat |
| Metrik-Alarm (Health) | rund 0,09 Euro im Monat |
| Aktionsgruppe, E-Mails, Budget | ohne Kosten |

Jeder Webtest-Lauf ruft die Function auf und erzeugt etwas Telemetrie.

## Rechte

Die ausführende Identität braucht `Contributor` auf der Subscription bzw. Resource Group; das deckt Aktionsgruppe, Alarme, Webtest und Budget (`Microsoft.Consumption/budgets/write`) ab. Rollen vergibt das Modul nicht.

Budgets gibt es nur für Subscriptions mit Cost Management (Pay-as-you-go, EA, Microsoft-Kundenvereinbarung). Bei Subscriptions über einen CSP-Partner kann das Anlegen scheitern; dann `budget_amount = 0` setzen.

## Eingaben

| Name | Bedeutung | Default |
| --- | --- | --- |
| `name`, `environment` | wie bei `core` | |
| `resource_group_name`, `resource_group_id`, `location`, `application_insights_id`, `log_analytics_workspace_id` | Outputs von `core` | |
| `alert_emails` | Empfänger, mindestens einer | |
| `exception_threshold` | Exceptions je Stunde, ab denen der Alarm kommt | `5` |
| `health_check_url` | URL für den Webtest; `null` ohne Webtest | `null` |
| `health_check_frequency` | Sekunden zwischen den Läufen: 300, 600 oder 900 | `900` |
| `health_check_locations` | Standorte des Webtests | Amsterdam und Dublin |
| `budget_amount` | Monatsbudget; `0` ohne Budget | `0` |
| `tags` | zusätzliche Tags | `{}` |

Ausgabe: `action_group_id`, damit ein Projekt eigene Alarme an dieselben Empfänger schicken kann.
