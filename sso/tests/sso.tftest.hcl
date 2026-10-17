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
    condition     = output.spa_redirect_uris == tolist(["https://app.example.org/", "http://localhost:5173/"])
    error_message = "Die Ausgabe spa_redirect_uris bleibt ohne neue Einstellungen unverändert."
  }

  assert {
    condition     = length(azuread_application_app_role.api) == 0 && azuread_service_principal.api[0].app_role_assignment_required == false
    error_message = "Ohne app_roles keine Rollen und keine Zuweisungspflicht."
  }

  assert {
    condition     = [for r in azuread_application.spa[0].required_resource_access : r.resource_app_id] == ["33333333-3333-3333-3333-333333333333"] && output.directory_permissions == null
    error_message = "Ohne directory fordert die SPA nur die eigene API an, keine Graph-Berechtigungen."
  }
}

run "verzeichnis_an" {
  variables {
    directory = { enabled = true }
  }

  assert {
    condition = [
      for r in azuread_application.spa[0].required_resource_access : toset([for a in r.resource_access : "${a.type}:${a.id}"])
      if r.resource_app_id == "00000003-0000-0000-c000-000000000000"
      ] == [toset([
        "Scope:e1fe6dd8-ba31-4d61-89e7-88639da4683d",
        "Scope:b340eb25-3456-403f-be2f-af7a0d370277",
        "Scope:ba47897c-39ec-4d83-8086-ee8256fa737d",
    ])]
    error_message = "enabled trägt User.Read, User.ReadBasic.All und People.Read als delegierte Graph-Berechtigungen an der SPA ein."
  }

  assert {
    condition     = length(azuread_application.spa[0].required_resource_access) == 2
    error_message = "Die Berechtigung für die eigene API bleibt neben Graph bestehen."
  }

  assert {
    condition = output.frontend_config.auth.directory == {
      scopes = [
        "https://graph.microsoft.com/User.Read",
        "https://graph.microsoft.com/User.ReadBasic.All",
        "https://graph.microsoft.com/People.Read",
      ]
      presence    = false
      roleFilter  = false
      apiClientId = "33333333-3333-3333-3333-333333333333"
    }
    error_message = "frontend_config.auth.directory nennt Scopes, Schalter und die Client-ID der API."
  }

  assert {
    condition     = output.frontend_config.auth.clientId == "33333333-3333-3333-3333-333333333333" && output.frontend_config.auth.apiScope == "api://33333333-3333-3333-3333-333333333333/access_as_user"
    error_message = "Die bisherigen Felder von frontend_config.auth bleiben."
  }

  assert {
    condition     = [for p in output.directory_permissions.permissions : p.value] == ["User.Read", "User.ReadBasic.All", "People.Read"] && !output.directory_permissions.admin_consent_required
    error_message = "Ohne role_filter keine Berechtigung, die zwingend Administratorzustimmung braucht."
  }
}

run "verzeichnis_mit_presence_und_rollenfilter" {
  variables {
    directory = { enabled = true, presence = true, role_filter = true }
  }

  assert {
    condition = [
      for r in azuread_application.spa[0].required_resource_access : toset([for a in r.resource_access : a.id])
      if r.resource_app_id == "00000003-0000-0000-c000-000000000000"
      ] == [toset([
        "e1fe6dd8-ba31-4d61-89e7-88639da4683d",
        "b340eb25-3456-403f-be2f-af7a0d370277",
        "ba47897c-39ec-4d83-8086-ee8256fa737d",
        "9c7a330d-35b3-4aa1-963d-cb2b9f927841",
        "c79f8feb-a9db-4090-85f9-90d820caa0eb",
        "bc024368-1153-4739-b217-4326f2e966d0",
    ])]
    error_message = "presence bringt Presence.Read.All, role_filter Application.Read.All und GroupMember.Read.All."
  }

  assert {
    condition = output.frontend_config.auth.directory.scopes == [
      "https://graph.microsoft.com/User.Read",
      "https://graph.microsoft.com/User.ReadBasic.All",
      "https://graph.microsoft.com/People.Read",
      "https://graph.microsoft.com/Presence.Read.All",
      "https://graph.microsoft.com/Application.Read.All",
      "https://graph.microsoft.com/GroupMember.Read.All",
    ]
    error_message = "Die Scopes stehen in der vereinbarten Reihenfolge."
  }

  assert {
    condition     = output.frontend_config.auth.directory.presence && output.frontend_config.auth.directory.roleFilter
    error_message = "presence und roleFilter stehen für das Frontend in frontend_config."
  }

  assert {
    condition = output.directory_permissions.admin_consent_required && {
      for p in output.directory_permissions.permissions : p.value => p.admin_consent
      } == {
      "User.Read"            = false
      "User.ReadBasic.All"   = false
      "People.Read"          = false
      "Presence.Read.All"    = false
      "Application.Read.All" = true
      "GroupMember.Read.All" = true
    }
    error_message = "Nur die Berechtigungen für den Rollenfilter brauchen zwingend Administratorzustimmung."
  }
}

