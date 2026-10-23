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
| `core` | Resource Group, Static Web App (Free oder Standard, mit eigenen Domains; entfällt bei Projekten ohne Frontend), Function App (Flex Consumption, .NET 10), Application Insights ohne lokale Authentifizierung mit Log Analytics (Tageslimit), Host-Storage mit Managed Identity | Phase 1 |
| `sso` | App-Registrierungen für API und SPA (ohne Frontend nur API), delegierte Berechtigung `access_as_user`, SPA vorab autorisiert, App-Rollen, Bridge-Seite für die stille Anmeldung; alternativ eine vorhandene Registrierung, auch aus einem anderen Tenant; mit `mcp` Scope `mcp_access` und Client-Registrierung für MCP-Clients; mit `connector` Client-Registrierung für einen Power-Platform-Custom-Connector (ohne Secret); mit `directory` delegierte Graph-Berechtigungen für die Personen-Komponenten im Frontend | Phase 2 |
| `monitoring` | Aktionsgruppe, Alarme (Exceptions, Health-Check alle 4 Stunden per Logic App, Tageslimit für Logs) und Budget je Resource Group; nur mit Empfängern | Baustein 5 |
| [`keyvault`](keyvault/README.md) | Key Vault je Projekt und Umgebung (RBAC, Purge-Schutz), Platzhalter-Secrets, Key-Vault-Referenzen als App-Settings `Secrets__<Name>`, auf Wunsch Audit-Log in den Workspace aus `core` | Baustein 2 |
| `storage` | Eigener Storage Account für Daten: Tabellen, Queues, Container, Versionierung, Soft Delete, Lifecycle-Regeln, Datenrollen für die Function, optional Schreibrecht auf den Container `extension` für eine selbst gehostete Browser-Erweiterung; Verbindung `SeedStorage` als App-Settings | Baustein 1 |
| `ado-project` | Seed-Projekt in Azure DevOps: Repo aus dem Template oder ein vorhandenes Repo, Environments mit Freigaben, Pipeline, Branch-Policies für PR-Validierung und Reviewer (für `seed-scaffold`); `frontend = false` legt ein Projekt ohne Frontend an | Phase 3 |

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

Wichtige Eingaben: `name`, `environment`, `location` (Default `westeurope`), `static_web_app_sku` (`Free`, `Standard` oder `None`; Azure erlaubt höchstens 10 Free-SWAs je Subscription), `custom_domains` (eigene Domains der Static Web App), `app_settings` (zusätzliche App-Settings, z. B. aus dem sso-Modul), `cors_allowed_origins`, `log_daily_quota_gb` (Tageslimit für Logs, Default 1 GB), `maximum_instance_count` (Obergrenze der Instanzen, 1 bis 1000, Default 40; `null` gilt als Default).

Wichtige Ausgaben: `function_app_name`, `function_app_url`, `static_web_app_name`, `static_web_app_url`, `custom_domain_dns_records`, `function_identity_principal_id`; für das Modul monitoring `resource_group_id`, `application_insights_id` und `log_analytics_workspace_id`.

Konvention: Das Modul setzt die App-Settings `Seed__Project` und `Seed__Environment`, die `Bfs.Seed.Functions.Core` ausliest. Seine Grundeinstellungen (`AzureWebJobsStorage__*`, `APPLICATIONINSIGHTS_*`, `AZURE_CLIENT_ID`, `Seed__Project`, `Seed__Environment`) gehen gleichnamigen Einträgen aus `app_settings` vor; bis v0.6.0 war es umgekehrt.

Key-Vault-Referenzen (`@Microsoft.KeyVault(...)`) in `app_settings` löst die Plattform mit der UAMI der Function auf (`keyVaultReferenceIdentity`); die Leserechte vergibt das Modul [`keyvault`](keyvault/README.md). Ab dieser Version zeigt der erste Plan nach dem Update dafür einmal eine Änderung an der Function App.

CORS: Die Function lässt die Standard-URL der Static Web App, alle eigenen Domains und `cors_allowed_origins` zu.

#### Telemetrie ohne Schlüssel

