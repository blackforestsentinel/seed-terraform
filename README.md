# Sentinel Seed – Terraform-Module

Terraform-Module für Projekte aus dem [Sentinel-Seed-Template](https://github.com/blackforestsentinel/seed-template). Projekte binden sie als Git-Quelle mit fester Version ein:

```hcl
module "core" {
  source = "git::https://github.com/blackforestsentinel/seed-terraform.git//core?ref=v0.6.0"

  name        = local.cfg.project
  environment = var.environment
}
```

Alle Module eines Releases teilen sich einen Tag (`vX.Y.Z`). Projekte pinnen den Tag, keine Branches.

## Module

| Modul | Inhalt | Status |
| --- | --- | --- |
| `core` | Resource Group (neu oder vorhanden), Static Web App (Free oder Standard, mit eigenen Domains; entfällt bei Projekten ohne Frontend), Function App (Flex Consumption, .NET 10), Application Insights und Log Analytics (Tageslimit) ohne lokale Authentifizierung, Host-Storage mit Managed Identity | Phase 1 |
| `sso` | App-Registrierungen für API und SPA (ohne Frontend nur API), delegierte Berechtigung `access_as_user`, SPA vorab autorisiert, Liste der zugelassenen Clients für `Bfs.Seed.Auth`, App-Rollen, Bridge-Seite für die stille Anmeldung; alternativ eine vorhandene Registrierung, auch aus einem anderen Tenant; mit `mcp` Scope `mcp_access` und Client-Registrierung für MCP-Clients; mit `connector` Client-Registrierung für einen Power-Platform-Custom-Connector (ohne Secret); mit `directory` delegierte Graph-Berechtigungen für die Personen-Komponenten im Frontend | Phase 2 |
| `monitoring` | Aktionsgruppe, Alarme (Exceptions, Health-Check alle 4 Stunden per Logic App, Tageslimit für Logs, Ablauf von Secrets im Key Vault) und Budget je Resource Group; nur mit Empfängern | Baustein 5 |
| [`keyvault`](keyvault/README.md) | Key Vault je Projekt und Umgebung (RBAC, Purge-Schutz), Platzhalter-Secrets, Key-Vault-Referenzen als App-Settings `Secrets__<Name>`, URI des Vaults als `Seed__KeyVaultUri`, auf Wunsch Audit-Log in den Workspace aus `core` | Baustein 2 |
| `storage` | Eigener Storage Account für Daten: Tabellen, Queues, Container, Versionierung, Soft Delete, Lifecycle-Regeln, Datenrollen für die Function, optional Schreibrecht auf den Container `extension` für eine selbst gehostete Browser-Erweiterung; Verbindung `SeedStorage` als App-Settings | Baustein 1 |
| `ado-project` | Seed-Projekt in Azure DevOps: Repo aus dem Template oder ein vorhandenes Repo, Environments mit Freigaben, Pipeline, Branch-Policies für PR-Validierung und Reviewer, eingeschränkte Rechte am Repo (für `seed-scaffold`); `frontend = false` legt ein Projekt ohne Frontend an; ab v0.20.0 optional neues Projekt, eigene Service Connection je Projekt mit Checks und Mitglieder | Phase 3 |

### Besitzer (`owner`)

Jedes Projekt hat eine Ansprechperson oder ein Team, im Template `owner` in `project.yaml`. Die Module `core`, `keyvault`, `storage`, `monitoring` und `sso` nehmen sie als Variable `owner` an, eine E-Mail-Adresse oder einen Verteiler:

```hcl
module "core" {
  # ...
  owner = try(local.cfg.owner, null) # z. B. team@example.org; "" wie null
}
```

| Modul | Wirkung |
| --- | --- |
| `core`, `keyvault`, `storage`, `monitoring` | Tag `owner` an jeder Ressource, die Tags kennt. Er ersetzt einen Tag `owner` aus `tags`, gleich wie geschrieben (`Owner`, `OWNER`): Azure unterscheidet bei Tag-Namen keine Groß- und Kleinschreibung. |
| `monitoring` | Zusätzlicher Empfänger `owner` in der Aktionsgruppe, also für alle Alarme und Budget-Warnungen. Steht die Adresse schon in `alert_emails`, auch anders geschrieben, kommt keine zweite Mail. |
| `sso` | App-Registrierungen kennen keine Azure-Tags. Das Modul schreibt `owner: <adresse>` als Notiz (`notes`) an jede Registrierung und jeden Service Principal, den es anlegt. Besitzerin im Sinne von Entra bleibt die Pipeline-Identität. |
| `ado-project` | `owner` in der erzeugten `project.yaml`; ohne Angabe `owner: ""` mit `TODO(onboarding)`, wie im Template. |

Die Module prüfen das Format einer E-Mail-Adresse. Leerer Text gilt wie `null`: Das Template liefert `owner: ""` aus, bis jemand eine Adresse einträgt, und kann den Wert unverändert übergeben. Fehlt der Schlüssel ganz, fängt das der Aufrufer ab, etwa mit `try(local.cfg.owner, null)`. Ohne `owner` (Default `null`) oder mit leerem Text ändert sich nichts.

Umstieg: Kommt `owner` dazu, ändert der nächste Apply die Tags an Ort und Stelle; nichts wird ersetzt. Die Pipeline verlangt dafür einmal die Infrastruktur-Freigabe. Die Function App schreibt Terraform dabei mit ihrer ganzen Konfiguration neu (`azapi`), wie bei jeder Änderung der App-Settings; sie kann dabei neu starten. Azure schickt der Adresse einmal eine Mail, dass sie der Aktionsgruppe hinzugefügt wurde.

### core

Das Modul legt keine Schlüssel an: Die Function greift per User-Assigned Managed Identity auf ihren Host-Storage zu, Shared-Key-Zugriff ist abgeschaltet. Basic Auth für Deployments (SCM, FTP) ist aus, Deployments laufen über Entra ID. Die Function App entsteht per `azapi`, weil die azurerm-Ressource für Flex Consumption dabei fehlerhafte App-Settings setzt ([#29149](https://github.com/hashicorp/terraform-provider-azurerm/issues/29149), [#33211](https://github.com/hashicorp/terraform-provider-azurerm/issues/33211)).

Die ausführende Identität braucht `Contributor` und `Role Based Access Control Administrator` (oder `User Access Administrator`) auf der Subscription. Mit `create_resource_group = false` genügen beide auf der Resource Group des Projekts (unten).

#### Resource Group (`create_resource_group`)

Die Resource Group heißt `rg-<name>-<environment>`, also `rg-` + `name` (Projektname aus `project.yaml`) + `-` + `environment`, etwa `rg-kundenportal-dev`. Alle Ressourcen des Moduls liegen darin.

Ab v0.20.0 kann es sie schon geben: Mit `create_resource_group = false` (Standard `true`) legt das Modul sie nicht an, sondern liest sie unter genau diesem Namen (`data "azurerm_resource_group"`) und nutzt Name und ID wie bisher. Gedacht für das zentrale Scaffold mit einer Identität je Projekt: Es legt `rg-<name>-<environment>` vorab an und gibt der Identität des Projekts Rollen nur darauf, die Projekt-Pipeline legt sie dann nicht neu an. Wer die Resource Group anlegt, muss den Namen exakt so bilden. Im Template steuert das `createResourceGroups` in `project.yaml` (Modul `ado-project`, `create_resource_groups`).

Mit `false` ändert das Modul weder die Resource Group noch ihre Tags; Tags wie `seed:project` und `seed:environment` setzt, wer sie anlegt. Die übrigen Ressourcen entstehen weiter in `location` und bekommen ihre Tags wie bisher. Liegt die vorhandene Resource Group in einer anderen Region, warnt der Plan (Check `resource_group_location`).

Umstieg: Mit dem Standard bleibt alles, wie es ist; der erste Plan nach dem Update verschiebt die Resource Group im State nach `azurerm_resource_group.this[0]` (`moved`), ohne Änderung in Azure. `false` ist für neue Projekte gedacht. Ein bestehendes Projekt, dessen Resource Group Terraform verwaltet, plante sonst ihr Löschen; dort vorher `terraform state rm 'module.core.azurerm_resource_group.this[0]'`.

Provider-Einstellungen im aufrufenden Projekt:

```hcl
provider "azurerm" {
  features {}
  storage_use_azuread = true
}

provider "azapi" {}
```

Wichtige Eingaben: `name`, `environment`, `location` (Default `westeurope`), `static_web_app_sku` (`Free`, `Standard` oder `None`; Azure erlaubt höchstens 10 Free-SWAs je Subscription), `custom_domains` (eigene Domains der Static Web App), `app_settings` (zusätzliche App-Settings, z. B. aus dem sso-Modul), `cors_allowed_origins`, `log_daily_quota_gb` (Tageslimit für Logs, Default 1 GB), `maximum_instance_count` (Obergrenze der Instanzen, 1 bis 1000, Default 40; `null` gilt als Default), `owner` (Tag `owner`, siehe [Besitzer](#besitzer-owner)), `tags`, `create_resource_group` (Standard `true`, siehe oben).

Wichtige Ausgaben: `function_app_name`, `function_app_url`, `static_web_app_name`, `static_web_app_url`, `custom_domain_dns_records`, `function_identity_principal_id`; für das Modul monitoring `resource_group_id`, `application_insights_id` und `log_analytics_workspace_id`.

Konvention: Das Modul setzt die App-Settings `Seed__Project` und `Seed__Environment`, die `Bfs.Seed.Functions.Core` ausliest. Seine Grundeinstellungen (`AzureWebJobsStorage__*`, `APPLICATIONINSIGHTS_*`, `AZURE_CLIENT_ID`, `Seed__Project`, `Seed__Environment`) gehen gleichnamigen Einträgen aus `app_settings` vor; bis v0.6.0 war es umgekehrt.

Key-Vault-Referenzen (`@Microsoft.KeyVault(...)`) in `app_settings` löst die Plattform mit der UAMI der Function auf (`keyVaultReferenceIdentity`); die Leserechte vergibt das Modul [`keyvault`](keyvault/README.md). Ab dieser Version zeigt der erste Plan nach dem Update dafür einmal eine Änderung an der Function App.

CORS: Die Function lässt die Standard-URL der Static Web App, alle eigenen Domains und `cors_allowed_origins` zu, ohne Credentials. Ab v0.17.0 lehnt das Modul ein `*` in `cors_allowed_origins` ab, auch als Platzhalter wie `https://*.example.org`: Jede Website, bzw. jede Subdomain, dürfte die API sonst aus dem Browser aufrufen und die Antworten lesen. Ebenso den Origin `null`, den Browser für Sandbox-iframes, `data:`- und `file:`-Seiten senden und den damit jede Website erzeugen kann. Origins einzeln angeben. Das Template lässt schon bisher nur einzelne Origins zu.

#### Telemetrie ohne Schlüssel

Application Insights nimmt nur Telemetrie mit Entra-Token an (`local_authentication_enabled = false`). Wer den Connection String kennt, kann damit keine Telemetrie einschleusen. Die Function sendet per User-Assigned Managed Identity: Das Modul gibt ihr die Rolle `Monitoring Metrics Publisher` auf Application Insights und setzt `APPLICATIONINSIGHTS_AUTHENTICATION_STRING` (`Authorization=AAD;ClientId=<client-id>`). Diese Einstellung lesen der Functions-Host und im Worker `ConfigureFunctionsApplicationInsights()` aus `Microsoft.Azure.Functions.Worker.ApplicationInsights`, das `AddSeedCore()` aus `Bfs.Seed.Functions.Core` aufruft. Am Code ändert sich dafür nichts.

Der Log Analytics Workspace hat ein Tageslimit (`log_daily_quota_gb`, Default 1 GB, `-1` ohne Limit). Ist es erreicht, nimmt er bis 0 Uhr UTC nichts mehr an; das Modul monitoring meldet das.

Die ausführende Identität vergibt dafür eine weitere Rolle: Die Bedingung an `Role Based Access Control Administrator` muss `Monitoring Metrics Publisher` (`3913510d-42f4-4e42-8a64-420c390055eb`) erlauben.

Umstieg bestehender Projekte (vor dieser Version):

- Der Apply ändert Application Insights und den Workspace an Ort und Stelle; nichts wird neu angelegt, die Daten bleiben.
- Er legt die Rolle an und setzt das App-Setting. Die Function startet dadurch neu und sendet danach per Managed Identity, Host wie Worker. Ein neuer Deploy oder ein Paket-Update ist nicht nötig; alle bisherigen Versionen von `Bfs.Seed.Functions.Core` bringen `Microsoft.Azure.Functions.Worker.ApplicationInsights` 2.50 mit, das die Einstellung auswertet.
- Terraform schaltet die lokale Authentifizierung ab, bevor die Function das neue App-Setting hat. Telemetrie aus dieser Zeitspanne und dem Neustart geht verloren, im Test rund eine Minute. Danach ist sie vollständig. Wer das vermeiden will, wendet die Änderung in einer ruhigen Zeit an.

Ab v0.15.0 ist auch am Log Analytics Workspace die lokale Authentifizierung aus (`local_authentication_enabled = false`). Die Workspace-Schlüssel (Shared Keys) stehen weiter im State, gelten aber nicht mehr: Wer State oder Plan lesen kann, schreibt damit keine Daten in den Workspace. Die Seed-Module brauchen sie nicht: Application Insights schreibt als workspace-basierte Ressource über Azure Monitor in den Workspace, das Audit-Log des Key Vaults kommt per Diagnoseeinstellung, die Alarme aus monitoring fragen über Azure Monitor ab, und die Logic App des Health-Checks schreibt nichts in den Workspace. Abfragen im Portal und mit `az monitor log-analytics query` laufen ohnehin über Entra ID. Eigene Quellen, die mit Workspace-ID und Schlüssel senden (HTTP Data Collector API, alter Log-Analytics-Agent), vorher auf die Logs Ingestion API oder den Azure Monitor Agent umstellen. Der Apply ändert den Workspace an Ort und Stelle, die Daten bleiben.

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

Legt zwei App-Registrierungen an (Single Tenant): die API mit der delegierten Berechtigung `access_as_user` und Application ID URI `api://<client-id>`, und die SPA mit den Redirect-URIs des Frontends. Die SPA ist an der API vorab autorisiert, Nutzerinnen und Nutzer sehen also keinen Einwilligungsdialog für die API. Zustimmen dürfen für `access_as_user` nur Admins (Typ Admin): Die eigenen Clients, SPA und Custom Connector, sind vorab autorisiert; eine fremde App bekommt die Berechtigung also nicht über die Einwilligung einer einzelnen Person, gleich wie die Einwilligungseinstellungen des Tenants stehen. Bis v0.10.0 war die Berechtigung vom Typ User.

Eigene Domains gehören als `https://<domain>` mit in `spa_redirect_uris`. `http://` erlaubt das Modul nur für `localhost` und `127.0.0.1`, optional mit Port, danach `/` oder Ende, in `spa_redirect_uris` wie in `mcp_redirect_uris`; ab v0.18.0 lehnt es Hosts wie `http://localhost.example.org` ab, die bisher durchgingen. Ohne Redirect-URIs (Projekt ohne Frontend, `spa_redirect_uris` weglassen oder leer) entsteht nur die API-Registrierung: keine SPA, kein Service Principal dafür, keine Vorab-Autorisierung. Ab v0.5.0 liegen die SPA-Ressourcen deshalb unter `[0]`; `moved`-Blöcke verschieben bestehende States ohne Änderung an den Registrierungen. Ab v0.6.0 liegen auch die API-Ressourcen unter `[0]`, weil eine vorhandene Registrierung an ihre Stelle treten kann; `moved`-Blöcke verschieben bestehende States, der Plan verschiebt dann nur.

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

Ausgaben: `app_settings` (das Feature-Flag `Seed__Features__Sso = "true"`, mit dem das Template `UseSeedAuth()` einschaltet, sowie `Auth__TenantId`, `Auth__ClientId`, `Auth__Audience` für `Bfs.Seed.Auth`, bei einer anderen Berechtigung als `access_as_user` zusätzlich `Auth__RequiredScope`, dazu die [zugelassenen Clients](#zugelassene-clients) als `Auth__AllowedClientIds__0`, `Auth__AllowedClientIds__1`, …), `frontend_config` (Auth-Teil der `config.json` für `@blackforestsentinel/seed-web-auth`, ohne SPA leer), dazu `api_client_id`, `api_scope`, `api_scope_id`, `spa_client_id` (ohne SPA `null`), `spa_redirect_uris`, `app_roles` und `directory_permissions`.

#### Zugelassene Clients

Ab v0.15.0 nennt `app_settings` die Clients, deren delegierte Tokens die API annimmt, je einen als `Auth__AllowedClientIds__0`, `Auth__AllowedClientIds__1`, … (in `Bfs.Seed.Auth` die Liste `Auth:AllowedClientIds`). `Bfs.Seed.Auth` vergleicht sie mit dem Client im Token (`azp` bei v2-, `appid` bei v1-Tokens) und lehnt andere ab; ohne Einträge prüft es den Client nicht. Eine fremde App, der jemand im Tenant zugestimmt hat, kommt so nicht an die API, auch nicht über `mcp_access` (Typ User).

Das Modul trägt jeden Client ein, den es selbst anlegt, in dieser Reihenfolge:

1. die SPA-Registrierung (mit Frontend oder `spa_extra_redirect_uris`),
2. die Client-Registrierung des Custom Connectors (`connector`),
3. die Client-Registrierung für MCP-Clients (`mcp`),
4. die Clients aus `additional_allowed_client_ids`, sortiert, ohne Doppelte und klein geschrieben (bis v0.18.1 davor die Clients aus `mcp_preauthorized_client_ids`, siehe [MCP](#mcp)).

Mit `existing_registration` treten an die Stelle der eigenen Registrierungen die Client-IDs aus `existing_registration`, in derselben Reihenfolge und je nach Schalter: `spa_client_id` (mit Frontend), `connector_client_id` (mit `connector`), `mcp_client_id` (mit `mcp`), danach `additional_allowed_client_ids`; klein geschrieben, ohne Doppelte.

Die eigenen Registrierungen stehen vorn, statt einsortiert zu werden: Ihre Client-IDs entstehen erst beim Apply, eine ganz sortierte Liste wäre im Plan unbekannt und mit ihr alle App-Settings der Function. Kommt ein Client dazu oder fällt einer weg, verschieben sich die Nummern der folgenden Einträge; der Plan zeigt das als Änderung der App-Settings.

Ohne jeden Eintrag (nur API, keine weiteren Clients) prüft die API den Client nicht. Bis v0.17.0 setzte das Modul mit `existing_registration` nur die Einträge aus `additional_allowed_client_ids`: Ohne sie prüfte die API den Client gar nicht, mit ihnen lehnte sie die eigene SPA ab. Ab v0.18.0 steht die SPA aus `existing_registration` immer vorn; der erste Plan danach zeigt die neuen bzw. verschobenen App-Settings an der Function. Weitere Clients mit delegierten Tokens, etwa eine andere App mit Administratorzustimmung für `access_as_user` oder ein Dienst im On-Behalf-Of-Flow, kennt das Modul nicht: Sie gehören in `additional_allowed_client_ids` (im Template `auth.additionalClientIds` in `project.yaml`), sonst lehnt die API sie ab, sobald `Bfs.Seed.Auth` die Liste prüft. Solche Projekte vor dem Update prüfen. Tokens einer Anwendung ohne angemeldete Person (App-Rollen mit `Application`) betrifft die Liste nicht.

Umstieg: Der erste Plan nach dem Update zeigt an der Function App die neuen App-Settings, eine Änderung an Ort und Stelle; die Function startet danach neu. Versionen von `Bfs.Seed.Auth` ohne `AllowedClientIds` ignorieren die Einträge.

#### App-Rollen und Zuweisung

```hcl
module "sso" {
  # ...
  app_roles = {
    Reader = { description = "Liest Rechnungen" }
    Sync   = { description = "Nächtlicher Abgleich", allowed_member_types = ["Application"] }
  }
  assignment_required = true
}
```

`app_roles` legt je Eintrag eine App-Rolle an der API-Registrierung an; der Schlüssel ist der Wert im `roles`-Claim. `allowed_member_types` ist `User` (Default), `Application` oder beides; Rollen für `Application` erlauben Aufrufe ohne angemeldete Person (Client-Credentials-Flow). Die IDs sind stabil je Projekt, Umgebung und Rolle; ein umbenannter Schlüssel ist eine neue Rolle. Das Template füllt `app_roles` aus `auth.roles` in `project.yaml`, dieselbe Datei, aus der `Bfs.Seed.Auth` die Capabilities je Rolle liest. Entra ID kennt nur die Rollen.

Personen und Gruppen weist ein Admin in Entra zu (Enterprise App `<projekt>-<umgebung>-api`, „Benutzer und Gruppen“). Die Pipeline kann das nicht: Zuweisungen über Graph verlangen `AppRoleAssignment.ReadWrite.All`, `Application.ReadWrite.OwnedBy` reicht dafür nicht. Gruppen werden nicht verschachtelt aufgelöst; zugewiesen wird die Gruppe, in der die Personen direkt Mitglied sind.

`assignment_required` setzt „Zuweisung erforderlich“ am Service Principal der API: Ein Token für die API bekommen dann nur Personen, Gruppen und Anwendungen mit einer Rolle; alle anderen scheitern schon bei der Anmeldung (AADSTS50105). Ohne `app_roles` weist der Admin der Standardrolle („Standardzugriff“) zu. Mit `false` kann sich jedes Konto des Tenants anmelden und bekommt ohne Rolle nur keine Capabilities; eine Function ohne `[RequireCapability]` stünde ihm offen. Für die SPA gibt es `spa_assignment_required`, siehe [Personen und Profilbilder](#personen-und-profilbilder-microsoft-graph).

Default ist ab v0.17.0 `true` (bis v0.16.0 `false`); `null` gilt als Default. Umstieg: Wer das Modul ohne `assignment_required` einbindet, sieht im nächsten Plan eine Änderung am Service Principal der API an Ort und Stelle. Danach bekommt nur noch ein Token, wer eine Rolle hat; vor dem Update also Personen und Gruppen in Entra zuweisen oder `assignment_required = false` setzen. Das Template übergibt den Wert aus `auth.assignmentRequired` in `project.yaml` ausdrücklich, mit `false` als Rückfallwert: Projekte, deren `project.yaml` den Schlüssel nicht hat, behalten `false`, und neue Projekte haben `assignmentRequired: true` ausdrücklich in `project.yaml`. Für bestehende Template-Projekte ändert sich durch den neuen Default also nichts.

#### Bridge-Seite für die stille Anmeldung

MSAL 5 empfängt die Antwort der stillen Anmeldung im iframe nur über eine eigene Seite, die `broadcastResponseToMainFrame` aufruft. Mit `spa_redirect_bridge_path = "/redirect.html"` trägt das Modul je Origin der `spa_redirect_uris` die Redirect-URI `<origin>/redirect.html` ein und schreibt `redirectBridgePath` in `frontend_config`. Ohne die Variable bleibt alles wie bisher; `seed-web-auth` erneuert die Sitzung dann per Umleitung statt im iframe.

#### Weitere Redirect-URIs, etwa für eine Browser-Erweiterung

Sonderfall: Eine Browser-Erweiterung (Manifest V3) als weiterer Client derselben API meldet sich per `chrome.identity.launchWebAuthFlow` mit der Redirect-URI `https://<erweiterungs-id>.chromiumapp.org/` an. Sie gehört an die SPA-Registrierung, damit Entra ID die Einlösung des Codes mit `Origin: chrome-extension://<erweiterungs-id>` annimmt:

```hcl
module "sso" {
  # ...
  spa_extra_redirect_uris = ["https://abcdefghijklmnopabcdefghijklmnop.chromiumapp.org/"]
}
```

Das Modul übernimmt diese URIs ohne Bridge-Seite und ergänzt ohne Pfad den abschließenden Schrägstrich. Erlaubt ist nur `https://`; unter `chromiumapp.org` muss vor der Domain eine Erweiterungs-ID stehen (32 Zeichen `a` bis `p`). Auch ohne `spa_redirect_uris` entsteht damit die SPA-Registrierung, `frontend_config` dann ohne `redirectBridgePath`. Entpackte Erweiterung und Store-Version haben verschiedene IDs, die URI ist also meist je Umgebung verschieden. Die CORS-Freigabe für `chrome-extension://<erweiterungs-id>` an der Function kommt über `cors_allowed_origins` im Modul `core`. Ohne die Variable bleibt alles wie bisher.

#### Vorhandene App-Registrierung, auch aus einem anderen Tenant

```hcl
module "sso" {
  # ...
  existing_registration = {
    tenant_id     = "<tenant-id des Kunden>"
    api_client_id = "<client-id der API>"
    spa_client_id = "<client-id der SPA>"       # weglassen ohne Frontend
    api_scope     = "api://<client-id der API>/access_as_user"
    audience      = "api://<client-id der API>" # optional, Default: api_scope ohne den letzten Teil

    # optional, je nach Schalter
    connector_client_id = "<client-id des Connector-Clients>" # mit connector
    mcp_client_id       = "<client-id des MCP-Clients>"       # mit mcp Pflicht
  }
}
```

Dann legt das Modul nichts an und braucht keine Graph-Rechte im fremden Tenant. Es reicht Tenant, Client-IDs und Berechtigung als `app_settings` und `frontend_config` weiter; die API prüft Tokens gegen den angegebenen Tenant, das Frontend meldet sich dort an. Heißt die Berechtigung nicht `access_as_user`, setzt es `Auth__RequiredScope`. v1- und v2-Tokens akzeptiert `Bfs.Seed.Auth` beide. War die Registrierung bisher angelegt, entfernt der nächste Apply die eigenen Registrierungen.

**Zugelassene Clients:** Die Client-IDs aus `existing_registration` kommen wie die eigenen Registrierungen in die [zugelassenen Clients](#zugelassene-clients): `spa_client_id` mit Frontend, `connector_client_id` mit `connector`, `mcp_client_id` mit `mcp`, danach `additional_allowed_client_ids`. In `existing_registration` gehört also jeder Client aus dem anderen Tenant, der die API im Namen von Personen aufruft; ein fehlender wird abgelehnt, sobald die Liste einen Eintrag hat. Alle IDs müssen GUIDs sein, auch `tenant_id`. Bis v0.17.0 setzte das Modul hier nur `additional_allowed_client_ids` (siehe oben); ab v0.18.0 ist die SPA immer dabei.

Was der Admin im anderen Tenant einrichtet:

1. **SPA-Registrierung** (Plattform „Single-Page-Anwendung“) mit den Redirect-URIs aus der Ausgabe `spa_redirect_uris`: URL der Static Web App mit abschließendem Schrägstrich, eigene Domains, mit Bridge-Seite zusätzlich `<origin>/redirect.html` je Origin, in `dev` `http://localhost:5173/`, dazu `spa_extra_redirect_uris`. Die URL der Static Web App steht erst nach dem ersten Apply fest. Ihre Client-ID gehört als `spa_client_id` in `existing_registration`.
2. **API-Registrierung** mit Application ID URI (`audience`) und einer delegierten Berechtigung (`api_scope`). Unter „Eine API verfügbar machen“ muss bei der Berechtigung „Wer kann zustimmen?“ auf **„Nur Administratoren“** stehen (Typ Admin), wie bei Registrierungen, die das Modul anlegt. Der Standard im Portal ist „Administratoren und Benutzer“: Dann bekäme eine fremde App über die Einwilligung einer einzelnen Person Tokens für die API in deren Namen.
3. **Vorautorisierung:** die SPA unter „Eine API verfügbar machen“ als autorisierte Clientanwendung für die Berechtigung eintragen, ebenso den Client des Custom Connectors, falls es einen gibt. Mit Admin-Zustimmung (Schritt 2) ginge sonst jede Anmeldung erst über die Administratorzustimmung für die SPA.
4. **Mit `mcp`:** einen zweiten Scope `mcp_access` an der API und eine öffentliche Client-Registrierung für MCP-Clients wie in [MCP](#mcp) beschrieben (Mobile und Desktop, Redirect-URIs aus `mcp_redirect_uris`, ohne „Öffentliche Clientflows zulassen“), für `mcp_access` vorautorisiert, nie für `access_as_user`. Ihre Client-ID gehört als `mcp_client_id` in `existing_registration`, sonst bricht der Plan ab. Keine öffentlichen Clients von Microsoft (etwa VS Code) vorautorisieren, siehe [MCP](#mcp).
5. **App-Rollen** an der API-Registrierung gemäß `auth.roles` bzw. Ausgabe `app_roles`: Wert gleich Rollenname, zulässige Mitgliedstypen wie angegeben. Die IDs dürfen abweichen, entscheidend ist der Wert.
6. **Zuweisungen** von Personen und Gruppen zu den Rollen und „Zuweisung erforderlich“ an der Enterprise App der API. Das Modul setzt es bei eigenen Registrierungen als Standard; eine vorhandene erreicht es nicht. Mit `directory.role_filter` oder `directory.service_principals` zusätzlich „Zuweisung erforderlich“ an der Enterprise App der SPA und dieselben Gruppen dort zuweisen (`spa_assignment_required` wirkt bei einer vorhandenen Registrierung nicht).
7. **Mit `directory`:** die Graph-Berechtigungen an der SPA-Registrierung und die Zustimmung, siehe [Personen und Profilbilder](#personen-und-profilbilder-microsoft-graph).

#### Personen und Profilbilder (Microsoft Graph)

Für die Personen-Komponenten aus `@blackforestsentinel/seed-web-people` (im Template `auth.directory`): Profilbilder, Profile, Personensuche und Teams-Status, auf Wunsch auch Anwendungen und verwaltete Identitäten, lädt das Frontend mit dem Token der angemeldeten Person direkt aus Microsoft Graph. Die API ist nicht beteiligt, es gibt keine Anwendungsberechtigung und keinen Token-Tausch.

```hcl
module "sso" {
  # ...
  directory = {
    enabled            = true  # Fotos, Profile, Suche
    presence           = true  # Teams-Status
    role_filter        = false # Personenauswahl nur mit App-Rolle, braucht Administratorzustimmung
    service_principals = false # auch Anwendungen und verwaltete Identitäten, braucht Administratorzustimmung
  }
}
```

Das Modul trägt an der SPA-Registrierung `<name>-<umgebung>-web` delegierte Berechtigungen für Microsoft Graph ein und schreibt die Scopes als `directory` in `frontend_config.auth`. `enabled` ist der Hauptschalter: `presence`, `role_filter` und `service_principals` wirken nur mit ihm, `enabled = false` schaltet alles ab, etwa je Umgebung. `servicePrincipals: true` steht nur mit `service_principals` in `frontend_config`.

```json
"directory": {
  "scopes": ["https://graph.microsoft.com/User.Read", "https://graph.microsoft.com/User.ReadBasic.All", "https://graph.microsoft.com/People.Read", "https://graph.microsoft.com/Presence.Read.All"],
  "presence": true,
  "roleFilter": false,
  "apiClientId": "<Client-ID der API-Registrierung>"
}
```

| Schalter | Berechtigung | ID | Wofür | Typ |
| --- | --- | --- | --- | --- |
| `enabled` | `User.Read` | `e1fe6dd8-ba31-4d61-89e7-88639da4683d` | eigenes Profil und Foto | User |
| `enabled` | `User.ReadBasic.All` | `b340eb25-3456-403f-be2f-af7a0d370277` | andere Personen, ihre Fotos, Suche im Verzeichnis | User |
| `enabled` | `People.Read` | `ba47897c-39ec-4d83-8086-ee8256fa737d` | relevante Personen als erste Vorschläge | User |
| `presence` | `Presence.Read.All` | `9c7a330d-35b3-4aa1-963d-cb2b9f927841` | Teams-Status | User |
| `role_filter` | `Application.Read.All` | `c79f8feb-a9db-4090-85f9-90d820caa0eb` | wer der Enterprise App der API zugewiesen ist (`apiClientId`) | Admin |
| `role_filter` | `GroupMember.Read.All` | `bc024368-1153-4739-b217-4326f2e966d0` | Mitglieder zugewiesener Gruppen | Admin |
| `service_principals` | `Application.Read.All` | `c79f8feb-a9db-4090-85f9-90d820caa0eb` | Anwendungen und verwaltete Identitäten suchen (`/servicePrincipals`) und anzeigen | Admin |

Die IDs sind in allen Tenants gleich; das Modul nutzt sie fest wie bei `offline_access` in `mcp.tf`, weil die Pipeline mit `Application.ReadWrite.OwnedBy` den Service Principal von Graph nicht zwingend lesen darf. Delegiert heißt: Mit `enabled` und `presence` sieht das Frontend nur, was die angemeldete Person auch in Outlook und Teams sieht, und die Einstellungen des Tenants (etwa ausgeblendete Fotos) gelten weiter.

**`role_filter` und `service_principals` gelten tenantweit.** Sie geben der SPA, einem öffentlichen Client ohne Secret, die delegierten Berechtigungen `Application.Read.All` und `GroupMember.Read.All` für den ganzen Tenant, nicht nur für den Picker. Nach der Administratorzustimmung kann jede Person, die ein Token für die SPA-Client-ID bekommt, Microsoft Graph damit direkt aufrufen und alle App-Registrierungen und Service Principals (mit Redirect-URIs, App-Rollen und Metadaten der Anmeldeinformationen), alle Rollenzuweisungen und alle Gruppenmitgliedschaften aufzählen; auch ein Skriptfehler im Frontend (XSS) erreicht all das. Beide Optionen nur einschalten, wenn der Picker sie wirklich braucht, und die Zustimmung bewusst erteilen.

Die Zuweisungspflicht am Service Principal der API (`assignment_required`) greift nur für Tokens der API: Ein Token für Graph fordert die SPA bei Entra direkt an, begrenzt wird es nur durch „Zuweisung erforderlich“ an der Enterprise App der SPA (`<name>-<umgebung>-web`). Deshalb gilt:

- `role_filter` und `service_principals` verlangen, dass `spa_assignment_required` nicht `false` ist, sonst bricht der Plan ab. `assignment_required` an der API bleibt frei: Eine API ohne Zuweisungspflicht, etwa mit `[AllowWithoutRole]` und einer eigenen Berechtigungsliste je Datensatz, kann die Personenauswahl trotzdem nutzen (v0.18.0 verlangte hier zusätzlich `assignment_required = true`).
- `spa_assignment_required` setzt „Zuweisung erforderlich“ am Service Principal der SPA. Default `null`: an mit `role_filter` oder `service_principals` (bei `enabled`), sonst aus. `true` schaltet es auch ohne sie ein; `false` zusammen mit `role_filter` oder `service_principals` lehnt das Modul ab.
- Ist es an, meldet sich an der SPA nur an, wer ihr zugewiesen ist: Personen oder Gruppen unter Enterprise App `<name>-<umgebung>-web` → „Benutzer und Gruppen“ → Rolle „Standardzugriff“ (Default Access). Alle anderen scheitern mit AADSTS50105, auch wenn sie eine Rolle an der API haben. Am einfachsten eine Sicherheitsgruppe einmal pflegen und sie den App-Rollen der API und dem „Standardzugriff“ der SPA zuweisen; Gruppenzuweisungen an Enterprise Apps brauchen Entra ID P1, sonst Personen einzeln. Die Pipeline kann das nicht (`AppRoleAssignment.ReadWrite.All`).

Umstieg: Wer `role_filter` oder `service_principals` schon nutzt, sieht im nächsten Plan eine Änderung am Service Principal der SPA an Ort und Stelle. Vor dem Update die Gruppen der SPA zuweisen, sonst kommt niemand mehr ins Frontend.

**Zustimmung, von Hand:** Das Modul erteilt keine Einwilligung; die Pipeline-Identität könnte das nur mit `DelegatedPermissionGrant.ReadWrite.All`. Nach dem Apply gibt es zwei Wege:

- **Administratorzustimmung (empfohlen):** Entra Admin Center → App-Registrierungen → `<name>-<umgebung>-web` → API-Berechtigungen → „Administratorzustimmung für &lt;Tenant&gt; erteilen“, oder `az ad app permission admin-consent --id <spa_client_id>` als Admin. Einmal je Registrierung, also je Projekt und Umgebung; sie gilt für alle Personen. Mit `role_filter` oder `service_principals` ist sie Pflicht, weil deren Berechtigungen vom Typ Admin sind.
- **Personen stimmen selbst zu:** Berechtigungen vom Typ User dürfen Personen beim ersten Aufruf selbst erteilen, aber nur, soweit die Einwilligungseinstellungen des Tenants es zulassen (Unternehmensanwendungen → Einwilligung und Berechtigungen). Mit der von Microsoft empfohlenen Einstellung gilt das nur für Berechtigungen, die als „geringes Risiko“ eingestuft sind, oft nur `openid`, `profile`, `email`, `offline_access` und `User.Read`. `User.ReadBasic.All`, `People.Read` und `Presence.Read.All` brauchen dann trotzdem die Administratorzustimmung, oder der Admin stuft sie unter „Berechtigungsklassifizierungen“ als geringes Risiko ein; das gilt dann für alle Apps im Tenant.

Eine Zustimmung deckt die Berechtigungen ab, die beim Klick eingetragen waren. Kommt `presence`, `role_filter` oder `service_principals` später dazu, erneut zustimmen. Abschalten entfernt die Berechtigungen aus der Registrierung; eine erteilte Zustimmung bleibt bestehen, bis ein Admin sie an der Enterprise App unter „Berechtigungen“ widerruft.

**Mit `existing_registration`** legt das Modul nichts an; `frontend_config` bekommt `directory` trotzdem, `apiClientId` ist dann `api_client_id`. Der Admin des anderen Tenants trägt an seiner SPA-Registrierung (`spa_client_id`, bei einer gemeinsamen Registrierung für SPA und API dieselbe) unter API-Berechtigungen → Berechtigung hinzufügen → Microsoft Graph → Delegierte Berechtigungen die Berechtigungen aus der Tabelle ein und erteilt die Administratorzustimmung wie oben. Die Ausgabe `directory_permissions` nennt Tenant, Client-ID, Berechtigungen mit ID und den Befehl.

Ausgabe `directory_permissions`: `tenant_id`, `spa_client_id`, `permissions` (je Berechtigung `value`, `id` und `admin_consent`), `admin_consent_required` (mit `role_filter` oder `service_principals`) und `admin_consent_command`; `null` ohne `directory` oder ohne Frontend. Ohne `directory` ändert sich an Registrierungen und Ausgaben nichts.

### ado-project

Legt für die Pipeline `seed-scaffold` ein Seed-Projekt in Azure DevOps an; Ablauf und Parameter beschreibt [seed-pipelines](https://github.com/blackforestsentinel/seed-pipelines). Die erzeugten Dateien `project.yaml` und `azure-pipelines.yml` entsprechen denen aus seed-template, mit Name, Features, Frontend, Umgebungen und Verbindungen des Projekts. Ab v0.17.0 setzt `project.yaml` `auth.assignmentRequired: true` und mit `owner` den Besitzer, sonst `owner: ""` mit `TODO(onboarding)`. `azure-pipelines.yml` bekommt den Laufzeitparameter `allowBreakingConnectorChanges` und die auskommentierten Schalter `treatWarningsAsErrors` und `checkConnectorConnections` erst mit `pipelines_version` ab v0.17.0; ältere Versionen von `web-app.yml` lehnen unbekannte Parameter ab.

PR-Validierung (`pr_validation`, Standard `true`): eine Branch-Policy auf `main`, nach der Pull Requests einen erfolgreichen Lauf der Projekt-Pipeline brauchen. Die Pipeline erkennt PR-Läufe selbst und baut, testet und sucht dann nur nach Secrets, ohne Deploy und ohne Service Connection; eine zweite Pipeline-Definition ist nicht nötig. Ein Ergebnis gilt 12 Stunden, auch wenn sich `main` ändert. Die Policy ist Pflicht und sperrt damit direkte Pushes auf `main`; sie entsteht deshalb erst nach den Dateien, die das Modul direkt auf `main` schreibt.

Voraussetzungen: `pipelines_version` ab v0.5.0, denn ältere Versionen von seed-pipelines deployen auch in PR-Läufen (das Modul bricht dann mit einer Meldung ab). Die anlegende Identität braucht am Repo die Berechtigung „Edit policies“; beim PAT von `seed-scaffold` genügt dafür der Scope Code (Read, write & manage).

Für ein zentrales Scaffold, das Seed-Projekte in anderen Azure-DevOps-Projekten anlegt (seed-pipelines, Selbstbedienung):

- **`create_repository = false`:** Das Modul nutzt das vorhandene Repo `repository` (leer: `name`) und schreibt nur `project.yaml` und `azure-pipelines.yml`. Grund: Das Job-Token des zentralen Projekts darf unter „Protect access to repositories in YAML pipelines“ keine Repos anlegen. Die Person legt das Repo an, die Pipeline führt seed-template vorher ein.
- **`approver_groups`:** Gruppen der Organisation, deren Mitglieder zusätzlich zu `approvers` freigeben.
- **`requester_can_approve`** (Standard `true`): im zentralen Scaffold `false`, damit niemand die eigene Infrastruktur allein freigibt.
- **`min_reviewers`** (Standard `1`, bis v0.14.0 `0`): Pflicht-Reviewer auf `main`, die eigene Stimme zählt nicht. Die Stage Plan nutzt die Service Connection schon vor jeder Freigabe; ohne Review könnte eine Person ihre eigene Pipeline-Änderung mergen und so die Rechte der Deployment-Identität nutzen. Arbeitet nur eine Person am Projekt, braucht sie eine zweite für Reviews oder das Recht, Policies beim Abschließen zu umgehen; `0` schaltet die Pflicht ab.
- **`pool`:** Agent-Pool der Projekt-Pipeline, ab `pipelines_version` v0.13.0; das Modul berechtigt die Pipeline für dessen Queue, sonst fragte der erste Lauf danach („Permit“).
- **Output `project_id`:** startet den ersten Lauf im anderen Projekt.

Bis v0.13.0 legte das Modul das Repo immer an; ein `moved`-Block übernimmt es in bestehenden States.

#### Rechte am Repo (`protect_repository`)

Ab v0.18.0 setzt das Modul am Repo des Projekts (`azuredevops_git_permissions`) Deny für die Gruppe Contributors des Projekts und für `<Projekt> Build Service (<Organisation>)`, das Job-Token der Pipelines im Projekt:

| Recht | Name im Provider | Warum |
| --- | --- | --- |
| Create tag | `CreateTag` | Ein Tag `v…` im Projekt-Repo passte zur Branch-Prüfung der Service Connection und käme ohne Review und ohne Freigabe an die Deployment-Identität. |
| Force push | `ForcePush` | Verlauf umschreiben, Branches und Tags löschen. |
| Bypass policies when pushing | `PolicyExempt` | Direkter Push auf `main` an PR-Validierung und Reviewern vorbei. |
| Bypass policies when completing pull requests | `PullRequestBypassPolicy` | Merge ohne Review. |
| Edit policies | `EditPolicies` | Reviewer-Pflicht und PR-Validierung abschalten. |

Die übrigen Einträge am Repo bleiben (`replace = false`); Project Administrators betrifft die Einschränkung nicht, es sei denn, sie sind zugleich Contributors: Ein Deny gilt dann auch für sie. Wer einen Branch anlegt, bekommt von Azure DevOps an diesem eigene Rechte, etwa Force push; das bleibt für eigene PR-Branches möglich. Das Modul legt die Rechte erst nach Dateien und Policies an. `protect_repository = false` lässt die Projekt-Defaults stehen, wie bis v0.17.0. Ein Projekt, dessen Pipelines nicht auf das eigene Projekt beschränkt sind („Limit job authorization scope to current project“ aus), läuft als `Project Collection Build Service (<Organisation>)`; diese Identität erfasst das Modul nicht, die Onboarding-Skripte aus seed-pipelines verbieten ihr Create tag.

Die anlegende Identität braucht dafür am Repo „Manage permissions“, und sie muss Gruppen und Identitäten lesen dürfen. Beim PAT von `seed-scaffold` heißt das zusätzlich die Scopes Security (Manage) und Identity (Read), neben Graph (Read) für die Gruppe. Das Job-Token des zentralen Scaffolds hat „Manage permissions“ nicht; dort `protect_repository = false` setzen und die Rechte projektweit über `Grant-SeedScaffoldAccess.ps1` vergeben, oder der Gruppe des Scaffolds das Recht bewusst geben.

**Branch-Prüfung der Service Connection:** Branch control an der Deployment-Service-Connection lässt nur `refs/heads/main` zu und, für die eingebundenen Templates von seed-pipelines, `refs/tags/v*`; nie `refs/tags/*` oder `*`. Weil auch `refs/tags/v*` Tags im Projekt-Repo trifft, gehört Create tag dort nur Administratoren.

Umstieg: Der erste Plan nach dem Update zeigt zwei neue Ressourcen `azuredevops_git_permissions.repository`, ohne Änderung an Repo, Pipeline oder Policies.

**Werte in `azure-pipelines.yml`:** Ab v0.18.0 prüft das Modul alle Werte, die es in die erzeugte Pipeline schreibt, damit ein Zeilenumbruch oder `: ` das YAML nicht umschreibt (etwa `confirmDataDeletion: true` setzen oder ein Repo ergänzen): `pipelines_version` ist ein Release-Tag (`vX.Y.Z`), `service_connection`, `github_connection` und `pool` bestehen aus Buchstaben, Ziffern, `.`, `_`, `-` und Leerzeichen, `environments` aus Kleinbuchstaben, Ziffern und `-`, `terraform_state` aus gültigen Namen für Resource Group, Storage Account und Container.

#### Selbstbedienung: Identität je Projekt (ab v0.20.0)

Zielbild: Jedes Seed-Projekt hat eine eigene Deployment-Identität, eine User-Assigned Managed Identity `id-<name>` hinter der Service Connection `sc-<name>` im Zielprojekt (Workload Identity Federation). Sie hat Rollen nur auf den Resource Groups `rg-<name>-<env>` und darf im State-Container nur unter dem Pfad `<name>/` schreiben. Was ein Projekt mit seiner Identität anrichten kann, bleibt so im Projekt. Das zentrale Scaffold ist ein Makler: Es führt nie Code der Person aus und berechtigt die Pipeline erst, wenn die Leitplanken stehen. Reihenfolge eines Laufs:

1. Prüfen: Eingaben, Zielprojekt, Mitgliedschaft der Person, Name frei; bei einem neuen Repo enthält `main` nur README, LICENSE oder `.gitignore`.
2. Identität in Azure: `id-<name>`, Resource Groups `rg-<name>-<env>`, Rollen darauf, Schreibrecht im State-Container nur für `<name>/`.
3. seed-template am Tag als ein Commit nach `main`; danach `project.yaml` und `azure-pipelines.yml` über dieses Modul.
4. Dieses Modul: Service Connection `sc-<name>` mit Branch-Prüfung und Required-Template-Check, Environments mit Freigaben, Reviewer-Policy (mindestens eine Person, die eigene Stimme zählt nicht), PR-Validierung, Rechte am Repo; `requester_can_approve = false`. Mit den Outputs `workload_identity_federation_issuer` und `workload_identity_federation_subject` legt der Aufrufer danach das Federated Credential an `id-<name>` an.
5. Verifizieren: `main` zeigt auf den Commit aus Schritt 3 und die Commits des Moduls, kein fremder Push dazwischen; sonst Abbruch.
6. Pipeline für `sc-<name>` und die Environments berechtigen, ersten Lauf starten.

Innerhalb des Moduls entsteht die eigene Service Connection erst nach Dateien, Branch-Policies und Rechten am Repo, und die Pipeline wird erst für sie berechtigt, wenn beide Checks daran stehen.

Neue Eingaben, alle optional; die Standardwerte entsprechen dem Verhalten bis v0.19.0:

| Variable | Typ, Standard | Wirkung |
| --- | --- | --- |
| `create_project` | `bool`, `false` | Projekt `ado_project` neu anlegen: privat, Git, Prozess wie Provider-Standard, nur Repos und Pipelines eingeschaltet. |
| `project_description` | `string`, `null` | Beschreibung des neuen Projekts. |
| `create_service_connection` | `bool`, `false` | Azure-Service-Connection `service_connection` selbst anlegen, Workload Identity Federation manuell (ohne Secret, ohne Prüfung beim Anlegen), mit Checks. `false`: eine vorhandene wie bisher. |
| `service_connection_identity` | `object({ tenant_id, subscription_id, subscription_name, client_id })`, `null` | Identität hinter der eigenen Service Connection; `client_id` der Managed Identity `id-<name>`. Mit `create_service_connection` Pflicht. |
| `required_template_repository` | `string`, `"blackforestsentinel/seed-pipelines"` | GitHub-Repo (Besitzer/Name), dessen `templates/web-app.yml` der Required-Template-Check verlangt; für Forks. |
| `contributors` | `list(string)`, `[]` | Principal Names, die Mitglied der Gruppe Contributors des Projekts werden. |
| `project_administrators` | `list(string)`, `[]` | Principal Names, die Mitglied der Gruppe Project Administrators werden (Warnung unten). |
| `create_resource_groups` | `bool`, `true` | `false` schreibt `createResourceGroups: false` in `project.yaml`: Die Resource Groups legt das Scaffold vorab an (Modul `core`, `create_resource_group`). |

Neue Ausgaben: `service_connection_id` (eigene oder vorhandene, sonst leer), `workload_identity_federation_issuer` und `workload_identity_federation_subject` (nur mit `create_service_connection`, sonst leer). `project_id` gibt es schon, mit `create_project` ist es die ID des neuen Projekts.

- **Neues Projekt:** Die anlegende Identität braucht in der Organisation „Create new projects“ und wird Projektadministrator des neuen Projekts. Dessen Standard-Repo ist leer, und unter „Protect access to repositories in YAML pipelines“ sieht ein Job-Token es nicht und kann es nicht befüllen. Das Scaffold legt das Repo deshalb nicht per Terraform an (`create_repository = false`): Die Person klickt in Repos auf „Initialize“, danach richtet ein weiterer Lauf mit demselben State alles ein. Das Modul löscht ein angelegtes Projekt nie (`prevent_destroy`); Beschreibung und Features pflegt danach das Projekt.
- **Checks an der eigenen Service Connection:** Branch control lässt `refs/heads/main` und `refs/tags/<pipelines_version>` zu: Die Prüfung vergleicht jedes Repo des Laufs mit derselben Liste, auch seed-pipelines, das die Pipeline am Tag einbindet. Ohne Prüfung des Branch-Schutzes, Timeout wie Provider-Standard. Required template verlangt `templates/web-app.yml` aus `required_template_repository` am Ref `refs/tags/<pipelines_version>`. Eine neue Version von seed-pipelines braucht deshalb einen weiteren Lauf des Moduls mit der neuen `pipelines_version`; bis dahin weisen beide Checks Läufe von `main` mit dem neuen Tag ab.
- **GitHub-Service-Connection:** bleibt eine vorhandene (`github_connection`); das zentrale Scaffold teilt sie aus seinem Projekt ins Zielprojekt, bevor das Modul läuft.
- **Mitglieder:** `contributors` und `project_administrators` kommen zu den Gruppen dazu; weitere Mitglieder bleiben. Die Konten müssen Mitglieder der Organisation sein, sonst bricht der Plan mit einer Meldung ab. **Vorsicht mit `project_administrators`:** Ein Projektadministrator kann Branch-Policies, Rechte am Repo, Checks und Freigaben seines Projekts aufheben, und damit unreviewten Code mit der Identität des Projekts ausführen. Standard ist deshalb niemand aus dem Team.
- **Reviewer und Freigaben:** `min_reviewers` bleibt standardmäßig `1`, die eigene Stimme zählt nicht (`submitter_can_vote = false`), neue Pushes setzen Zustimmungen zurück. `requester_can_approve` bleibt eine Variable mit Standard `true`; das zentrale Scaffold übergibt `false`.
- **State:** `web-app.yml` legt den State jedes Projekts unter `<project>/<env>.tfstate` ab. Die Identität des Projekts darf im State-Container nur Blobs unter `<name>/` schreiben; die Bedingung an der Rolle setzt, wer die Identität anlegt.
- **Grenzen der Identität:** Im Zielbild bearbeitet sie keine anderen Resource Groups, keine fremden States und App-Registrierungen und vergibt keine Rollen außerhalb der Seed-Rollen; das legen die Rollen fest, die der Aufrufer vergibt. Projekte mit Custom Connector brauchen den Anwendungsbenutzer in der Power-Platform-Umgebung für ihre eigene Identität (Onboarding in seed-pipelines).

Umstieg: Bestehende Aufrufe laufen unverändert weiter; der erste Plan nach dem Update zeigt keine Änderung.

#### MCP

Für den MCP-Server aus `Bfs.Seed.Mcp` (im Template `features.mcp`):

```hcl
module "sso" {
  # ...
  mcp               = true
  mcp_custom_domain = "mcp.example.org" # optional, für Claude nötig
}
```

| Was | Wozu |
| --- | --- |
| Scope `mcp_access` an der API | Gilt nur für `/api/mcp`. Ein Token, das ein MCP-Client bekommt, erreicht die übrige API nicht; Web-Tokens mit `access_as_user` erreichen den MCP-Endpunkt nicht. |
| Registrierung `<name>-<umgebung>-mcp` | Öffentlicher Client (Mobile und Desktop, PKCE, kein Secret) für Clients ohne eigene Entra-Registrierung. Redirect-URIs aus `mcp_redirect_uris`, Standard: Claude (`https://claude.ai/api/mcp/auth_callback`) und Claude Code (`http://localhost/callback`, `http://127.0.0.1/callback`; Entra ignoriert bei Loopback den Port). |
| Vorautorisierung | Dieser Client bekommt `mcp_access` ohne Einwilligungsdialog, nie `access_as_user`, und steht in den zugelassenen Clients. Andere Clients autorisiert das Modul nicht vor. |
| Application ID URI `https://<mcp_custom_domain>/api/mcp` | Nur mit `mcp_custom_domain`, dazu das App-Setting `Mcp__Resource`. |

Mit `existing_registration` legt das Modul für MCP nichts an: Scope `mcp_access`, Client-Registrierung und Vorautorisierung richtet der Admin im anderen Tenant von Hand ein ([Schritt 4](#vorhandene-app-registrierung-auch-aus-einem-anderen-tenant)). Die Client-ID des MCP-Clients gehört als `mcp_client_id` in `existing_registration` und kommt in die zugelassenen Clients. Ohne `mcp_client_id` bricht der Plan ab (Validierung von `mcp`). Bis v0.17.0 wies nur ein `check` darauf hin, und MCP ging ohne Liste zugelassener Clients live.

**Keine Clients von Microsoft:** Das Modul autorisiert nur die eigene MCP-Registrierung vor. Bis v0.17.0 war zusätzlich VS Code vorautorisiert (`aebc6443-996d-45c2-90f0-388ff96faa56`, die Registrierung von Microsoft), bis v0.18.1 ließ sich das über `mcp_preauthorized_client_ids` einschalten; ab v0.19.0 gibt es die Variable nicht mehr. Grund: Ein vorautorisierter öffentlicher Client von Microsoft lässt sich im Device-Code-Flow nutzen; `fallback_public_client_enabled = false` gilt nur für die eigene MCP-Registrierung. Ein Angreifer startet den Flow mit dessen Client-ID für `<api>/mcp_access`, schickt der Person den Code, und nach ihrer Anmeldung hat er ein Token und ein Refresh-Token in ihrem Namen, ohne Einwilligungsdialog. Dagegen hilft nur eine Regel für bedingten Zugriff im Tenant (Authentifizierungsflüsse → Gerätecodefluss blockieren), und die soll kein Projekt aus dem Baukasten voraussetzen müssen. Dasselbe gilt für `additional_allowed_client_ids`: dort keine öffentlichen Clients von Microsoft eintragen. Clients, die ein Client-Secret verlangen (Copilot Studio, Microsoft 365 Copilot), erreichen die API über den Custom Connector (`connector`), nicht über MCP.

Umstieg von v0.18.x: `mcp_preauthorized_client_ids` aus dem Modulaufruf entfernen. Der nächste Plan löscht die Vorautorisierung und den Eintrag in `Auth__AllowedClientIds`; danach lehnt die API Tokens aus VS Code ab. In `existing_registration` entfällt das Feld ebenso; eine Vorautorisierung, die der Admin im anderen Tenant eingetragen hat, nimmt er zurück.

**Warum eine eigene Domain für Claude:** Claude sendet die MCP-Adresse als `resource` (RFC 8707). Entra stellt nur dann ein Token aus, wenn diese Adresse eine Application ID URI der API ist, sonst kommt nach der Anmeldung `AADSTS9010010`. HTTPS-URIs nimmt Entra dort nur auf Domains an, die im Tenant verifiziert sind; `*.azurewebsites.net` scheidet aus. Die Domain muss deshalb vor dem Apply im Tenant verifiziert sein, sonst scheitert `azuread_application_identifier_uri.mcp`. DNS-Einträge, Hostname-Bindung und Zertifikat an der Function legt das Modul nicht an; die Schritte stehen in der README von seed-template.

**Nur zugelassene Clients:** `mcp_access` ist ein Scope vom Typ User, den jede App im Tenant mit Einwilligung bekommen kann. Die API nimmt Tokens aber nur von den [zugelassenen Clients](#zugelassene-clients) an, also den eigenen Registrierungen (bzw. denen aus `existing_registration`) und `additional_allowed_client_ids`; eine fremde App mit Einwilligung kommt damit nicht durch. Der Scope gilt nur für den MCP-Endpunkt, und was jemand dort darf, entscheiden die Capabilities der Werkzeuge. Bis v0.14.0 gab es keine solche Liste; die API nahm jedes Token mit ihrer Audience und `mcp_access` an, gleich von welchem Client.

**Einmal je Umgebung von Hand:** An `<name>-<umgebung>-mcp` die Administratorzustimmung erteilen (Entra Admin Center → App-Registrierungen → API-Berechtigungen). Sie deckt `offline_access` ab, also das Refresh-Token; ohne sie sehen Personen einen Einwilligungsdialog oder „Administratorgenehmigung erforderlich“. Die Pipeline-Identität könnte das nur mit `DelegatedPermissionGrant.ReadWrite.All`.

Ausgaben: `mcp_client_id` (in Claude „OAuth Client ID“, in Claude Code `--client-id`; bei `existing_registration` deren `mcp_client_id`), `mcp_resource` (MCP-Adresse auf der eigenen Domain, sonst `null`), `mcp_scope`. Mit `mcp = false` entsteht nichts davon, und bestehende Projekte sehen nach einem Update des Moduls keine Änderung. Abschalten entfernt Registrierung, Vorautorisierungen, URI und Scope; Entra verlangt, dass der Scope vorher deaktiviert wird, das erledigt der Provider.

#### Custom Connector

Für einen Custom Connector der Power Platform (im Template `features.customConnector`, Pipeline-Schritt in seed-pipelines):

```hcl
module "sso" {
  # ...
  connector = true
}
```

| Was | Warum |
| --- | --- |
| Registrierung `<name>-<umgebung>-connector` | Client, mit dem sich der Connector im Namen der angemeldeten Person anmeldet. Single-tenant, weil die Managed Identity des Connectors nur damit funktioniert. Kein Secret. |
| Vorautorisierung für `access_as_user` | Dieselbe Berechtigung wie das Frontend, ohne Einwilligungsdialog. Was eine Person über den Connector erreicht, regeln wie im Browser App-Rollen und Capabilities. |
| Pipeline als Besitzerin | Die Pipeline trägt nach dem Anlegen des Connectors die Redirect-URI (Plattform „Web“) und einen Federated Credential für die Managed Identity des Connectors ein; dafür reicht `Application.ReadWrite.OwnedBy`. Terraform ignoriert die Redirect-URIs (`ignore_changes`), Federated Credentials verwaltet es ohnehin nicht. |

**Warum Redirect-URI und Federated Credential nicht hier:** Beide enthalten einen Schlüssel, den die Power Platform aus Anzeigename, Publisher-Präfix und einer Endung der Power-Platform-Umgebung bildet. Die Endung steht in keinen Metadaten der Umgebung, erst der angelegte Connector kennt sie.

Mit `existing_registration` legt das Modul keinen Connector-Client an; der Admin richtet ihn im anderen Tenant von Hand ein und trägt seine Client-ID als `connector_client_id` in `existing_registration` ein, damit er in den zugelassenen Clients steht. Fehlt sie, weist ein `check` im Plan darauf hin. Ausgabe: `connector_client_id` (bei `existing_registration` `null`, die Pipeline ändert keine fremde Registrierung). Mit `connector = false` entsteht nichts, bestehende Projekte sehen nach einem Update keine Änderung.

### monitoring

Aktionsgruppe, Alarme und Budget je Umgebung, nur wenn es Empfänger gibt. Details, Kosten und Entscheidungen in [monitoring/README.md](monitoring/README.md).

```hcl
module "monitoring" {
  source = "git::https://github.com/blackforestsentinel/seed-terraform.git//monitoring?ref=<version>"
  count  = length(local.alert_emails) > 0 || (local.owner != null && local.owner != "") ? 1 : 0

  name                       = local.cfg.project
  environment                = var.environment
  owner                      = local.owner
  resource_group_name        = module.core.resource_group_name
  resource_group_id          = module.core.resource_group_id
  location                   = module.core.location
  application_insights_id    = module.core.application_insights_id
  log_analytics_workspace_id = module.core.log_analytics_workspace_id
  alert_emails               = local.alert_emails
  health_check_url           = "${module.core.function_app_url}/api/health"
  budget_amount              = 20
  key_vault_ids              = { for m in module.keyvault : "keyvault" => m.key_vault_id }
}
```

Mit `key_vault_ids` meldet das Modul, wenn ein Secret mit Ablaufdatum in 30 Tagen abläuft und wenn es abgelaufen ist (Event Grid mit dem Ziel „Azure Monitor alert“, ohne eigenen Code). Dafür muss der Ressourcenanbieter `Microsoft.EventGrid` registriert sein; Details in [monitoring/README.md](monitoring/README.md#ablauf-von-secrets).

Bis v0.12.0 rief ein Webtest den Health-Endpunkt alle 15 Minuten aus zwei Standorten auf. Seit v0.13.0 übernimmt das eine Logic App, standardmäßig alle 4 Stunden (`health_check_interval_hours`); `health_check_frequency` und `health_check_locations` entfallen. Beim Umstieg entfernt der Apply den Webtest und ersetzt den Alarm `alert-…-health` durch `alert-…-health-check`.

### storage

Eigener Storage Account für die Daten des Projekts, getrennt vom Host-Storage aus `core`: ohne Shared Key, TLS 1.2, ohne öffentlichen Blob-Zugriff; Tabellen, Queues und Container aus `project.yaml`; Versionierung und Soft Delete als Standard, Lifecycle-Regeln für Löschfristen. Die Managed Identity der Function bekommt Blob, Queue und Table Data Contributor; optional bekommt eine weitere Identität (`extension_publisher_principal_id`, meist die Deployment-Identität) Blob Data Contributor nur auf dem Container `extension`, für eine selbst gehostete Browser-Erweiterung. Der Output `app_settings` beschreibt die identitätsbasierte Verbindung `SeedStorage` (Endpunkte, `credential = managedidentity`, Client-ID), die Queue-Trigger und `Bfs.Seed.Storage` nutzen.

```hcl
module "storage" {
  source = "git::https://github.com/blackforestsentinel/seed-terraform.git//storage?ref=<version>"
  count  = local.cfg.features.storage ? 1 : 0

  name                           = local.cfg.project
  environment                    = var.environment
  resource_group_name            = module.core.resource_group_name
  location                       = module.core.location
  function_identity_principal_id = module.core.function_identity_principal_id
  function_identity_client_id    = module.core.function_identity_client_id
  tables                         = ["jobs"]
  queues                         = ["jobs"]
}
```

Details zu Aufbewahrung, Rollen, Poison-Queue und zum Entfernen von Tabellen: [storage/README.md](storage/README.md).

## Entwickeln

```bash
terraform fmt -recursive
terraform -chdir=examples/core init -backend=false
terraform -chdir=examples/core validate
terraform -chdir=examples/sso init -backend=false
terraform -chdir=examples/sso validate
terraform -chdir=examples/api-only init -backend=false
terraform -chdir=examples/api-only validate
terraform -chdir=examples/sso-roles init -backend=false
terraform -chdir=examples/sso-roles validate
terraform -chdir=examples/sso-existing init -backend=false
terraform -chdir=examples/sso-existing validate
terraform -chdir=examples/mcp init -backend=false
terraform -chdir=examples/mcp validate
terraform -chdir=examples/custom-connector init -backend=false
terraform -chdir=examples/custom-connector validate
terraform -chdir=examples/monitoring init -backend=false
terraform -chdir=examples/monitoring validate
terraform -chdir=examples/keyvault init -backend=false
terraform -chdir=examples/keyvault validate
terraform -chdir=examples/storage init -backend=false
terraform -chdir=examples/storage validate
terraform -chdir=examples/ado-project init -backend=false
terraform -chdir=examples/ado-project validate
```

Module mit Tests (`<modul>/tests/*.tftest.hcl`) laufen gegen einen Mock der Provider, ohne Tenant und ohne Rechte:

```bash
terraform -chdir=core init -backend=false
terraform -chdir=core test
terraform -chdir=keyvault init -backend=false
terraform -chdir=keyvault test
terraform -chdir=sso init -backend=false
terraform -chdir=sso test
terraform -chdir=monitoring init -backend=false
terraform -chdir=monitoring test
terraform -chdir=storage init -backend=false
terraform -chdir=storage test
terraform -chdir=ado-project init -backend=false
terraform -chdir=ado-project test
```

## Lizenz

MIT, siehe [LICENSE](LICENSE).