run "verzeichnis_mit_vorhandener_registrierung" {
  variables {
    existing_registration = {
      tenant_id     = "44444444-4444-4444-4444-444444444444"
      api_client_id = "55555555-5555-5555-5555-555555555555"
      spa_client_id = "66666666-6666-6666-6666-666666666666"
      api_scope     = "api://55555555-5555-5555-5555-555555555555/access_as_user"
    }
    directory = { enabled = true, presence = true }
  }

  assert {
    condition     = length(azuread_application.api) + length(azuread_application.spa) == 0
    error_message = "Mit existing_registration legt das Modul auch für directory nichts an."
  }

  assert {
    condition     = output.frontend_config.auth.directory.apiClientId == "55555555-5555-5555-5555-555555555555" && length(output.frontend_config.auth.directory.scopes) == 4
    error_message = "frontend_config bekommt directory trotzdem, apiClientId aus api_client_id."
  }

  assert {
    condition = output.directory_permissions.spa_client_id == "66666666-6666-6666-6666-666666666666" && output.directory_permissions.tenant_id == "44444444-4444-4444-4444-444444444444" && [
      for p in output.directory_permissions.permissions : p.id
    ] == ["e1fe6dd8-ba31-4d61-89e7-88639da4683d", "b340eb25-3456-403f-be2f-af7a0d370277", "ba47897c-39ec-4d83-8086-ee8256fa737d", "9c7a330d-35b3-4aa1-963d-cb2b9f927841"]
    error_message = "directory_permissions nennt dem Admin des anderen Tenants Registrierung und Berechtigungen."
  }

  assert {
    condition     = output.directory_permissions.admin_consent_command == "az ad app permission admin-consent --id 66666666-6666-6666-6666-666666666666"
    error_message = "Der Befehl für die Administratorzustimmung nennt die SPA-Registrierung."
  }
}

run "verzeichnis_ohne_frontend" {
  variables {
    spa_redirect_uris = []
    directory         = { enabled = true }
  }

  assert {
    condition     = output.frontend_config == {} && output.directory_permissions == null && length(azuread_application.spa) == 0
    error_message = "Ohne Frontend keine SPA, kein directory in config.json und keine Ausgabe."
  }
}

