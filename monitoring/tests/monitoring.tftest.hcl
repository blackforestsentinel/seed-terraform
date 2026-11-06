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

  mock_resource "azurerm_eventgrid_system_topic" {
    defaults = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-example-dev/providers/Microsoft.EventGrid/systemTopics/egst-example-dev-keyvault"
    }
  }
}

# Abonnements für den Alarm zum Ablauf von Secrets (Event Grid an Azure Monitor).
mock_provider "azapi" {}

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

run "ohne_owner_wie_bisher" {
  command = plan

  assert {
    condition     = [for r in azurerm_monitor_action_group.this.email_receiver : [r.name, r.email_address]] == [["mail-0", "betrieb@example.org"]]
    error_message = "Ohne owner bleiben die Empfänger der Aktionsgruppe wie bisher."
  }

  assert {
    condition     = !contains(keys(azurerm_monitor_action_group.this.tags), "owner")
    error_message = "Ohne owner kein Tag owner."
  }
}

run "owner_als_empfaenger_und_tag" {
  command = plan

  variables {
    alert_emails = ["betrieb@example.org", "bereitschaft@example.org"]
    owner        = "team@example.org"
  }

  assert {
    condition = [for r in azurerm_monitor_action_group.this.email_receiver : [r.name, r.email_address]] == [
      ["mail-0", "betrieb@example.org"],
      ["mail-1", "bereitschaft@example.org"],
      ["owner", "team@example.org"],
    ]
    error_message = "owner kommt als eigener Empfänger ans Ende; die bisherigen behalten ihre Namen."
  }

  assert {
    condition = alltrue([
      for tags in [
        azurerm_monitor_action_group.this.tags,
        azurerm_monitor_scheduled_query_rules_alert_v2.exceptions.tags,
        azurerm_monitor_scheduled_query_rules_alert_v2.daily_cap.tags,
        azurerm_logic_app_workflow.health[0].tags,
        azurerm_monitor_metric_alert.health[0].tags,
      ] : tags["owner"] == "team@example.org"
    ])
    error_message = "owner steht als Tag an jeder Ressource mit Tags."
  }
}

run "owner_schon_unter_den_empfaengern" {
  command = plan

  variables {
    alert_emails = ["Team@Example.org"]
    owner        = "team@example.org"
  }

  assert {
    condition     = [for r in azurerm_monitor_action_group.this.email_receiver : r.email_address] == ["Team@Example.org"]
    error_message = "Steht owner schon unter alert_emails, auch anders geschrieben, kommt er nicht doppelt dazu."
  }
}

run "nur_owner" {
  command = plan

  variables {
    alert_emails = []
    owner        = "team@example.org"
  }

  assert {
    condition     = [for r in azurerm_monitor_action_group.this.email_receiver : [r.name, r.email_address]] == [["owner", "team@example.org"]]
    error_message = "Ohne weitere Empfänger meldet die Aktionsgruppe an owner."
  }
}

run "owner_leer_wie_null" {
  command = plan

  variables {
    owner = ""
    tags  = { Owner = "alt@example.org" }
  }

  assert {
    condition     = [for r in azurerm_monitor_action_group.this.email_receiver : r.name] == ["mail-0"] && !contains(keys(azurerm_monitor_action_group.this.tags), "owner")
    error_message = "Ein leerer owner wirkt wie null: kein Empfänger, kein Tag."
  }
}

run "owner_ersetzt_tag_in_anderer_schreibweise" {
  command = plan

  variables {
    owner = "team@example.org"
    tags  = { Owner = "alt@example.org" }
  }

  assert {
    condition     = azurerm_monitor_action_group.this.tags["owner"] == "team@example.org" && !contains(keys(azurerm_monitor_action_group.this.tags), "Owner")
    error_message = "owner ersetzt einen Tag Owner aus tags."
  }
}

run "owner_nur_als_mail" {
  command = plan

  variables {
    owner = "Team Betrieb"
  }

  expect_failures = [var.owner]
}

