data "azuread_client_config" "current" {}

locals {
  base = "${var.name}-${var.environment}"

  # Mit Application.ReadWrite.OwnedBy darf die Pipeline nur App-Registrierungen verwalten,
  # deren Besitzerin sie ist; deshalb steht sie immer in owners.
  owners = distinct(concat([data.azuread_client_config.current.object_id], var.additional_owners))

  # Entra ID verlangt bei URIs ohne Pfad einen abschließenden Schrägstrich
  # (https://app.example.org/); MSAL meldet sich mit genau dieser Form an.
  spa_redirect_uris = [for uri in var.spa_redirect_uris : can(regex("^https?://[^/]+$", uri)) ? "${uri}/" : uri]

  # Ohne Redirect-URIs (Projekt ohne Frontend) entsteht nur die API-Registrierung.
  spa = length(var.spa_redirect_uris) > 0

  # Stabile ID der delegierten Berechtigung, eindeutig je Projekt und Umgebung.
  scope_id = uuidv5("url", "https://github.com/blackforestsentinel/seed-terraform/sso/${local.base}/${var.scope_name}")
}

# --- API: von Browser und Custom Connector aufgerufen --------------------------

resource "azuread_application" "api" {
  display_name     = "${local.base}-api"
  sign_in_audience = "AzureADMyOrg"
  owners           = local.owners

  api {
    requested_access_token_version = 2

    oauth2_permission_scope {
      id                         = local.scope_id
      value                      = var.scope_name
      type                       = "User"
      enabled                    = true
      admin_consent_display_name = "Zugriff auf ${local.base}"
      admin_consent_description  = "Erlaubt der Anwendung, im Namen der angemeldeten Person auf die API von ${local.base} zuzugreifen."
      user_consent_display_name  = "Zugriff auf ${local.base}"
      user_consent_description   = "Erlaubt der Anwendung, in deinem Namen auf die API von ${local.base} zuzugreifen."
    }

    # Mit mcp der Scope mcp_access, nur für den MCP-Endpunkt (mcp.tf).
    dynamic "oauth2_permission_scope" {
      for_each = local.mcp_permission_scopes

      content {
        id                         = oauth2_permission_scope.value.id
        value                      = oauth2_permission_scope.key
        type                       = "User"
        enabled                    = true
        admin_consent_display_name = oauth2_permission_scope.value.admin_consent_display_name
        admin_consent_description  = oauth2_permission_scope.value.admin_consent_description
        user_consent_display_name  = oauth2_permission_scope.value.user_consent_display_name
        user_consent_description   = oauth2_permission_scope.value.user_consent_description
      }
    }
  }

  # Die Identifier-URI braucht die Client-ID und entsteht deshalb als eigene Ressource.
  lifecycle {
    ignore_changes = [identifier_uris]
  }
}

resource "azuread_application_identifier_uri" "api" {
  application_id = azuread_application.api.id
  identifier_uri = "api://${azuread_application.api.client_id}"
}

resource "azuread_service_principal" "api" {
  client_id = azuread_application.api.client_id
  owners    = local.owners
}

# --- SPA: Login im Frontend per MSAL --------------------------------------------

resource "azuread_application" "spa" {
  count = local.spa ? 1 : 0

  display_name     = "${local.base}-web"
  sign_in_audience = "AzureADMyOrg"
  owners           = local.owners

  single_page_application {
    redirect_uris = local.spa_redirect_uris
  }

  required_resource_access {
    resource_app_id = azuread_application.api.client_id

    resource_access {
      id   = local.scope_id
      type = "Scope"
    }
  }
}

resource "azuread_service_principal" "spa" {
  count = local.spa ? 1 : 0

  client_id = azuread_application.spa[0].client_id
  owners    = local.owners
}

# Das Frontend darf die API ohne Einwilligungsdialog aufrufen.
resource "azuread_application_pre_authorized" "spa" {
  count = local.spa ? 1 : 0

  application_id       = azuread_application.api.id
  authorized_client_id = azuread_application.spa[0].client_id
  permission_ids       = [local.scope_id]
}

# Bis v0.4.0 ohne count. Die Verschiebungen ändern nur den State, nicht die Registrierungen;
# die Pipeline verlangt dafür keine Freigabe.
moved {
  from = azuread_application.spa
  to   = azuread_application.spa[0]
}

moved {
  from = azuread_service_principal.spa
  to   = azuread_service_principal.spa[0]
}

moved {
  from = azuread_application_pre_authorized.spa
  to   = azuread_application_pre_authorized.spa[0]
}