run "verzeichnis_aus_trotz_weiterer_schalter" {
  variables {
    directory = { enabled = false, presence = true, role_filter = true }
  }

  assert {
    condition     = length([for r in azuread_application.spa[0].required_resource_access : r if r.resource_app_id == "00000003-0000-0000-c000-000000000000"]) == 0
    error_message = "enabled = false schaltet alles ab, auch presence und role_filter (Override je Umgebung)."
  }

  assert {
    condition     = !contains(keys(output.frontend_config.auth), "directory") && output.directory_permissions == null
    error_message = "Ohne enabled kein directory in frontend_config und keine Ausgabe."
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

run "weitere_redirect_uris_ohne_bridge" {
  variables {
    spa_redirect_bridge_path = "/redirect.html"
    spa_extra_redirect_uris  = ["https://abcdefghijklmnopabcdefghijklmnop.chromiumapp.org/", "https://app.example.org/"]
  }

  assert {
    condition = azuread_application.spa[0].single_page_application[0].redirect_uris == toset([
      "https://app.example.org/", "http://localhost:5173/",
      "https://app.example.org/redirect.html", "http://localhost:5173/redirect.html",
      "https://abcdefghijklmnopabcdefghijklmnop.chromiumapp.org/",
    ])
    error_message = "Die weiteren URIs kommen ohne Bridge-Seite dazu."
  }

  assert {
    condition = output.spa_redirect_uris == tolist([
      "https://app.example.org/", "http://localhost:5173/",
      "https://app.example.org/redirect.html", "http://localhost:5173/redirect.html",
      "https://abcdefghijklmnopabcdefghijklmnop.chromiumapp.org/",
    ])
    error_message = "spa_redirect_uris nennt die weiteren URIs nach den übrigen, ohne Doppelte."
  }

  assert {
    condition     = output.frontend_config.auth.redirectBridgePath == "/redirect.html"
    error_message = "Mit Frontend nennt frontend_config die Bridge-Seite weiter."
  }
}

run "nur_weitere_redirect_uris" {
  variables {
    spa_redirect_uris        = []
    spa_redirect_bridge_path = "/redirect.html"
    spa_extra_redirect_uris  = ["https://abcdefghijklmnopabcdefghijklmnop.chromiumapp.org"]
  }

  assert {
    condition     = azuread_application.spa[0].single_page_application[0].redirect_uris == toset(["https://abcdefghijklmnopabcdefghijklmnop.chromiumapp.org/"])
    error_message = "Auch ohne Frontend entsteht die SPA-Registrierung; ohne Pfad kommt der abschließende Schrägstrich dazu."
  }

  assert {
    condition     = length(azuread_service_principal.spa) == 1 && length(azuread_application_pre_authorized.spa) == 1
    error_message = "Die SPA ist wie mit Frontend an der API vorab autorisiert."
  }

  assert {
    condition     = keys(output.frontend_config.auth) == ["apiScope", "clientId", "tenantId"] && output.frontend_config.auth.clientId == "33333333-3333-3333-3333-333333333333"
    error_message = "frontend_config.auth ohne redirectBridgePath, weil es keine Bridge-URIs gibt."
  }
}

run "weitere_redirect_uris_nur_https" {
  command = plan

  variables {
    spa_extra_redirect_uris = ["http://abcdefghijklmnopabcdefghijklmnop.chromiumapp.org/"]
  }

  expect_failures = [var.spa_extra_redirect_uris]
}

run "weitere_redirect_uris_falsche_erweiterungs_id" {
  command = plan

  variables {
    spa_extra_redirect_uris = ["https://abcdefghijklmnopabcdefghijklmnoq.chromiumapp.org/"]
  }

  expect_failures = [var.spa_extra_redirect_uris]
}

run "weitere_redirect_uris_mit_vorhandener_registrierung" {
  variables {
    existing_registration = {
      tenant_id     = "44444444-4444-4444-4444-444444444444"
      api_client_id = "55555555-5555-5555-5555-555555555555"
      spa_client_id = "66666666-6666-6666-6666-666666666666"
      api_scope     = "api://55555555-5555-5555-5555-555555555555/access_as_user"
    }
    spa_extra_redirect_uris = ["https://abcdefghijklmnopabcdefghijklmnop.chromiumapp.org/"]
  }

  assert {
    condition     = length(azuread_application.spa) == 0 && contains(output.spa_redirect_uris, "https://abcdefghijklmnopabcdefghijklmnop.chromiumapp.org/")
    error_message = "Mit existing_registration nennt spa_redirect_uris dem Admin auch die weiteren URIs."
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

run "connector_aus_wie_bisher" {
  assert {
    condition     = length(azuread_application.connector) == 0 && length(azuread_application_pre_authorized.connector) == 0 && output.connector_client_id == null
    error_message = "Ohne connector keine Client-Registrierung und keine Vorautorisierung."
  }
}

run "connector_an" {
  variables {
    connector = true
  }

  assert {
    condition     = azuread_application.connector[0].display_name == "example-dev-connector" && azuread_application.connector[0].sign_in_audience == "AzureADMyOrg"
    error_message = "Die Client-Registrierung heißt <name>-<umgebung>-connector und ist single-tenant (Voraussetzung für die Managed Identity des Connectors)."
  }

  assert {
    condition = (
      [for r in azuread_application.connector[0].required_resource_access : r.resource_app_id] == ["33333333-3333-3333-3333-333333333333"] &&
      azuread_application_pre_authorized.connector[0].permission_ids == toset([for s in azuread_application.api[0].api[0].oauth2_permission_scope : s.id if s.value == "access_as_user"])
    )
    error_message = "Der Connector fordert nur die eigene API an und ist für deren delegierte Berechtigung vorautorisiert."
  }

  assert {
    condition     = output.connector_client_id == "33333333-3333-3333-3333-333333333333"
    error_message = "connector_client_id nennt die Client-ID der Registrierung."
  }

  assert {
    condition     = output.app_settings == run.ohne_neue_einstellungen_wie_bisher.app_settings
    error_message = "connector ändert die App-Settings der Function nicht."
  }
}

run "connector_mit_vorhandener_registrierung" {
  command = plan

  variables {
    connector = true
    existing_registration = {
      tenant_id     = "44444444-4444-4444-4444-444444444444"
      api_client_id = "55555555-5555-5555-5555-555555555555"
      api_scope     = "api://55555555-5555-5555-5555-555555555555/access_as_user"
    }
  }

  assert {
    condition     = length(azuread_application.connector) == 0 && output.connector_client_id == null
    error_message = "Mit existing_registration legt das Modul keinen Connector-Client an."
  }

  expect_failures = [check.connector_existing_registration]
}
