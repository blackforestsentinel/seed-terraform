locals {
  base = "${var.name}-${var.environment}"

  health_check = var.health_check_url != null

  # Das Fenster des Alarms ist länger als der Abstand der Läufe. Scheitern zwei Läufe
  # nacheinander, liegen beide im Fenster, und der Alarm bleibt bestehen; bei einem kürzeren
  # Fenster käme zwischen zwei Läufen eine Entwarnung, obwohl die App noch nicht antwortet.
  health_window = (
    var.health_check_interval_hours < 6 ? "PT6H" :
    var.health_check_interval_hours < 12 ? "PT12H" : "P1D"
  )

  tags = merge(
    {
      "seed:project"     = var.name
      "seed:environment" = var.environment
      "seed:module"      = "monitoring"
    },
    var.tags,
  )
}

# Alle Meldungen laufen über diese Gruppe; die Empfänger stehen nur hier.
resource "azurerm_monitor_action_group" "this" {
  name                = "ag-${local.base}"
  resource_group_name = var.resource_group_name
  # Höchstens 12 Zeichen, steht im Betreff jeder Meldung.
  short_name = substr(var.name, 0, 12)
  tags       = local.tags

  dynamic "email_receiver" {
    for_each = var.alert_emails

    content {
      name          = "mail-${email_receiver.key}"
      email_address = email_receiver.value
      # Mit Resource Group und Ressource im Inhalt, daran erkennt man Projekt und Umgebung.
      use_common_alert_schema = true
    }
  }
}

# --- Exceptions -----------------------------------------------------------------

# Alle Abfragen enden in einem einzigen Zählwert. Die Meldung verlässt Azure per Mail;
# Nachrichten und Details der Exceptions können Mandantendaten enthalten und bleiben
# deshalb in Application Insights.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "exceptions" {
  name                = "alert-${local.base}-exceptions"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.tags

  display_name = "${local.base}: Exceptions häufen sich"
  description  = "In der letzten Stunde gab es mindestens ${var.exception_threshold} Exceptions. Details unter Application Insights, Failures bzw. Tabelle exceptions."
  severity     = 2

  scopes               = [var.application_insights_id]
  evaluation_frequency = "PT15M"
  window_duration      = "PT1H"
  # Eine Mail je Vorfall statt alle 15 Minuten; löst sich auf, sobald die Stunde ruhig ist.
  auto_mitigation_enabled = true

  criteria {
    # Zu jeder unbehandelten Exception im Worker schreibt die Plattform neben dessen Eintrag
    # zwei weitere ohne SDK-Version und Vorgang. Ohne den Filter zählte sie dreifach.
    query                   = <<-QUERY
      exceptions
      | where isnotempty(sdkVersion)
      | summarize Anzahl = count()
    QUERY
    time_aggregation_method = "Total"
    metric_measure_column   = "Anzahl"
    operator                = "GreaterThanOrEqual"
    threshold               = var.exception_threshold
  }

  action {
    action_groups = [azurerm_monitor_action_group.this.id]
  }
}

# --- Health-Check ---------------------------------------------------------------

# Ein Aufruf von außen statt des Health-Checks von App Service: Flex Consumption fährt auf
# null Instanzen herunter, dann gibt es nichts, was eine Instanz prüfen könnte. Ein Alarm auf
# fehlende Requests scheidet aus demselben Grund aus, eine ruhige App ist keine kaputte.
#
# Eine Logic App statt eines Webtests von Application Insights: Webtests laufen höchstens alle
# 15 Minuten. Jeder Aufruf startet nach einer Ruhephase eine Instanz, zehrt am Freikontingent
# der Function und schreibt die Startmeldungen des Hosts in die Logs.
resource "azurerm_logic_app_workflow" "health" {
  count = local.health_check ? 1 : 0

  name                = "logic-${local.base}-health"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.tags
}

# Ohne Startzeit läuft der erste Durchgang gleich nach dem Anlegen.
resource "azurerm_logic_app_trigger_recurrence" "health" {
  count = local.health_check ? 1 : 0

  name         = "zeitplan"
  logic_app_id = azurerm_logic_app_workflow.health[0].id
  frequency    = "Hour"
  interval     = var.health_check_interval_hours
}

