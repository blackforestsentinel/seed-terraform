# terraform -chdir=monitoring init -backend=false && terraform -chdir=monitoring test
# Läuft gegen einen Mock des azurerm-Providers, ohne Subscription und ohne Rechte.

mock_provider "azurerm" {
  # Der Provider prüft Ressourcen-IDs auch gegen den Mock; deshalb echte Formen.
  mock_resource "azurerm_monitor_action_group" {
    defaults = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-example-dev/providers/Microsoft.Insights/actionGroups/ag-example-dev"
    }
  }

  mock_resource "azurerm_logic_app_workflow" {
    defaults = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-example-dev/providers/Microsoft.Logic/workflows/logic-example-dev-health"
    }
  }
}

variables {
  name                       = "example"
  environment                = "dev"
  resource_group_name        = "rg-example-dev"
  resource_group_id          = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-example-dev"
  location                   = "westeurope"
  application_insights_id    = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-example-dev/providers/Microsoft.Insights/components/appi-example-dev"
  log_analytics_workspace_id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-example-dev/providers/Microsoft.OperationalInsights/workspaces/log-example-dev"
  alert_emails               = ["betrieb@example.org"]
  health_check_url           = "https://func-example-dev.azurewebsites.net/api/health"
}

run "default_alle_4_stunden" {
  command = plan

  assert {
    condition     = azurerm_logic_app_trigger_recurrence.health[0].frequency == "Hour" && azurerm_logic_app_trigger_recurrence.health[0].interval == 4
    error_message = "Der Health-Check soll per Default alle 4 Stunden laufen."
  }

  assert {
    condition     = azurerm_logic_app_action_http.health[0].uri == var.health_check_url && azurerm_logic_app_action_http.health[0].method == "GET"
    error_message = "Die Logic App soll die health_check_url per GET aufrufen."
  }

  assert {
    condition     = azurerm_monitor_metric_alert.health[0].window_size == "PT6H"
    error_message = "Bei 4 Stunden soll das Fenster 6 Stunden umfassen, länger als der Abstand der Läufe."
  }
}

run "fenster_laenger_als_der_abstand" {
  command = plan

  variables {
    health_check_interval_hours = 6
  }

  assert {
    condition     = azurerm_monitor_metric_alert.health[0].window_size == "PT12H"
    error_message = "Bei 6 Stunden soll das Fenster 12 Stunden umfassen."
  }
}

run "zwoelf_stunden" {
  command = plan

  variables {
    health_check_interval_hours = 12
  }

  assert {
    condition     = azurerm_monitor_metric_alert.health[0].window_size == "P1D"
    error_message = "Bei 12 Stunden soll das Fenster 24 Stunden umfassen."
  }
}

run "ohne_url_kein_health_check" {
  command = plan

  variables {
    health_check_url = null
  }

  assert {
    condition     = length(azurerm_logic_app_workflow.health) == 0 && length(azurerm_monitor_metric_alert.health) == 0
    error_message = "Ohne health_check_url soll weder Logic App noch Health-Alarm entstehen."
  }
}

run "abstand_ueber_zwoelf_stunden_abgelehnt" {
  command = plan

  variables {
    health_check_interval_hours = 24
  }

  expect_failures = [var.health_check_interval_hours]
}

run "halbe_stunden_abgelehnt" {
  command = plan

  variables {
    health_check_interval_hours = 1.5
  }

  expect_failures = [var.health_check_interval_hours]
}
