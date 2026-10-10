# Sentinel Seed – Terraform-Module

Terraform-Module für Projekte aus dem [Sentinel-Seed-Template](https://github.com/blackforestsentinel/seed-template). Projekte binden sie als Git-Quelle mit fester Version ein:

```hcl
module "core" {
  source = "git::https://github.com/blackforestsentinel/seed-terraform.git//core?ref=v0.5.0"

  name        = local.cfg.project
  environment = var.environment
}
```

Alle Module eines Releases teilen sich einen Tag (`vX.Y.Z`). Projekte pinnen den Tag, keine Branches.

## Module

| Modul | Inhalt | Status |
| --- | --- | --- |
| `core` | Resource Group, Static Web App (Free oder Standard, mit eigenen Domains; entfällt bei Projekten ohne Frontend), Function App (Flex Consumption, .NET 10), Application Insights mit Log Analytics, Host-Storage mit Managed Identity | Phase 1 |
| `sso` | App-Registrierungen für API und SPA (ohne Frontend nur API), delegierte Berechtigung `access_as_user`, SPA vorab autorisiert | Phase 2 |
| `storage` | Storage Account mit RBAC für die Function | geplant |
| `connector` | App-Registrierung für den Custom Connector | geplant |
| `ado-project` | Seed-Projekt in Azure DevOps: Repo aus dem Template, Environments mit Freigaben, Pipeline (für `seed-scaffold`); `frontend = false` legt ein Projekt ohne Frontend an | Phase 3 |

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

Wichtige Eingaben: `name`, `environment`, `location` (Default `westeurope`), `static_web_app_sku` (`Free`, `Standard` oder `None`; Azure erlaubt höchstens 10 Free-SWAs je Subscription), `custom_domains` (eigene Domains der Static Web App), `app_settings` (zusätzliche App-Settings, z. B. aus dem sso-Modul), `cors_allowed_origins`.

Wichtige Ausgaben: `function_app_name`, `function_app_url`, `static_web_app_name`, `static_web_app_url`, `custom_domain_dns_records`, `function_identity_principal_id`.

Konvention: Das Modul setzt die App-Settings `Seed__Project` und `Seed__Environment`, die `Bfs.Seed.Functions.Core` ausliest.

CORS: Die Function lässt die Standard-URL der Static Web App, alle eigenen Domains und `cors_allowed_origins` zu.

#### Eigene Domains

```hcl
module "core" {
  # ...
  custom_domains = ["app.example.org"]
}
```

Das Modul legt je Domain eine `azurerm_static_web_app_custom_domain` mit Validierung per TXT-Eintrag (`dns-txt-token`) an. Terraform wartet dabei nur auf das Token, nicht auf den DNS-Eintrag; der Apply läuft also auch dann durch, wenn das DNS außerhalb von Azure liegt und erst danach gepflegt wird. Die Alternative `cname-delegation` wartet im Apply bis zu 30 Minuten auf einen schon gesetzten CNAME, scheitert sonst und geht für Apex-Domains (`example.org`) gar nicht.

Ablauf:

1. Domain in `custom_domains` eintragen (im Template: `hosting.customDomains` in `project.yaml`) und die Pipeline laufen lassen. Die Infrastruktur-Freigabe ist nötig, weil eine Ressource hinzukommt.
2. Die DNS-Einträge stehen im Output `custom_domain_dns_records` (am Ende des Apply-Logs):
   - `txt_name` / `txt_value`: TXT-Eintrag `_dnsauth.<domain>` mit dem Token, für die Validierung.
   - `cname`: Ziel für den Datenverkehr. Bei einer Subdomain ein CNAME `<domain>` auf diesen Host, bei einer Apex-Domain ein ALIAS- oder ANAME-Eintrag (bzw. CNAME-Flattening) auf denselben Host.
3. Azure prüft den TXT-Eintrag selbst und stellt danach ein Zertifikat aus; das dauert Minuten bis einige Stunden. Den Status zeigt `az staticwebapp hostname list` oder der Deploy-Schritt der Pipeline aus seed-pipelines (Warnung, solange eine Domain nicht bereit ist).

Azure leert das Token nach der Validierung; das Modul hält den Wert fest, damit sich der Output nicht ändert und kein Plan ohne echte Änderung eine Freigabe verlangt. Den TXT-Eintrag stehen lassen. Läuft die Validierung ab (Status `Failed`), die Domain entfernen, Pipeline laufen lassen und wieder eintragen. Free erlaubt 2, Standard 5 eigene Domains je Static Web App.

#### Ohne Frontend

Mit `static_web_app_sku = "None"` entsteht keine Static Web App; `static_web_app_name` und `static_web_app_url` sind dann leere Strings (nicht `null`, weil die Pipeline sie mit `terraform output -raw` liest). Eigene Domains sind in diesem Fall nicht erlaubt.

Ab v0.5.0 legt das Modul die Static Web App per `count` an. Bestehende States verschiebt ein `moved`-Block von `azurerm_static_web_app.this` nach `azurerm_static_web_app.this[0]`; die Ressource selbst bleibt unverändert. seed-pipelines wertet einen Plan, der nur verschiebt, ab v0.4.0 nicht als Infrastruktur-Änderung.

### sso

Legt zwei App-Registrierungen an (Single Tenant): die API mit der delegierten Berechtigung `access_as_user` und Application ID URI `api://<client-id>`, und die SPA mit den Redirect-URIs des Frontends. Die SPA ist an der API vorab autorisiert, Nutzerinnen und Nutzer sehen also keinen Einwilligungsdialog für die API.

Eigene Domains gehören als `https://<domain>` mit in `spa_redirect_uris`. Ohne Redirect-URIs (Projekt ohne Frontend, `spa_redirect_uris` weglassen oder leer) entsteht nur die API-Registrierung: keine SPA, kein Service Principal dafür, keine Vorab-Autorisierung. Ab v0.5.0 liegen die SPA-Ressourcen deshalb unter `[0]`; `moved`-Blöcke verschieben bestehende States ohne Änderung an den Registrierungen.

```hcl
module "sso" {
  source = "git::https://github.com/blackforestsentinel/seed-terraform.git//sso?ref=<version>"
  count  = local.cfg.features.sso ? 1 : 0

  name              = local.cfg.project
  environment       = var.environment
  spa_redirect_uris = [module.core.static_web_app_url, "https://app.example.org", "http://localhost:5173"]
}

module "core" {
  # ...
  app_settings = merge({}, [for m in module.sso : m.app_settings]...)
}
```

Die ausführende Identität braucht die Microsoft-Graph-Anwendungsberechtigung `Application.ReadWrite.OwnedBy` mit Admin-Consent. Sie trägt sich selbst als Besitzerin der App-Registrierungen ein und darf nur diese verwalten.

Ausgaben: `app_settings` (`Auth__TenantId`, `Auth__ClientId`, `Auth__Audience` für `Bfs.Seed.Auth`), `frontend_config` (Auth-Teil der `config.json` für `@blackforestsentinel/seed-web-auth`, ohne SPA leer), dazu `api_client_id`, `api_scope`, `api_scope_id` und `spa_client_id` (ohne SPA `null`).

## Entwickeln

```bash
terraform fmt -recursive
terraform -chdir=examples/core init -backend=false
terraform -chdir=examples/core validate
terraform -chdir=examples/sso init -backend=false
terraform -chdir=examples/sso validate
terraform -chdir=examples/api-only init -backend=false
terraform -chdir=examples/api-only validate
```

## Lizenz

MIT, siehe [LICENSE](LICENSE).
