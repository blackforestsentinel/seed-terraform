locals {
  base = "${var.name}-${var.environment}"

  health_check = var.health_check_url != null

  # Fenster über mindestens zwei Läufe je Standort; bei einem einzigen Lauf im Fenster hinge
  # es vom Takt ab, ob ein Standort darin überhaupt ein Ergebnis hat.
  health_window = { 300 = "PT15M", 600 = "PT30M", 900 = "PT30M" }[var.health_check_frequency]

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

# Ein Webtest von außen statt des Health-Checks von App Service: Flex Consumption fährt auf
# null Instanzen herunter, dann gibt es nichts, was eine Instanz prüfen könnte. Ein Alarm auf
# fehlende Requests scheidet aus demselben Grund aus, eine ruhige App ist keine kaputte.
resource "azurerm_application_insights_standard_web_test" "health" {
  count = local.health_check ? 1 : 0

  name                    = "webtest-${local.base}-health"
  resource_group_name     = var.resource_group_name
  location                = var.location
  application_insights_id = var.application_insights_id
  description             = "Ruft den Health-Endpunkt ohne Token auf und erwartet 200."
  geo_locations           = var.health_check_locations
  frequency               = var.health_check_frequency
  # Nach einer Ruhephase startet der erste Aufruf eine Instanz; 30 Sekunden (Default) wären
  # dafür knapp. Mit retry_enabled zählt ein Lauf erst nach drei Fehlversuchen als Ausfall.
  timeout       = 60
  retry_enabled = true
  enabled       = true
  tags          = local.tags

  request {
    url                              = var.health_check_url
    follow_redirects_enabled         = false
    parse_dependent_requests_enabled = false
  }

  validation_rules {
    expected_status_code = 200
  }
}

resource "azurerm_monitor_metric_alert" "health" {
  count = local.health_check ? 1 : 0

  name                = "alert-${local.base}-health"
  resource_group_name = var.resource_group_name
  description         = "Der Health-Endpunkt antwortet von keinem Prüfstandort mit 200: ${var.health_check_url}"
  severity            = 1
  scopes              = [azurerm_application_insights_standard_web_test.health[0].id, var.application_insights_id]
  frequency           = "PT5M"
  window_size         = local.health_window
  auto_mitigate       = true
  tags                = local.tags

  application_insights_web_test_location_availability_criteria {
    web_test_id           = azurerm_application_insights_standard_web_test.health[0].id
    component_id          = var.application_insights_id
    failed_location_count = length(var.health_check_locations)
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
