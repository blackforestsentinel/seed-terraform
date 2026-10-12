# Custom Connector für die Power Platform: eine Client-Registrierung, mit der sich der Connector
# im Namen der angemeldeten Person bei Entra anmeldet und die API aufruft (delegiert, wie das
# Frontend).
#
# Ohne Secret: Der Connector nutzt seine Managed Identity (Option der Power Platform, Preview),
# Entra vertraut ihr über einen Federated Credential an dieser Registrierung. Federated Credential
# und Redirect-URI hängen an einer Endung der Power-Platform-Umgebung, die erst der angelegte
# Connector kennt. Beides trägt deshalb die Pipeline nach dem Anlegen ein (seed-pipelines), die
# als Besitzerin dafür Application.ReadWrite.OwnedBy genügt.

variable "connector" {
  description = "Client-Registrierung für einen Power-Platform-Custom-Connector: single-tenant, ohne Secret, für die delegierte Berechtigung der API vorautorisiert. Redirect-URI und Federated Credential trägt die Pipeline ein."
  type        = bool
  default     = false
}

locals {
  # Mit existing_registration gehört die API nicht der Pipeline; den Client richtet dann der
  # Admin im anderen Tenant ein (README).
  connector_create = var.connector && local.create
}

resource "azuread_application" "connector" {
  count = local.connector_create ? 1 : 0

  display_name = "${local.base}-connector"
  # Die Managed Identity des Connectors funktioniert nur mit single-tenant-Registrierungen.
  sign_in_audience = "AzureADMyOrg"
  owners           = local.owners

  # Deklariert, damit die Registrierung zeigt, wofür sie ist; eine Zustimmung braucht es nicht,
  # der Client ist unten vorautorisiert.
  required_resource_access {
    resource_app_id = azuread_application.api[0].client_id

    resource_access {
      id   = local.scope_id
      type = "Scope"
    }
  }

  # Redirect-URIs (Plattform „Web“) trägt die Pipeline je Connector ein; sie gehören nicht in den
  # Plan, sonst entfernte jeder Apply sie wieder.
  lifecycle {
    ignore_changes = [web]
  }
}

resource "azuread_service_principal" "connector" {
  count = local.connector_create ? 1 : 0

  client_id = azuread_application.connector[0].client_id
  owners    = local.owners
}

# Dieselbe Berechtigung wie das Frontend: Der Connector ruft die API wie ein Browser im Namen
# der angemeldeten Person auf; welche Functions sie erreicht, regeln App-Rollen und Capabilities.
resource "azuread_application_pre_authorized" "connector" {
  count = local.connector_create ? 1 : 0

  application_id       = azuread_application.api[0].id
  authorized_client_id = azuread_application.connector[0].client_id
  permission_ids       = [local.scope_id]
}

check "connector_existing_registration" {
  assert {
    condition     = !(var.connector && !local.create)
    error_message = "connector mit existing_registration: Die Client-Registrierung des Custom Connectors legt das Modul nicht an; sie muss im anderen Tenant von Hand eingerichtet werden (README)."
  }
}

output "connector_client_id" {
  description = "Client-ID der Client-Registrierung des Custom Connectors; die Pipeline trägt sie in den Connector ein und ergänzt an ihr Redirect-URI und Federated Credential. Null ohne connector."
  value       = one(azuread_application.connector[*].client_id)
}
