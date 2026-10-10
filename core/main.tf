data "azurerm_client_config" "current" {}

locals {
  base = "${var.name}-${var.environment}"

  # Stabiles Kürzel für global eindeutige Namen (Function App, Storage Account),
  # schon beim Plan bekannt und je Subscription, Projekt und Umgebung verschieden.
  suffix = substr(sha256("${data.azurerm_client_config.current.subscription_id}/${local.base}"), 0, 6)

  storage_account_name = "st${substr(replace(local.base, "-", ""), 0, 16)}${local.suffix}"
  function_app_name    = "func-${local.base}-${local.suffix}"

  # Ohne Frontend (static_web_app_sku = None) entsteht keine Static Web App.
  static_web_app = var.static_web_app_sku != "None"
  custom_domains = toset(var.custom_domains)

  tags = merge(
    {
      "seed:project"     = var.name
      "seed:environment" = var.environment
      "seed:module"      = "core"
    },
    var.tags,
  )
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.base}"
  location = var.location
  tags     = local.tags
}

# --- Monitoring ---------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${local.base}"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  # Schutz vor Ausreißern wie einer Log-Schleife. Ist das Limit erreicht, nimmt der Workspace
  # bis zum nächsten Tag (UTC) nichts mehr an; das Modul monitoring meldet das.
  daily_quota_gb = var.log_daily_quota_gb
  tags           = local.tags
}

resource "azurerm_application_insights" "this" {
  name                = "appi-${local.base}"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "web"
  # Nur Telemetrie mit Entra-Token: Host und Worker senden per Managed Identity
  # (APPLICATIONINSIGHTS_AUTHENTICATION_STRING). Wer nur den Connection String kennt,
  # kann damit keine Telemetrie einschleusen.
  local_authentication_enabled = false
  tags                         = local.tags
}

resource "azurerm_role_assignment" "app_insights_publisher" {
  scope                = azurerm_application_insights.this.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_user_assigned_identity.function.principal_id
  principal_type       = "ServicePrincipal"
}

# --- Host-Storage der Function (nur Managed Identity, keine Schlüssel) ---------

resource "azurerm_storage_account" "host" {
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.this.name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  tags                            = local.tags
}

resource "azurerm_storage_container" "deployment" {
  name                  = "app-package"
  storage_account_id    = azurerm_storage_account.host.id
  container_access_type = "private"
}

resource "azurerm_user_assigned_identity" "function" {
  name                = "id-${local.base}"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "host_storage" {
  for_each = toset([
    "Storage Blob Data Owner",
    "Storage Queue Data Contributor",
    "Storage Table Data Contributor",
  ])

  scope                = azurerm_storage_account.host.id
  role_definition_name = each.value
  principal_id         = azurerm_user_assigned_identity.function.principal_id
  principal_type       = "ServicePrincipal"
}

# --- Function App (Flex Consumption) -----------------------------------------

resource "azurerm_service_plan" "this" {
  name                = "asp-${local.base}"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = local.tags
}

# azapi statt azurerm_function_app_flex_consumption: Die azurerm-Ressource setzt bei
# Managed-Identity-Storage einen AzureWebJobsStorage-Connection-String ohne Schlüssel
# (hashicorp/terraform-provider-azurerm#29149, #29993, #33211).
resource "azapi_resource" "function_app" {
  type      = "Microsoft.Web/sites@2024-11-01"
  name      = local.function_app_name
  parent_id = azurerm_resource_group.this.id
  location  = var.location
  tags      = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.function.id]
  }

  body = {
    kind = "functionapp,linux"
    properties = {
      # Azure liefert die ID mit "serverfarms" zurück; ohne Angleichen zeigt jeder Plan Drift.
      serverFarmId = replace(azurerm_service_plan.this.id, "Microsoft.Web/serverFarms", "Microsoft.Web/serverfarms")
      httpsOnly    = true

      # Key-Vault-Referenzen in den App-Settings (Modul keyvault) löst die Plattform mit der UAMI
      # auf; ohne Angabe nähme sie die System-Identität, die es hier nicht gibt.
      keyVaultReferenceIdentity = azurerm_user_assigned_identity.function.id

      functionAppConfig = {
        deployment = {
          storage = {
            type  = "blobContainer"
            value = "${azurerm_storage_account.host.primary_blob_endpoint}${azurerm_storage_container.deployment.name}"
            authentication = {
              type                           = "UserAssignedIdentity"
              userAssignedIdentityResourceId = azurerm_user_assigned_identity.function.id
            }
          }
        }
        scaleAndConcurrency = {
          maximumInstanceCount = var.maximum_instance_count
          instanceMemoryMB     = var.instance_memory_mb
        }
        runtime = {
          name    = "dotnet-isolated"
          version = var.runtime_version
        }
      }

      siteConfig = {
        minTlsVersion = "1.2"
        ftpsState     = "Disabled"
        # Frontend unter der Standard-URL und den eigenen Domains; ohne Static Web App nur
        # die zusätzlichen Origins.
        cors = {
          allowedOrigins = concat(
            [for host in azurerm_static_web_app.this[*].default_host_name : "https://${host}"],
            [for domain in local.custom_domains : "https://${domain}"],
            var.cors_allowed_origins,
          )
          supportCredentials = false
        }
        # Die Grundeinstellungen stehen zuletzt und gehen damit vor: Ein gleichnamiges Setting aus
        # app_settings, etwa aus project.yaml eines Projekts, kann Host-Storage, Telemetrie und
        # Identität nicht verbiegen.
        appSettings = [
          for k, v in merge(
            var.app_settings,
            {
              AzureWebJobsStorage__accountName      = azurerm_storage_account.host.name
              AzureWebJobsStorage__credential       = "managedidentity"
              AzureWebJobsStorage__clientId         = azurerm_user_assigned_identity.function.client_id
              APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.this.connection_string
              AZURE_CLIENT_ID                       = azurerm_user_assigned_identity.function.client_id
              Seed__Project                         = var.name
              Seed__Environment                     = var.environment
              # Telemetrie per Managed Identity. Liest der Host und, über
              # ConfigureFunctionsApplicationInsights(), auch der Worker.
              APPLICATIONINSIGHTS_AUTHENTICATION_STRING = "Authorization=AAD;ClientId=${azurerm_user_assigned_identity.function.client_id}"
            },
          ) : { name = k, value = v }
        ]
      }
    }
  }

  response_export_values = ["properties.defaultHostName"]

  # Ohne die Rollen startet der Host nicht, weil er seinen Storage nicht erreicht. Die
  # Telemetrie-Rolle soll stehen, bevor die App per Entra-Token sendet.
  depends_on = [azurerm_role_assignment.host_storage, azurerm_role_assignment.app_insights_publisher]
}

