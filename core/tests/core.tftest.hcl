# terraform -chdir=core init -backend=false && terraform -chdir=core test
# Läuft gegen Mocks der Provider azurerm und azapi, ohne Subscription und ohne Rechte.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      subscription_id = "11111111-1111-1111-1111-111111111111"
      tenant_id       = "22222222-2222-2222-2222-222222222222"
      object_id       = "33333333-3333-3333-3333-333333333333"
    }
  }
}

mock_provider "azapi" {}

variables {
  name        = "example"
  environment = "dev"
}

run "ohne_owner_wie_bisher" {
  command = plan

  assert {
    condition = azurerm_resource_group.this.tags == tomap({
      "seed:project"     = "example"
      "seed:environment" = "dev"
      "seed:module"      = "core"
    })
    error_message = "Ohne owner bleiben die Tags wie bisher."
  }

  assert {
    condition     = !contains(keys(azapi_resource.function_app.tags), "owner")
    error_message = "Ohne owner kein Tag owner an der Function App."
  }
}

run "owner_an_allen_ressourcen" {
  command = plan

  variables {
    owner = "team@example.org"
  }

  assert {
    condition = alltrue([
      for tags in [
        azurerm_resource_group.this.tags,
        azurerm_log_analytics_workspace.this.tags,
        azurerm_application_insights.this.tags,
        azurerm_storage_account.host.tags,
        azurerm_user_assigned_identity.function.tags,
        azurerm_service_plan.this.tags,
        azapi_resource.function_app.tags,
        azurerm_static_web_app.this[0].tags,
      ] : tags["owner"] == "team@example.org"
    ])
    error_message = "owner steht als Tag an jeder Ressource mit Tags."
  }

  assert {
    condition     = azurerm_resource_group.this.tags["seed:module"] == "core"
    error_message = "Die Seed-Tags bleiben neben owner erhalten."
  }
}

run "owner_geht_tags_vor" {
  command = plan

  variables {
    owner = "team@example.org"
    tags  = { owner = "alt@example.org", kostenstelle = "4711" }
  }

  assert {
    condition     = azurerm_resource_group.this.tags["owner"] == "team@example.org" && azurerm_resource_group.this.tags["kostenstelle"] == "4711"
    error_message = "owner geht einem Tag owner aus tags vor, weitere Tags bleiben."
  }
}

# Azure unterscheidet bei Tag-Namen keine Groß- und Kleinschreibung, merge() schon.
run "owner_ersetzt_tag_in_anderer_schreibweise" {
  command = plan

  variables {
    owner = "team@example.org"
    tags  = { Owner = "alt@example.org", OWNER = "noch-aelter@example.org", kostenstelle = "4711" }
  }

  assert {
    condition = azurerm_resource_group.this.tags == tomap({
      "seed:project"     = "example"
      "seed:environment" = "dev"
      "seed:module"      = "core"
      owner              = "team@example.org"
      kostenstelle       = "4711"
    })
    error_message = "Mit owner fällt jeder Tag owner aus tags weg, gleich wie geschrieben."
  }
}

run "owner_leer_wie_null" {
  command = plan

  variables {
    owner = ""
    tags  = { Owner = "alt@example.org" }
  }

  assert {
    condition     = !contains(keys(azurerm_resource_group.this.tags), "owner") && azurerm_resource_group.this.tags["Owner"] == "alt@example.org"
    error_message = "Ein leerer owner wirkt wie null: kein Tag owner, tags bleiben unverändert."
  }
}

run "owner_nur_als_mail" {
  command = plan

  variables {
    owner = "Team Abrechnung"
  }

  expect_failures = [var.owner]
}

run "cors_mit_stern_abgelehnt" {
  command = plan

  variables {
    cors_allowed_origins = ["*"]
  }

  expect_failures = [var.cors_allowed_origins]
}

run "cors_mit_platzhalter_abgelehnt" {
  command = plan

  variables {
    cors_allowed_origins = ["https://www.example.org", "https://*.example.org"]
  }

  expect_failures = [var.cors_allowed_origins]
}

run "cors_einzelne_origins" {
  command = plan

  variables {
    static_web_app_sku   = "None"
    cors_allowed_origins = ["https://www.example.org", "http://localhost:5173"]
  }

  assert {
    condition     = azapi_resource.function_app.body.properties.siteConfig.cors.allowedOrigins == ["https://www.example.org", "http://localhost:5173"]
    error_message = "Einzelne Origins übernimmt das Modul unverändert."
  }

  assert {
    condition     = azapi_resource.function_app.body.properties.siteConfig.cors.supportCredentials == false
    error_message = "CORS ohne Credentials."
  }
}