Application Insights nimmt nur Telemetrie mit Entra-Token an (`local_authentication_enabled = false`). Wer den Connection String kennt, kann damit keine Telemetrie einschleusen. Die Function sendet per User-Assigned Managed Identity: Das Modul gibt ihr die Rolle `Monitoring Metrics Publisher` auf Application Insights und setzt `APPLICATIONINSIGHTS_AUTHENTICATION_STRING` (`Authorization=AAD;ClientId=<client-id>`). Diese Einstellung lesen der Functions-Host und im Worker `ConfigureFunctionsApplicationInsights()` aus `Microsoft.Azure.Functions.Worker.ApplicationInsights`, das `AddSeedCore()` aus `Bfs.Seed.Functions.Core` aufruft. Am Code ändert sich dafür nichts.

Der Log Analytics Workspace hat ein Tageslimit (`log_daily_quota_gb`, Default 1 GB, `-1` ohne Limit). Ist es erreicht, nimmt er bis 0 Uhr UTC nichts mehr an; das Modul monitoring meldet das.

Die ausführende Identität vergibt dafür eine weitere Rolle: Die Bedingung an `Role Based Access Control Administrator` muss `Monitoring Metrics Publisher` (`3913510d-42f4-4e42-8a64-420c390055eb`) erlauben.

Umstieg bestehender Projekte (vor dieser Version):

- Der Apply ändert Application Insights und den Workspace an Ort und Stelle; nichts wird neu angelegt, die Daten bleiben.
- Er legt die Rolle an und setzt das App-Setting. Die Function startet dadurch neu und sendet danach per Managed Identity, Host wie Worker. Ein neuer Deploy oder ein Paket-Update ist nicht nötig; alle bisherigen Versionen von `Bfs.Seed.Functions.Core` bringen `Microsoft.Azure.Functions.Worker.ApplicationInsights` 2.50 mit, das die Einstellung auswertet.
- Terraform schaltet die lokale Authentifizierung ab, bevor die Function das neue App-Setting hat. Telemetrie aus dieser Zeitspanne und dem Neustart geht verloren, im Test rund eine Minute. Danach ist sie vollständig. Wer das vermeiden will, wendet die Änderung in einer ruhigen Zeit an.

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

Eigene Domains gehören als `https://<domain>` mit in `spa_redirect_uris`. Ohne Redirect-URIs (Projekt ohne Frontend, `spa_redirect_uris` weglassen oder leer) entsteht nur die API-Registrierung: keine SPA, kein Service Principal dafür, keine Vorab-Autorisierung. Ab v0.5.0 liegen die SPA-Ressourcen deshalb unter `[0]`; `moved`-Blöcke verschieben bestehende States ohne Änderung an den Registrierungen. Ab v0.6.0 liegen auch die API-Ressourcen unter `[0]`, weil eine vorhandene Registrierung an ihre Stelle treten kann; `moved`-Blöcke verschieben bestehende States, der Plan verschiebt dann nur.

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

Ausgaben: `app_settings` (`Auth__TenantId`, `Auth__ClientId`, `Auth__Audience` für `Bfs.Seed.Auth`, bei einer anderen Berechtigung als `access_as_user` zusätzlich `Auth__RequiredScope`), `frontend_config` (Auth-Teil der `config.json` für `@blackforestsentinel/seed-web-auth`, ohne SPA leer), dazu `api_client_id`, `api_scope`, `api_scope_id`, `spa_client_id` (ohne SPA `null`), `spa_redirect_uris`, `app_roles` und `directory_permissions`.

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