# --- Static Web App -----------------------------------------------------------

resource "azurerm_static_web_app" "this" {
  count = local.static_web_app ? 1 : 0

  name                = "swa-${local.base}"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.static_web_app_location
  sku_tier            = var.static_web_app_sku
  sku_size            = var.static_web_app_sku
  tags                = local.tags

  # Der Deploy-Task der Pipeline trägt das Repository ein; das ist kein Drift.
  lifecycle {
    ignore_changes = [repository_branch, repository_url]
  }
}

# Bis v0.4.0 ohne count. Die Verschiebung ändert nur den State, nicht die Ressource;
# die Pipeline verlangt dafür keine Freigabe.
moved {
  from = azurerm_static_web_app.this
  to   = azurerm_static_web_app.this[0]
}

# --- Eigene Domains -----------------------------------------------------------

# Validierung per TXT-Eintrag: Terraform wartet nur auf das Token, nicht auf das DNS. Der
# Apply läuft also auch durch, wenn der Eintrag erst danach gesetzt wird (DNS liegt meist
# außerhalb von Azure); Azure prüft ihn dann selbst. cname-delegation dagegen wartet im
# Apply auf einen schon gesetzten CNAME (bis 30 Minuten, dann Fehler) und geht nicht für
# Apex-Domains.
resource "azurerm_static_web_app_custom_domain" "this" {
  for_each = local.custom_domains

  static_web_app_id = azurerm_static_web_app.this[0].id
  domain_name       = each.value
  validation_type   = "dns-txt-token"
}

# Azure leert das Token, sobald die Domain validiert ist. Ohne Festhalten änderte sich danach
# der Output, und der nächste Plan verlangte eine Freigabe ohne echte Änderung. Das Token
# steht ohnehin öffentlich im DNS und ist kein Geheimnis.
resource "terraform_data" "custom_domain_token" {
  for_each = local.custom_domains

  input = nonsensitive(azurerm_static_web_app_custom_domain.this[each.key].validation_token)

  lifecycle {
    ignore_changes       = [input]
    replace_triggered_by = [azurerm_static_web_app_custom_domain.this[each.key]]
  }
}

# Basic Auth (Benutzername/Passwort) für SCM und FTP ausdrücklich aus, unabhängig vom
# Azure-Default. Deployments laufen über Entra ID.
resource "azapi_update_resource" "basic_auth_off" {
  for_each = toset(["scm", "ftp"])

  type      = "Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-11-01"
  name      = each.value
  parent_id = azapi_resource.function_app.id
  body = {
    properties = {
      allow = false
    }
  }
}
