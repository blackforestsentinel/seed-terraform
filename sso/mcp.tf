# MCP-Server (Bfs.Seed.Mcp): eigener Scope mcp_access an der API, eine öffentliche
# Client-Registrierung für MCP-Clients ohne eigene Entra-Registrierung (Claude, Claude Code)
# und optional die MCP-Adresse auf einer eigenen Domain als Application ID URI.
#
# Entra ist der Autorisierungsserver. Dynamische Client-Registrierung kennt Entra nicht; deshalb
# legt das Modul je Projekt und Umgebung eine Registrierung an, deren Client-ID man einmal im
# Client einträgt. Eine Allowlist der Clients gibt es nicht: Die API nimmt jedes Token mit
# Audience der API und Scope mcp_access an, die Werkzeuge prüfen Capabilities aus App-Rollen.

variable "mcp" {
  description = "MCP-Server einschalten: Scope mcp_access an der API, öffentliche Client-Registrierung für MCP-Clients, Vorautorisierung."
  type        = bool
  default     = false
}

variable "mcp_custom_domain" {
  description = "Eigene Domain der Function für den MCP-Endpunkt, z. B. mcp.example.org; die Domain oder eine übergeordnete muss im Tenant verifiziert sein. Claude sendet die MCP-Adresse als resource (RFC 8707), und Entra stellt nur ein Token aus, wenn sie Application ID URI der API ist. Ohne Domain funktionieren nur Clients, die ohne resource anmelden, etwa VS Code. Hostname-Bindung und Zertifikat an der Function sind Handarbeit (README)."
  type        = string
  default     = null

  validation {
    condition     = var.mcp_custom_domain == null || can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.mcp_custom_domain))
    error_message = "mcp_custom_domain: ein Hostname in Kleinbuchstaben ohne Schema und Pfad, z. B. mcp.example.org."
  }
}

variable "mcp_redirect_uris" {
  description = "Redirect-URIs der MCP-Client-Registrierung (Plattform „Mobile und Desktop“, öffentlicher Client mit PKCE). Standard: Claude (Web, Desktop, Mobil) und Claude Code (Loopback; Entra ignoriert dort den Port)."
  type        = list(string)
  nullable    = false
  default = [
    "https://claude.ai/api/mcp/auth_callback",
    "http://localhost/callback",
    "http://127.0.0.1/callback",
  ]

  validation {
    condition     = alltrue([for uri in var.mcp_redirect_uris : can(regex("^(https://|http://localhost[:/]|http://127\\.0\\.0\\.1[:/])", uri))])
    error_message = "mcp_redirect_uris: jeweils https:// oder http://localhost bzw. http://127.0.0.1."
  }
}

variable "mcp_preauthorized_client_ids" {
  description = "Weitere Clients mit eigener Entra-Registrierung, die mcp_access ohne Einwilligungsdialog bekommen. Standard: VS Code (aebc6443-…), das sich bei Entra immer mit seiner eigenen Registrierung anmeldet."
  type        = list(string)
  nullable    = false
  default     = ["aebc6443-996d-45c2-90f0-388ff96faa56"]
}

locals {
  mcp_scope_id = uuidv5("url", "https://github.com/blackforestsentinel/seed-terraform/sso/${local.base}/mcp_access")

  # Kanonische MCP-Adresse auf der eigenen Domain: genau das, was man in Claude einträgt, mit
  # Pfad und ohne Schrägstrich am Ende. Sie ist zugleich Application ID URI der API und
  # App-Setting Mcp__Resource; ein abweichendes Zeichen lässt die Anmeldung scheitern.
  mcp_resource = var.mcp && var.mcp_custom_domain != null ? "https://${var.mcp_custom_domain}/api/mcp" : null

  # Zusätzliche delegierte Berechtigung der API, eingebunden in main.tf.
  mcp_permission_scopes = var.mcp ? {
    mcp_access = {
      id                         = local.mcp_scope_id
      admin_consent_display_name = "MCP-Zugriff auf ${local.base}"
      admin_consent_description  = "Erlaubt einem MCP-Client wie Claude oder VS Code, im Namen der angemeldeten Person die Werkzeuge von ${local.base} aufzurufen. Gilt nur für den MCP-Endpunkt, nicht für die übrige API."
      user_consent_display_name  = "MCP-Zugriff auf ${local.base}"
      user_consent_description   = "Erlaubt einem KI-Werkzeug wie Claude oder VS Code, in deinem Namen die Werkzeuge von ${local.base} aufzurufen."
    }
  } : {}

  mcp_app_settings = local.mcp_resource == null ? {} : {
    Mcp__Resource = local.mcp_resource
  }

  # Microsoft Graph und dessen delegierte Berechtigung offline_access (feste IDs in allen Tenants).
  # Mit Application.ReadWrite.OwnedBy darf die Pipeline den Service Principal von Graph nicht
  # zwingend lesen; deshalb keine Datenquelle.
  msgraph_app_id         = "00000003-0000-0000-c000-000000000000"
  msgraph_offline_access = "7427e0e9-2fba-42fe-b0c0-848c9e6a8182"
}

