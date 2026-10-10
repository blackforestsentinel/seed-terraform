# Sentinel Seed – Terraform-Module

Terraform-Module für Projekte aus dem [Sentinel-Seed-Template](https://github.com/blackforestsentinel/seed-template). Projekte binden sie als Git-Quelle mit fester Version ein:

```hcl
module "core" {
  source = "git::https://github.com/blackforestsentinel/seed-terraform.git//core?ref=v0.1.0"

  name        = local.cfg.project
  environment = var.environment
}
```

Alle Module eines Releases teilen sich einen Tag (`vX.Y.Z`). Projekte pinnen den Tag, keine Branches.

## Module

| Modul | Inhalt | Status |
| --- | --- | --- |
| `core` | Resource Group, Static Web App (Free), Function App (Flex Consumption, .NET 10), Application Insights mit Log Analytics, Host-Storage mit Managed Identity | Phase 1 |
| `sso` | App-Registrierungen für API und SPA, delegierte Berechtigung `access_as_user`, SPA vorab autorisiert | Phase 2 |
| `storage` | Storage Account mit RBAC für die Function | geplant |
| `connector` | App-Registrierung für den Custom Connector | geplant |

### core

Das Modul legt keine Schlüssel an: Die Function greift per User-Assigned Managed Identity auf ihren Host-Storage zu, Shared-Key-Zugriff ist abgeschaltet. Basic Auth für Deployments (SCM, FTP) ist aus, Deployments laufen über Entra ID. Die Function App entsteht per `azapi`, weil die azurerm-Ressource für Flex Consumption dabei fehlerhafte App-Settings setzt ([#29149](https://github.com/hashicorp/terraform-provider-azurerm/issues/29149), [#33211](https://github.com/hashicorp/terraform-provider-azurerm/issues/33211)).

Die ausführende Identität braucht `Contributor` und `Role Based Access Control Administrator` (oder `User Access Administrator`) auf der Subscription.

Provider-Einstellungen im aufrufenden Projekt:

```hcl
provider "azurerm" {
  features {}
  storage_use_azuread = true
}

provider "azapi" {}
```

Wichtige Eingaben: `name`, `environment`, `location` (Default `westeurope`), `app_settings` (zusätzliche App-Settings, z. B. aus dem sso-Modul), `cors_allowed_origins`.

Wichtige Ausgaben: `function_app_name`, `function_app_url`, `static_web_app_name`, `static_web_app_url`, `function_identity_principal_id`.

Konvention: Das Modul setzt die App-Settings `Seed__Project` und `Seed__Environment`, die `Bfs.Seed.Functions.Core` ausliest.

### sso

Legt zwei App-Registrierungen an (Single Tenant): die API mit der delegierten Berechtigung `access_as_user` und Application ID URI `api://<client-id>`, und die SPA mit den Redirect-URIs des Frontends. Die SPA ist an der API vorab autorisiert, Nutzerinnen und Nutzer sehen also keinen Einwilligungsdialog für die API.

```hcl
module "sso" {
  source = "git::https://github.com/blackforestsentinel/seed-terraform.git//sso?ref=<version>"
  count  = local.cfg.features.sso ? 1 : 0

  name              = local.cfg.project
  environment       = var.environment
  spa_redirect_uris = [module.core.static_web_app_url, "http://localhost:5173"]
}

module "core" {
  # ...
  app_settings = merge({}, [for m in module.sso : m.app_settings]...)
}
```

Die ausführende Identität braucht die Microsoft-Graph-Anwendungsberechtigung `Application.ReadWrite.OwnedBy` mit Admin-Consent. Sie trägt sich selbst als Besitzerin der App-Registrierungen ein und darf nur diese verwalten.

Ausgaben: `app_settings` (`Auth__TenantId`, `Auth__ClientId`, `Auth__Audience` für `Bfs.Seed.Auth`), `frontend_config` (Auth-Teil der `config.json` für `@blackforestsentinel/seed-web-auth`), dazu `api_client_id`, `api_scope`, `api_scope_id` und `spa_client_id`.

## Entwickeln

```bash
terraform fmt -recursive
terraform -chdir=examples/core init -backend=false
terraform -chdir=examples/core validate
terraform -chdir=examples/sso init -backend=false
terraform -chdir=examples/sso validate
```

## Lizenz

MIT, siehe [LICENSE](LICENSE).
