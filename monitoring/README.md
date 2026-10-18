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
| Logic App `logic-…-health` und Alarm `alert-…-health-check` | Die Logic App ruft `health_check_url` alle `health_check_interval_hours` Stunden (Default 4) ohne Token auf. Bei Zeitüberschreitung, 408, 429 und 5xx wiederholt sie den Aufruf viermal; antwortet der Endpunkt auch dann nicht mit 2xx, scheitert der Lauf. Der Alarm prüft alle 15 Minuten, ob ein Lauf gescheitert ist. Schweregrad 1. Entfällt mit `health_check_url = null`. |
| Alarm `alert-…-daily-cap` | Meldet, wenn der Log Analytics Workspace sein Tageslimit (`core`: `log_daily_quota_gb`) erreicht hat. Bis 0 Uhr UTC kommt dann keine Telemetrie mehr an, und die übrigen Alarme bleiben still. Schweregrad 2. |
| Budget `budget-<projekt>-<umgebung>` | Monatsbudget der ganzen Resource Group in der Abrechnungswährung. Warnung bei 80 % der tatsächlichen Kosten und wenn die Prognose 100 % übersteigt. Entfällt mit `budget_amount = 0`. |

Alle Alarme lösen sich selbst auf, sobald die Bedingung nicht mehr zutrifft; je Vorfall kommt also eine Mail und eine Entwarnung. Beim Health-Check kommt die Entwarnung erst, wenn der letzte gescheiterte Lauf aus dem Fenster des Alarms fällt, mit dem Default 6 Stunden nach diesem Lauf.

## Entscheidungen

**Nur Zählwerte in den Meldungen.** Die Abfragen enden in einem einzigen `summarize count()`. Eine Alarm-Mail verlässt Azure; Nachrichten und Details von Exceptions können Mandantendaten enthalten und bleiben deshalb in Application Insights, hinter dessen Zugriffsschutz. Wer eigene Alarme ergänzt, hält es genauso.

**Health-Check von außen.** Flex Consumption fährt ohne Last auf null Instanzen herunter. Den Health-Check von App Service (`healthCheckPath`) gibt es dort nicht, und ein Alarm auf fehlende Requests oder Lebenszeichen würde bei jeder ruhigen App anschlagen. Ein Aufruf von außen prüft, ob die App antwortet, und startet sie dafür notfalls. Der Endpunkt muss ohne Token erfolgreich antworten; im Template ist das `/api/health` (`[AllowAnonymous]`).

**Alle 4 Stunden, per Logic App.** Jeder Aufruf nach einer Ruhephase startet eine Instanz, zählt gegen das Freikontingent der Function und schreibt die Startmeldungen des Hosts in die Logs. Bis v0.12.0 rief ein Webtest von Application Insights alle 15 Minuten aus zwei Standorten auf, rund 190 Mal am Tag; die Startmeldungen machten in einem migrierten Projekt einen großen Teil der Logs aus. Webtests laufen höchstens alle 15 Minuten, deshalb übernimmt eine Logic App mit Zeitplan. Ein Ausfall fällt so spätestens nach 4 Stunden und 15 Minuten auf; wer es früher wissen muss, setzt `health_check_interval_hours` kleiner.

**Ein Standort, dafür Wiederholungen.** Die Logic App ruft aus der Region des Projekts auf. Kurze Störungen und den Kaltstart überbrückt die Standard-Wiederholung (bis zu vier Wiederholungen, je Versuch bis zu zwei Minuten Timeout). Das Fenster des Alarms ist länger als der Abstand der Läufe: Scheitern zwei Läufe nacheinander, bleibt der Alarm bestehen, statt zwischendurch Entwarnung zu geben.

**Jede Exception zählt einmal.** Zu einer unbehandelten Exception in einer Function schreibt die Plattform neben dem Eintrag des Workers zwei weitere ohne SDK-Version und Vorgang. Die Abfrage lässt diese weg (`isnotempty(sdkVersion)`), sonst lösten schon zwei fehlgeschlagene Aufrufe den Alarm bei 5 aus.

**Exceptions statt fehlgeschlagener Requests.** Exceptions erfassen auch Fehler außerhalb von HTTP (Timer, Queues) und geloggte Fehler (`LogError` mit Exception). Ein Alarm auf fehlgeschlagene Requests würde nur HTTP sehen.

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
| Aktionsgruppe, E-Mails, Budget | ohne Kosten |

Jeder Health-Check ruft die Function auf, startet nach einer Ruhephase eine Instanz und erzeugt Telemetrie. Mit dem Default sind das 6 Aufrufe am Tag; der frühere Webtest kam auf rund 190 und kostete rund 3,50 Euro im Monat.

## Rechte

Die ausführende Identität braucht `Contributor` auf der Subscription bzw. Resource Group; das deckt Aktionsgruppe, Alarme, Logic App und Budget (`Microsoft.Consumption/budgets/write`) ab. Rollen vergibt das Modul nicht.

Der Ressourcenanbieter `Microsoft.Logic` muss in der Subscription registriert sein. azurerm registriert seit Version 5 nichts mehr von selbst; das Template trägt ihn deshalb in `resource_providers_to_register` des Providers ein. Ohne Template einmalig `az provider register --namespace Microsoft.Logic`, sonst scheitert der Apply mit `MissingSubscriptionRegistration`.

Budgets gibt es nur für Subscriptions mit Cost Management (Pay-as-you-go, EA, Microsoft-Kundenvereinbarung). Bei Subscriptions über einen CSP-Partner kann das Anlegen scheitern; dann `budget_amount = 0` setzen.

## Eingaben

| Name | Bedeutung | Default |
| --- | --- | --- |
| `name`, `environment` | wie bei `core` | |
| `resource_group_name`, `resource_group_id`, `location`, `application_insights_id`, `log_analytics_workspace_id` | Outputs von `core` | |
| `alert_emails` | Empfänger, mindestens einer | |
| `exception_threshold` | Exceptions je Stunde, ab denen der Alarm kommt | `5` |
| `health_check_url` | URL für den Health-Check; `null` ohne Health-Check | `null` |
| `health_check_interval_hours` | Stunden zwischen den Läufen, 1 bis 12 | `4` |
| `budget_amount` | Monatsbudget; `0` ohne Budget | `0` |
| `tags` | zusätzliche Tags | `{}` |

Ausgabe: `action_group_id`, damit ein Projekt eigene Alarme an dieselben Empfänger schicken kann.
