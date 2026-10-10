# terraform -chdir=sso init -backend=false && terraform -chdir=sso test
# Läuft gegen einen Mock des azuread-Providers, ohne Tenant und ohne Rechte.

mock_provider "azuread" {
  mock_data "azuread_client_config" {
    defaults = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      object_id = "22222222-2222-2222-2222-222222222222"
    }
  }

  mock_resource "azuread_application" {
    defaults = {
      id        = "/applications/77777777-7777-7777-7777-777777777777"
      client_id = "33333333-3333-3333-3333-333333333333"
    }
  }
}

variables {
  name              = "example"
  environment       = "dev"
  spa_redirect_uris = ["https://app.example.org", "http://localhost:5173"]
}

run "ohne_neue_einstellungen_wie_bisher" {
  assert {
    condition = output.app_settings == {
      Auth__TenantId = "11111111-1111-1111-1111-111111111111"
      Auth__ClientId = "33333333-3333-3333-3333-333333333333"
      Auth__Audience = "api://33333333-3333-3333-3333-333333333333"
    }
    error_message = "app_settings dürfen sich ohne neue Einstellungen nicht ändern."
  }

  assert {
    condition     = keys(output.frontend_config.auth) == ["apiScope", "clientId", "tenantId"]
    error_message = "frontend_config.auth hat ohne Bridge-Seite genau die bisherigen Felder."
  }

  assert {
    condition     = azuread_application.spa[0].single_page_application[0].redirect_uris == toset(["https://app.example.org/", "http://localhost:5173/"])
    error_message = "Ohne Bridge-Seite bleiben die Redirect-URIs unverändert."
  }

  assert {
    condition     = length(azuread_application_app_role.api) == 0 && azuread_service_principal.api[0].app_role_assignment_required == false
    error_message = "Ohne app_roles keine Rollen und keine Zuweisungspflicht."
  }
}

run "rollen_bridge_und_zuweisung" {
  variables {
    app_roles = {
      Reader = { description = "Liest Rechnungen" }
      Sync   = { allowed_member_types = ["Application"] }
    }
    assignment_required      = true
    spa_redirect_bridge_path = "/redirect.html"
  }

  assert {
    condition     = azuread_application_app_role.api["Reader"].allowed_member_types == toset(["User"]) && azuread_application_app_role.api["Sync"].allowed_member_types == toset(["Application"])
    error_message = "allowed_member_types: Default User, sonst wie angegeben."
  }

  assert {
    condition     = azuread_application_app_role.api["Sync"].description == "Sync" && azuread_application_app_role.api["Reader"].display_name == "Reader"
    error_message = "Beschreibung und Anzeigename fallen auf den Rollennamen zurück."
  }

  assert {
    condition     = output.app_roles["Reader"].id == uuidv5("url", "https://github.com/blackforestsentinel/seed-terraform/sso/example-dev/roles/Reader")
    error_message = "Rollen-IDs sind stabil je Projekt, Umgebung und Rolle."
  }

  assert {
    condition = azuread_application.spa[0].single_page_application[0].redirect_uris == toset([
      "https://app.example.org/", "http://localhost:5173/",
      "https://app.example.org/redirect.html", "http://localhost:5173/redirect.html",
    ])
    error_message = "Die Bridge-Seite kommt je Origin als Redirect-URI dazu."
  }

  assert {
    condition     = output.frontend_config.auth.redirectBridgePath == "/redirect.html"
    error_message = "frontend_config nennt die Bridge-Seite."
  }

  assert {
    condition     = azuread_service_principal.api[0].app_role_assignment_required
    error_message = "assignment_required setzt die Zuweisungspflicht am Service Principal der API."
  }
}

run "vorhandene_registrierung_aus_anderem_tenant" {
  variables {
    existing_registration = {
      tenant_id     = "44444444-4444-4444-4444-444444444444"
      api_client_id = "55555555-5555-5555-5555-555555555555"
      spa_client_id = "66666666-6666-6666-6666-666666666666"
      api_scope     = "https://api.kunde.example/Billing.ReadWrite"
    }
    app_roles                = { Admin = {} }
    spa_redirect_bridge_path = "/redirect.html"
  }

  assert {
    condition     = length(azuread_application.api) + length(azuread_application.spa) + length(azuread_service_principal.api) + length(azuread_application_app_role.api) == 0
    error_message = "Mit existing_registration legt das Modul nichts an."
  }

  assert {
    condition = output.app_settings == {
      Auth__TenantId      = "44444444-4444-4444-4444-444444444444"
      Auth__ClientId      = "55555555-5555-5555-5555-555555555555"
      Auth__Audience      = "https://api.kunde.example"
      Auth__RequiredScope = "Billing.ReadWrite"
    }
    error_message = "Die API prüft gegen den anderen Tenant, die Audience und die Berechtigung der vorhandenen Registrierung."
  }

  assert {
    condition = output.frontend_config.auth == {
      clientId           = "66666666-6666-6666-6666-666666666666"
      tenantId           = "44444444-4444-4444-4444-444444444444"
      apiScope           = "https://api.kunde.example/Billing.ReadWrite"
      redirectBridgePath = "/redirect.html"
    }
    error_message = "Das Frontend meldet sich im anderen Tenant an."
  }

  assert {
    condition     = contains(output.spa_redirect_uris, "https://app.example.org/redirect.html") && output.app_roles["Admin"].allowed_member_types == tolist(["User"])
    error_message = "Redirect-URIs und Rollen stehen als Ausgabe für den Admin des anderen Tenants bereit."
  }
}

run "vorhandene_registrierung_ohne_frontend" {
  variables {
    spa_redirect_uris = []
    existing_registration = {
      tenant_id     = "44444444-4444-4444-4444-444444444444"
      api_client_id = "55555555-5555-5555-5555-555555555555"
      api_scope     = "api://55555555-5555-5555-5555-555555555555/access_as_user"
      audience      = "api://kunde-api"
    }
  }

  assert {
    condition     = output.frontend_config == {} && output.spa_client_id == null
    error_message = "Ohne Frontend kein Auth-Teil in config.json."
  }

  assert {
    condition     = output.app_settings.Auth__Audience == "api://kunde-api" && !contains(keys(output.app_settings), "Auth__RequiredScope")
    error_message = "audience überschreibt die abgeleitete Application ID URI; access_as_user braucht kein Auth__RequiredScope."
  }
}

run "ungueltige_rollen" {
  command = plan

  variables {
    app_roles = {
      "Team Lead" = { allowed_member_types = ["Service"] }
    }
  }

  expect_failures = [var.app_roles]
}
