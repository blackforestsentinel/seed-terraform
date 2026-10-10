# App-Rollen der API aus auth.roles in project.yaml. Welche Capabilities eine Rolle bringt, weiß
# nur die API (Bfs.Seed.Auth liest dieselbe Datei); Entra ID kennt nur die Rollen. Personen und
# Gruppen weist ein Admin in Entra zu: Dafür bräuchte die Pipeline AppRoleAssignment.ReadWrite.All,
# Application.ReadWrite.OwnedBy reicht nicht.

variable "app_roles" {
  description = "App-Rollen der API, Schlüssel ist der Wert im roles-Claim. allowed_member_types: User, Application oder beide (Default User); Application erlaubt Aufrufe ohne angemeldete Person. Bei existing_registration nur Ausgabe für den Admin des anderen Tenants."
  type = map(object({
    description          = optional(string)
    display_name         = optional(string)
    allowed_member_types = optional(list(string), ["User"])
  }))
  default = {}

  validation {
    condition     = alltrue([for value in keys(var.app_roles) : can(regex("^[A-Za-z0-9][A-Za-z0-9._:-]{0,119}$", value))])
    error_message = "app_roles: Rollennamen ohne Leerzeichen, höchstens 120 Zeichen, z. B. Admin oder Invoices.Write."
  }

  validation {
    condition = alltrue([
      for role in values(var.app_roles) : length(role.allowed_member_types) > 0 && alltrue([for t in role.allowed_member_types : contains(["User", "Application"], t)])
    ])
    error_message = "app_roles: allowed_member_types enthält User, Application oder beide."
  }
}

variable "assignment_required" {
  description = "Zuweisung erforderlich: Tokens für die API bekommen nur Personen, Gruppen und Anwendungen mit einer App-Rolle. Default false, dann kann sich jedes Konto des Tenants anmelden."
  type        = bool
  default     = false
}

locals {
  # Stabile IDs je Rolle, wie bei der delegierten Berechtigung; ein neuer Name ist eine neue Rolle.
  app_roles = {
    for value, role in var.app_roles : value => {
      id                   = uuidv5("url", "https://github.com/blackforestsentinel/seed-terraform/sso/${local.base}/roles/${value}")
      display_name         = coalesce(role.display_name, value)
      description          = coalesce(role.description, role.display_name, value)
      allowed_member_types = role.allowed_member_types
    }
  }
}

# Eigene Ressource statt app_role-Block, damit Rollen ohne Änderung an der Registrierung selbst
# dazukommen; azuread_application.api ignoriert app_role deshalb. Beim Entfernen deaktiviert der
# Provider die Rolle zuerst, wie Entra ID es verlangt.
resource "azuread_application_app_role" "api" {
  for_each = local.create ? local.app_roles : {}

  application_id       = azuread_application.api[0].id
  role_id              = each.value.id
  value                = each.key
  display_name         = each.value.display_name
  description          = each.value.description
  allowed_member_types = each.value.allowed_member_types
}

output "app_roles" {
  description = "App-Rollen der API mit ID; bei existing_registration die Rollen, die der Admin im anderen Tenant anlegen muss."
  value       = local.app_roles
}
