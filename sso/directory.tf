# Personen-Komponenten im Frontend (@blackforestsentinel/seed-web-people): Profilbilder, Profile,
# Suche und Teams-Status lädt das Frontend mit dem Token der angemeldeten Person direkt aus
# Microsoft Graph. Das Modul trägt dafür delegierte Graph-Berechtigungen an der SPA-Registrierung
# ein und nennt die Scopes in frontend_config; die API ist nicht beteiligt.
#
# Die Einwilligung erteilt das Modul nicht, dafür bräuchte die Pipeline
# DelegatedPermissionGrant.ReadWrite.All. Je Tenant und Registrierung klickt ein Admin einmal auf
# „Administratorzustimmung erteilen“, oder die Personen stimmen selbst zu, soweit der Tenant das
# für die Berechtigung zulässt (README).

variable "directory" {
  description = "Personen-Komponenten im Frontend. enabled trägt die delegierten Graph-Berechtigungen User.Read, User.ReadBasic.All und People.Read an der SPA-Registrierung ein, presence zusätzlich Presence.Read.All (Teams-Status), role_filter Application.Read.All und GroupMember.Read.All (Personenauswahl nur mit App-Rolle, braucht Administratorzustimmung). presence und role_filter wirken nur mit enabled; enabled = false schaltet alles ab, etwa je Umgebung. frontend_config nennt die Scopes unter auth.directory. Bei existing_registration legt das Modul nichts an; die Ausgabe directory_permissions nennt, was der Admin des anderen Tenants einträgt."
  type = object({
    enabled     = optional(bool, false)
    presence    = optional(bool, false)
    role_filter = optional(bool, false)
  })
  default  = {}
  nullable = false
}

locals {
  # Delegierte Berechtigungen von Microsoft Graph mit ihren festen IDs, in allen Tenants gleich
  # (geprüft am Service Principal von Graph). Wie in mcp.tf ohne Datenquelle, weil die Pipeline
  # den Service Principal mit Application.ReadWrite.OwnedBy nicht zwingend lesen darf.
  # admin = true: Typ Admin, nur mit Administratorzustimmung. Sonst Typ User: Personen dürfen
  # selbst zustimmen, wenn die Einwilligungseinstellungen des Tenants es für sie zulassen.
  msgraph_directory_scopes = {
    "User.Read"            = { id = "e1fe6dd8-ba31-4d61-89e7-88639da4683d", admin = false } # eigenes Profil und Foto
    "User.ReadBasic.All"   = { id = "b340eb25-3456-403f-be2f-af7a0d370277", admin = false } # andere Personen, Fotos, Suche
    "People.Read"          = { id = "ba47897c-39ec-4d83-8086-ee8256fa737d", admin = false } # relevante Personen
    "Presence.Read.All"    = { id = "9c7a330d-35b3-4aa1-963d-cb2b9f927841", admin = false } # Teams-Status
    "Application.Read.All" = { id = "c79f8feb-a9db-4090-85f9-90d820caa0eb", admin = true }  # Rollenzuweisungen der API
    "GroupMember.Read.All" = { id = "bc024368-1153-4739-b217-4326f2e966d0", admin = true }  # Mitglieder zugewiesener Gruppen
  }

  # Die Berechtigungen je Schalter, in der Reihenfolge von frontend_config. enabled ist der
  # Hauptschalter: Ein Override wie enabled = false für eine Umgebung schaltet auch presence und
  # role_filter aus, ohne dass sie mit zurückgesetzt werden müssen.
  directory_scope_names = concat(
    var.directory.enabled ? ["User.Read", "User.ReadBasic.All", "People.Read"] : [],
    var.directory.enabled && var.directory.presence ? ["Presence.Read.All"] : [],
    var.directory.enabled && var.directory.role_filter ? ["Application.Read.All", "GroupMember.Read.All"] : [],
  )

  # Ohne Frontend ruft niemand Graph auf; dann bleibt alles aus.
  directory = var.directory.enabled && local.spa

  # Teil von frontend_config.auth für seed-web-people, eingebunden in outputs.tf. apiClientId
  # nennt die API-Registrierung, deren Rollenzuweisungen der Filter liest.
  directory_frontend_config = {
    for key in local.directory ? ["directory"] : [] : key => {
      scopes      = [for name in local.directory_scope_names : "https://graph.microsoft.com/${name}"]
      presence    = var.directory.presence
      roleFilter  = var.directory.role_filter
      apiClientId = local.api_client_id
    }
  }
}

output "directory_permissions" {
  description = "Mit directory: die delegierten Graph-Berechtigungen an der SPA-Registrierung (value, id, admin_consent) und der Befehl für die Administratorzustimmung. Bei existing_registration trägt der Admin des anderen Tenants die Berechtigungen an seiner SPA-Registrierung ein. Null ohne directory oder ohne Frontend."
  value = local.directory ? {
    tenant_id     = local.tenant_id
    spa_client_id = local.spa_client_id
    permissions = [
      for name in local.directory_scope_names : {
        value         = name
        id            = local.msgraph_directory_scopes[name].id
        admin_consent = local.msgraph_directory_scopes[name].admin
      }
    ]
    # Mit role_filter immer, sonst je nach Einwilligungseinstellungen des Tenants (README).
    admin_consent_required = anytrue([for name in local.directory_scope_names : local.msgraph_directory_scopes[name].admin])
    # Von einem Admin des Tenants auszuführen; im Portal: App-Registrierungen → SPA →
    # API-Berechtigungen → „Administratorzustimmung erteilen“.
    admin_consent_command = local.spa_client_id == null ? null : "az ad app permission admin-consent --id ${local.spa_client_id}"
  } : null
}
