data "azurerm_client_config" "current" {}

locals {
  base = "${var.name}-${var.environment}"

  # Stabiles Kürzel für global eindeutige Namen (Function App, Storage Account),
  # schon beim Plan bekannt und je Subscription, Projekt und Umgebung verschieden.
  suffix = substr(sha256("${data.azurerm_client_config.current.subscription_id}/${local.base}"), 0, 6)

  storage_account_name = "st${substr(replace(local.base, "-", ""), 0, 16)}${local.suffix}"
  function_app_name    = "func-${local.base}-${local.suffix}"

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
  tags                = local.tags
}

resource "azurerm_application_insights" "this" {
  name                = "appi-${local.base}"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "web"
  tags                = local.tags
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
        cors = {
          allowedOrigins     = concat(["https://${azurerm_static_web_app.this.default_host_name}"], var.cors_allowed_origins)
          supportCredentials = false
        }
        appSettings = [
          for k, v in merge(
            {
              AzureWebJobsStorage__accountName      = azurerm_storage_account.host.name
              AzureWebJobsStorage__credential       = "managedidentity"
              AzureWebJobsStorage__clientId         = azurerm_user_assigned_identity.function.client_id
              APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.this.connection_string
              AZURE_CLIENT_ID                       = azurerm_user_assigned_identity.function.client_id
              Seed__Project                         = var.name
              Seed__Environment                     = var.environment
            },
            var.app_settings,
          ) : { name = k, value = v }
        ]
      }
    }
  }

  response_export_values = ["properties.defaultHostName"]

  # Ohne die Rollen startet der Host nicht, weil er seinen Storage nicht erreicht.
  depends_on = [azurerm_role_assignment.host_storage]
}

# --- Static Web App -----------------------------------------------------------

resource "azurerm_static_web_app" "this" {
  name                = "swa-${local.base}"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.static_web_app_location
  sku_tier            = "Free"
  sku_size            = "Free"
  tags                = local.tags
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