run "ohne_key_vault_kein_secret_alarm" {
  command = plan

  assert {
    condition     = length(azurerm_eventgrid_system_topic.key_vault) == 0 && length(azapi_resource.secret_expiry) == 0
    error_message = "Ohne key_vault_ids weder System-Topic noch Abonnement."
  }
}

run "secret_ablauf_im_plan" {
  command = plan

  variables {
    key_vault_ids = { keyvault = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-example-dev/providers/Microsoft.KeyVault/vaults/kv-example-dev-abc123" }
  }

  assert {
    condition = alltrue([
      azurerm_eventgrid_system_topic.key_vault["keyvault"].name == "egst-example-dev-keyvault",
      azurerm_eventgrid_system_topic.key_vault["keyvault"].topic_type == "Microsoft.KeyVault.vaults",
      azurerm_eventgrid_system_topic.key_vault["keyvault"].source_resource_id == var.key_vault_ids["keyvault"],
      azurerm_eventgrid_system_topic.key_vault["keyvault"].location == "westeurope",
    ])
    error_message = "Je Vault ein System-Topic vom Typ Microsoft.KeyVault.vaults in der Region des Projekts."
  }

  assert {
    condition     = keys(azapi_resource.secret_expiry) == ["keyvault/secret-expired", "keyvault/secret-near-expiry"]
    error_message = "Je Vault ein Abonnement für die Vorwarnung und eins für den Ablauf."
  }
}

run "secret_ablauf_an_die_aktionsgruppe" {
  variables {
    owner         = "team@example.org"
    key_vault_ids = { keyvault = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-example-dev/providers/Microsoft.KeyVault/vaults/kv-example-dev-abc123" }
  }

  assert {
    condition = alltrue([
      for key, event in {
        "keyvault/secret-near-expiry" = ["Microsoft.KeyVault.SecretNearExpiry", "Sev2"]
        "keyvault/secret-expired"     = ["Microsoft.KeyVault.SecretExpired", "Sev1"]
      } :
      azapi_resource.secret_expiry[key].body.properties.filter.includedEventTypes == [event[0]] &&
      azapi_resource.secret_expiry[key].body.properties.destination.properties.severity == event[1]
    ])
    error_message = "Vorwarnung mit Schweregrad 2, Ablauf mit Schweregrad 1, je nur das eine Ereignis."
  }

  assert {
    condition = alltrue([
      for s in azapi_resource.secret_expiry :
      s.body.properties.destination.endpointType == "MonitorAlert" &&
      s.body.properties.eventDeliverySchema == "CloudEventSchemaV1_0" &&
      s.body.properties.destination.properties.actionGroups == [azurerm_monitor_action_group.this.id] &&
      s.parent_id == azurerm_eventgrid_system_topic.key_vault["keyvault"].id &&
      s.locks == tolist([azurerm_eventgrid_system_topic.key_vault["keyvault"].id]) &&
      s.type == "Microsoft.EventGrid/systemTopics/eventSubscriptions@2025-02-15"
    ])
    error_message = "Event Grid meldet als Alarm in Azure Monitor an die Aktionsgruppe, im CloudEvents-Schema; die Abonnements eines Topics entstehen nacheinander."
  }

  assert {
    condition     = azurerm_eventgrid_system_topic.key_vault["keyvault"].tags["owner"] == "team@example.org"
    error_message = "Auch das System-Topic trägt owner als Tag."
  }
}

run "key_vault_ids_name_ungueltig" {
  command = plan

  variables {
    key_vault_ids = { "Key Vault" = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-example-dev/providers/Microsoft.KeyVault/vaults/kv-example-dev-abc123" }
  }

  expect_failures = [var.key_vault_ids]
}

run "key_vault_ids_keine_vault_id" {
  command = plan

  variables {
    key_vault_ids = { keyvault = "kv-example-dev-abc123" }
  }

  expect_failures = [var.key_vault_ids]
}