# Ohne Token. Antwortet der Endpunkt nicht mit 2xx, scheitert der Lauf. Die Standard-Wiederholung
# der Logic App (bei Zeitüberschreitung, 408, 429 und 5xx bis zu vier Wiederholungen in wachsendem
# Abstand, Timeout je Versuch zwei Minuten) überbrückt den Kaltstart und kurze Störungen.
resource "azurerm_logic_app_action_http" "health" {
  count = local.health_check ? 1 : 0

  name         = "health"
  logic_app_id = azurerm_logic_app_workflow.health[0].id
  method       = "GET"
  uri          = var.health_check_url
}

# Bis v0.12.0 hieß der Alarm alert-…-health und hing am Webtest. Azure wandelt einen solchen
# Alarm nicht in einen Metrik-Alarm um; der neue Name lässt Terraform ihn ersetzen.
resource "azurerm_monitor_metric_alert" "health" {
  count = local.health_check ? 1 : 0

  name                = "alert-${local.base}-health-check"
  resource_group_name = var.resource_group_name
  description         = "Der Health-Endpunkt hat auch nach mehreren Versuchen nicht erfolgreich geantwortet: ${var.health_check_url}. Details im Ausführungsverlauf der Logic App logic-${local.base}-health."
  severity            = 1
  scopes              = [azurerm_logic_app_workflow.health[0].id]
  frequency           = "PT15M"
  window_size         = local.health_window
  auto_mitigate       = true
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.Logic/workflows"
    metric_name      = "RunsFailed"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = azurerm_monitor_action_group.this.id
  }
}

# --- Tageslimit ------------------------------------------------------------------

# Ist das Tageslimit erreicht (core: log_daily_quota_gb), kommt bis 0 Uhr UTC keine Telemetrie
# mehr an, und alle Alarme hier bleiben still. Diese Meldung schreibt Azure trotzdem.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "daily_cap" {
  name                = "alert-${local.base}-daily-cap"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.tags

  display_name = "${local.base}: Tageslimit für Logs erreicht"
  description  = "Der Log Analytics Workspace hat sein Tageslimit erreicht und nimmt bis 0 Uhr UTC keine Telemetrie mehr an. Bis dahin melden auch die übrigen Alarme nichts. Ursache suchen (Usage and estimated costs) oder das Limit anheben."
  severity     = 2

  scopes                  = [var.log_analytics_workspace_id]
  evaluation_frequency    = "PT15M"
  window_duration         = "PT1H"
  auto_mitigation_enabled = true

  criteria {
    query                   = <<-QUERY
      _LogOperation
      | where Category =~ "Ingestion" and Detail has "OverQuota"
      | summarize Anzahl = count()
    QUERY
    time_aggregation_method = "Total"
    metric_measure_column   = "Anzahl"
    operator                = "GreaterThan"
    threshold               = 0
  }

  action {
    action_groups = [azurerm_monitor_action_group.this.id]
  }
}

# --- Budget ---------------------------------------------------------------------

# Für alle Kosten der Resource Group, also das ganze Projekt in dieser Umgebung. Azure
# rechnet Kosten etwa einmal am Tag ab; die Prognose warnt, bevor der Betrag erreicht ist.
resource "azurerm_consumption_budget_resource_group" "this" {
  count = var.budget_amount > 0 ? 1 : 0

  name              = "budget-${local.base}"
  resource_group_id = var.resource_group_id
  amount            = var.budget_amount
  time_grain        = "Monthly"

  time_period {
    # Azure verlangt den Ersten eines Monats und lehnt Starttermine zu weit in der
    # Vergangenheit ab, ein festes Datum veraltete also. ignore_changes hält den Wert vom
    # Anlegen fest, sonst änderte sich der Plan jeden Monat.
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
  }

  notification {
    threshold      = 80
    threshold_type = "Actual"
    operator       = "GreaterThanOrEqualTo"
    contact_groups = [azurerm_monitor_action_group.this.id]
  }

  notification {
    threshold      = 100
    threshold_type = "Forecasted"
    operator       = "GreaterThanOrEqualTo"
    contact_groups = [azurerm_monitor_action_group.this.id]
  }

  lifecycle {
    ignore_changes = [time_period]
  }
}
