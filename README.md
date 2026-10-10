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
| `sso` | App-Registrierungen für API und SPA | geplant |
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

## Entwickeln

```bash
terraform fmt -recursive
terraform -chdir=examples/core init -backend=false
terraform -chdir=examples/core validate
```

## Lizenz

MIT, siehe [LICENSE](LICENSE).