# --- Client-Registrierung für MCP-Clients ----------------------------------------
# Eine Registrierung je Projekt und Umgebung für alle Personen: Jede meldet sich einzeln an und
# bekommt ein Token mit ihrer eigenen oid. Die Verbindung im Client ist ein Refresh-Token dort,
# kein Entra-Objekt; bei uns wird nichts gespeichert.

resource "azuread_application" "mcp" {
  count = var.mcp ? 1 : 0

  display_name     = "${local.base}-mcp"
  sign_in_audience = "AzureADMyOrg"
  owners           = local.owners

  # Nur Authorization Code mit PKCE über die Redirect-URIs; true öffnete zusätzlich Device Code
  # und Passwort-Anmeldung (ROPC), die kein MCP-Client braucht.
  fallback_public_client_enabled = false

  # „Mobile und Desktop“ = öffentlicher Client: Claude löst den Code mit PKCE und ohne Secret
  # ein. Unter „Web“ verlangte Entra ein Secret (AADSTS7000218), unter „SPA“ ginge das Einlösen
  # nur aus dem Browser (AADSTS9002327).
  public_client {
    redirect_uris = var.mcp_redirect_uris
  }

  # Deklariert, damit die Registrierung zeigt, wofür sie ist, und ein Klick auf
  # „Administratorzustimmung erteilen“ auch offline_access (Refresh-Token) abdeckt.
  # mcp_access selbst braucht keine Zustimmung, es ist unten vorautorisiert.
  required_resource_access {
    resource_app_id = azuread_application.api.client_id

    resource_access {
      id   = local.mcp_scope_id
      type = "Scope"
    }
  }

  required_resource_access {
    resource_app_id = local.msgraph_app_id

    resource_access {
      id   = local.msgraph_offline_access
      type = "Scope"
    }
  }
}

resource "azuread_service_principal" "mcp" {
  count = var.mcp ? 1 : 0

  client_id = azuread_application.mcp[0].client_id
  owners    = local.owners
}

# Nur mcp_access, nie access_as_user: Ein Token, das ein MCP-Client bekommt, erreicht den
# MCP-Endpunkt und sonst nichts.
resource "azuread_application_pre_authorized" "mcp" {
  count = var.mcp ? 1 : 0

  application_id       = azuread_application.api.id
  authorized_client_id = azuread_application.mcp[0].client_id
  permission_ids       = [local.mcp_scope_id]
}

resource "azuread_application_pre_authorized" "mcp_clients" {
  for_each = var.mcp ? toset(var.mcp_preauthorized_client_ids) : toset([])

  application_id       = azuread_application.api.id
  authorized_client_id = each.value
  permission_ids       = [local.mcp_scope_id]
}

# Die MCP-Adresse als zweite Application ID URI neben api://<client-id>, die das Frontend
# weiter nutzt. Der Apply scheitert hier, wenn die Domain im Tenant nicht verifiziert ist.
# azuread_application.api ignoriert identifier_uris, die beiden URI-Ressourcen stören sich nicht.
resource "azuread_application_identifier_uri" "mcp" {
  count = local.mcp_resource == null ? 0 : 1

  application_id = azuread_application.api.id
  identifier_uri = local.mcp_resource
}

output "mcp_client_id" {
  description = "Client-ID der MCP-Client-Registrierung; in Claude unter „OAuth Client ID“, in Claude Code als --client-id. Null ohne mcp."
  value       = one(azuread_application.mcp[*].client_id)
}

output "mcp_resource" {
  description = "MCP-Adresse auf der eigenen Domain (https://<domain>/api/mcp), null ohne mcp_custom_domain."
  value       = local.mcp_resource
}

output "mcp_scope" {
  description = "Scope für MCP-Clients über den Standardnamen der Function; mit eigener Domain gilt <mcp_resource>/mcp_access. Null ohne mcp."
  value       = var.mcp ? "${local.api_identifier_uri}/mcp_access" : null
}
