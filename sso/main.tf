data "azuread_client_config" "current" {}

locals {
  base = "${var.name}-${var.environment}"

  # Mit Application.ReadWrite.OwnedBy darf die Pipeline nur App-Registrierungen verwalten,
  # deren Besitzerin sie ist; deshalb steht sie immer in owners.
  owners = distinct(concat([data.azuread_client_config.current.object_id], var.additional_owners))

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
  display_name     = "${local.base}-web"
  sign_in_audience = "AzureADMyOrg"
  owners           = local.owners

  single_page_application {
    redirect_uris = var.spa_redirect_uris
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
  client_id = azuread_application.spa.client_id
  owners    = local.owners
}

# Das Frontend darf die API ohne Einwilligungsdialog aufrufen.
resource "azuread_application_pre_authorized" "spa" {
  application_id       = azuread_application.api.id
  authorized_client_id = azuread_application.spa.client_id
  permission_ids       = [local.scope_id]
}