`assignment_required = true` setzt „Zuweisung erforderlich“ am Service Principal der API: Ein Token für die API bekommen dann nur Personen, Gruppen und Anwendungen mit einer Rolle; alle anderen scheitern schon bei der Anmeldung (AADSTS50105). Default ist `false`, dann kann sich jedes Konto des Tenants anmelden und bekommt ohne Rolle nur keine Capabilities.

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
  }
}
```

Dann legt das Modul nichts an und braucht keine Graph-Rechte im fremden Tenant. Es reicht Tenant, Client-IDs und Berechtigung als `app_settings` und `frontend_config` weiter; die API prüft Tokens gegen den angegebenen Tenant, das Frontend meldet sich dort an. Heißt die Berechtigung nicht `access_as_user`, setzt es `Auth__RequiredScope`. v1- und v2-Tokens akzeptiert `Bfs.Seed.Auth` beide. War die Registrierung bisher angelegt, entfernt der nächste Apply die eigenen Registrierungen.

Was der Admin im anderen Tenant einrichtet:

1. **SPA-Registrierung** (Plattform „Single-Page-Anwendung“) mit den Redirect-URIs aus der Ausgabe `spa_redirect_uris`: URL der Static Web App mit abschließendem Schrägstrich, eigene Domains, mit Bridge-Seite zusätzlich `<origin>/redirect.html` je Origin, in `dev` `http://localhost:5173/`, dazu `spa_extra_redirect_uris`. Die URL der Static Web App steht erst nach dem ersten Apply fest.
2. **API-Registrierung** mit Application ID URI (`audience`) und einer delegierten Berechtigung (`api_scope`).
3. **Vorautorisierung:** die SPA unter „Eine API verfügbar machen“ als autorisierte Clientanwendung für die Berechtigung eintragen. Alternativ erteilt der Admin die Einwilligung für die SPA.
4. **App-Rollen** an der API-Registrierung gemäß `auth.roles` bzw. Ausgabe `app_roles`: Wert gleich Rollenname, zulässige Mitgliedstypen wie angegeben. Die IDs dürfen abweichen, entscheidend ist der Wert.
5. **Zuweisungen** von Personen und Gruppen zu den Rollen, bei Bedarf „Zuweisung erforderlich“ an der Enterprise App der API.
6. **Mit `directory`:** die Graph-Berechtigungen an der SPA-Registrierung und die Zustimmung, siehe [Personen und Profilbilder](#personen-und-profilbilder-microsoft-graph).

#### Personen und Profilbilder (Microsoft Graph)

Für die Personen-Komponenten aus `@blackforestsentinel/seed-web-people` (im Template `auth.directory`): Profilbilder, Profile, Personensuche und Teams-Status lädt das Frontend mit dem Token der angemeldeten Person direkt aus Microsoft Graph. Die API ist nicht beteiligt, es gibt keine Anwendungsberechtigung und keinen Token-Tausch.

```hcl
module "sso" {
  # ...
  directory = {
    enabled     = true  # Fotos, Profile, Suche
    presence    = true  # Teams-Status
    role_filter = false # Personenauswahl nur mit App-Rolle, braucht Administratorzustimmung
  }
}
```

Das Modul trägt an der SPA-Registrierung `<name>-<umgebung>-web` delegierte Berechtigungen für Microsoft Graph ein und schreibt die Scopes als `directory` in `frontend_config.auth`. `enabled` ist der Hauptschalter: `presence` und `role_filter` wirken nur mit ihm, `enabled = false` schaltet alles ab, etwa je Umgebung.

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

Die IDs sind in allen Tenants gleich; das Modul nutzt sie fest wie bei `offline_access` in `mcp.tf`, weil die Pipeline mit `Application.ReadWrite.OwnedBy` den Service Principal von Graph nicht zwingend lesen darf. Delegiert heißt: Das Frontend sieht nur, was die angemeldete Person auch in Outlook und Teams sieht, und die Einstellungen des Tenants (etwa ausgeblendete Fotos) gelten weiter.

**Zustimmung, von Hand:** Das Modul erteilt keine Einwilligung; die Pipeline-Identität könnte das nur mit `DelegatedPermissionGrant.ReadWrite.All`. Nach dem Apply gibt es zwei Wege:

- **Administratorzustimmung (empfohlen):** Entra Admin Center → App-Registrierungen → `<name>-<umgebung>-web` → API-Berechtigungen → „Administratorzustimmung für &lt;Tenant&gt; erteilen“, oder `az ad app permission admin-consent --id <spa_client_id>` als Admin. Einmal je Registrierung, also je Projekt und Umgebung; sie gilt für alle Personen. Mit `role_filter` ist sie Pflicht, weil die beiden Berechtigungen vom Typ Admin sind.
- **Personen stimmen selbst zu:** Berechtigungen vom Typ User dürfen Personen beim ersten Aufruf selbst erteilen, aber nur, soweit die Einwilligungseinstellungen des Tenants es zulassen (Unternehmensanwendungen → Einwilligung und Berechtigungen). Mit der von Microsoft empfohlenen Einstellung gilt das nur für Berechtigungen, die als „geringes Risiko“ eingestuft sind, oft nur `openid`, `profile`, `email`, `offline_access` und `User.Read`. `User.ReadBasic.All`, `People.Read` und `Presence.Read.All` brauchen dann trotzdem die Administratorzustimmung, oder der Admin stuft sie unter „Berechtigungsklassifizierungen“ als geringes Risiko ein; das gilt dann für alle Apps im Tenant.

Eine Zustimmung deckt die Berechtigungen ab, die beim Klick eingetragen waren. Kommt `presence` oder `role_filter` später dazu, erneut zustimmen. Abschalten entfernt die Berechtigungen aus der Registrierung; eine erteilte Zustimmung bleibt bestehen, bis ein Admin sie an der Enterprise App unter „Berechtigungen“ widerruft.

**Mit `existing_registration`** legt das Modul nichts an; `frontend_config` bekommt `directory` trotzdem, `apiClientId` ist dann `api_client_id`. Der Admin des anderen Tenants trägt an seiner SPA-Registrierung (`spa_client_id`, bei einer gemeinsamen Registrierung für SPA und API dieselbe) unter API-Berechtigungen → Berechtigung hinzufügen → Microsoft Graph → Delegierte Berechtigungen die Berechtigungen aus der Tabelle ein und erteilt die Administratorzustimmung wie oben. Die Ausgabe `directory_permissions` nennt Tenant, Client-ID, Berechtigungen mit ID und den Befehl.

Ausgabe `directory_permissions`: `tenant_id`, `spa_client_id`, `permissions` (je Berechtigung `value`, `id` und `admin_consent`), `admin_consent_required` (mit `role_filter`) und `admin_consent_command`; `null` ohne `directory` oder ohne Frontend. Ohne `directory` ändert sich an Registrierungen und Ausgaben nichts.

### ado-project

Legt für die Pipeline `seed-scaffold` ein Seed-Projekt in Azure DevOps an; Ablauf und Parameter beschreibt [seed-pipelines](https://github.com/blackforestsentinel/seed-pipelines).

PR-Validierung (`pr_validation`, Standard `true`): eine Branch-Policy auf `main`, nach der Pull Requests einen erfolgreichen Lauf der Projekt-Pipeline brauchen. Die Pipeline erkennt PR-Läufe selbst und baut, testet und sucht dann nur nach Secrets, ohne Deploy und ohne Service Connection; eine zweite Pipeline-Definition ist nicht nötig. Ein Ergebnis gilt 12 Stunden, auch wenn sich `main` ändert. Die Policy ist Pflicht und sperrt damit direkte Pushes auf `main`; sie entsteht deshalb erst nach den Dateien, die das Modul direkt auf `main` schreibt.

Voraussetzungen: `pipelines_version` ab v0.5.0, denn ältere Versionen von seed-pipelines deployen auch in PR-Läufen (das Modul bricht dann mit einer Meldung ab). Die anlegende Identität braucht am Repo die Berechtigung „Edit policies“; beim PAT von `seed-scaffold` genügt dafür der Scope Code (Read, write & manage).

Für ein zentrales Scaffold, das Seed-Projekte in anderen Azure-DevOps-Projekten anlegt (seed-pipelines, Selbstbedienung):

- **`create_repository = false`:** Das Modul nutzt das vorhandene Repo `repository` (leer: `name`) und schreibt nur `project.yaml` und `azure-pipelines.yml`. Grund: Das Job-Token des zentralen Projekts darf unter „Protect access to repositories in YAML pipelines“ keine Repos anlegen. Die Person legt das Repo an, die Pipeline führt seed-template vorher ein.
- **`approver_groups`:** Gruppen der Organisation, deren Mitglieder zusätzlich zu `approvers` freigeben.
- **`requester_can_approve`** (Standard `true`): im zentralen Scaffold `false`, damit niemand die eigene Infrastruktur allein freigibt.
- **`min_reviewers`** (Standard `0`): Pflicht-Reviewer auf `main`, die eigene Stimme zählt nicht. Die Stage Plan nutzt die Service Connection schon vor jeder Freigabe; ohne Review könnte eine Person ihre eigene Pipeline-Änderung mergen und so die Rechte der Deployment-Identität nutzen.
- **`pool`:** Agent-Pool der Projekt-Pipeline, ab `pipelines_version` v0.13.0; das Modul berechtigt die Pipeline für dessen Queue, sonst fragte der erste Lauf danach („Permit“).
- **Output `project_id`:** startet den ersten Lauf im anderen Projekt.

Bis v0.13.0 legte das Modul das Repo immer an; ein `moved`-Block übernimmt es in bestehenden States.

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
| Vorautorisierung | Dieser Client und `mcp_preauthorized_client_ids` (Standard: VS Code, `aebc6443-996d-45c2-90f0-388ff96faa56`) bekommen `mcp_access` ohne Einwilligungsdialog, nie `access_as_user`. |
| Application ID URI `https://<mcp_custom_domain>/api/mcp` | Nur mit `mcp_custom_domain`, dazu das App-Setting `Mcp__Resource`. |

Mit `existing_registration` legt das Modul für MCP nichts an: Scope `mcp_access`, Client-Registrierung und Vorautorisierung richtet der Admin im anderen Tenant von Hand ein. Ein `check` weist im Plan darauf hin.

**Warum eine eigene Domain für Claude:** Claude sendet die MCP-Adresse als `resource` (RFC 8707). Entra stellt nur dann ein Token aus, wenn diese Adresse eine Application ID URI der API ist, sonst kommt nach der Anmeldung `AADSTS9010010`. HTTPS-URIs nimmt Entra dort nur auf Domains an, die im Tenant verifiziert sind; `*.azurewebsites.net` scheidet aus. Die Domain muss deshalb vor dem Apply im Tenant verifiziert sein, sonst scheitert `azuread_application_identifier_uri.mcp`. DNS-Einträge, Hostname-Bindung und Zertifikat an der Function legt das Modul nicht an; die Schritte stehen in der README von seed-template. VS Code meldet sich mit seiner eigenen Registrierung ohne `resource` an und kommt ohne eigene Domain aus.

**Keine Allowlist der Clients:** Die API nimmt jedes Token mit ihrer Audience und `mcp_access` an, gleich von welchem Client. `mcp_access` ist ein Scope vom Typ User, den jede App im Tenant mit Einwilligung bekommen kann; deshalb gilt er nur für den MCP-Endpunkt, und was jemand dort darf, entscheiden die Capabilities der Werkzeuge.

**Einmal je Umgebung von Hand:** An `<name>-<umgebung>-mcp` die Administratorzustimmung erteilen (Entra Admin Center → App-Registrierungen → API-Berechtigungen). Sie deckt `offline_access` ab, also das Refresh-Token; ohne sie sehen Personen einen Einwilligungsdialog oder „Administratorgenehmigung erforderlich“. Die Pipeline-Identität könnte das nur mit `DelegatedPermissionGrant.ReadWrite.All`.

Ausgaben: `mcp_client_id` (in Claude „OAuth Client ID“, in Claude Code `--client-id`), `mcp_resource` (MCP-Adresse auf der eigenen Domain, sonst `null`), `mcp_scope`. Mit `mcp = false` entsteht nichts davon, und bestehende Projekte sehen nach einem Update des Moduls keine Änderung. Abschalten entfernt Registrierung, Vorautorisierungen, URI und Scope; Entra verlangt, dass der Scope vorher deaktiviert wird, das erledigt der Provider.

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

Mit `existing_registration` legt das Modul keinen Connector-Client an; der Admin richtet ihn im anderen Tenant von Hand ein, ein `check` weist im Plan darauf hin. Ausgabe: `connector_client_id`. Mit `connector = false` entsteht nichts, bestehende Projekte sehen nach einem Update keine Änderung.

### monitoring

Aktionsgruppe, Alarme und Budget je Umgebung, nur wenn es Empfänger gibt. Details, Kosten und Entscheidungen in [monitoring/README.md](monitoring/README.md).

```hcl
module "monitoring" {
  source = "git::https://github.com/blackforestsentinel/seed-terraform.git//monitoring?ref=<version>"
  count  = length(local.alert_emails) > 0 ? 1 : 0

  name                       = local.cfg.project
  environment                = var.environment
  resource_group_name        = module.core.resource_group_name
  resource_group_id          = module.core.resource_group_id
  location                   = module.core.location
  application_insights_id    = module.core.application_insights_id
  log_analytics_workspace_id = module.core.log_analytics_workspace_id
  alert_emails               = local.alert_emails
  health_check_url           = "${module.core.function_app_url}/api/health"
  budget_amount              = 20
}
```

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
