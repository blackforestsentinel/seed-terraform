# terraform -chdir=keyvault init -backend=false && terraform -chdir=keyvault test
# Läuft gegen Mocks der Provider azurerm und azapi, ohne Subscription und ohne Rechte.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      subscription_id = "11111111-1111-1111-1111-111111111111"
      tenant_id       = "22222222-2222-2222-2222-222222222222"
      object_id       = "33333333-3333-3333-3333-333333333333"
    }
  }

  # Der Provider prüft Ressourcen-IDs auch gegen den Mock; deshalb echte Formen.
  mock_resource "azurerm_key_vault" {
    defaults = {
      id        = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-example-dev/providers/Microsoft.KeyVault/vaults/kv-example-dev-abc123"
      vault_uri = "https://kv-example-dev-abc123.vault.azure.net/"
    }
  }
}

mock_provider "azapi" {}

variables {
  name                           = "example"
  environment                    = "dev"
  resource_group_name            = "rg-example-dev"
  location                       = "westeurope"
  function_identity_principal_id = "44444444-4444-4444-4444-444444444444"
}

run "ohne_owner_wie_bisher" {
  command = plan

  assert {
    condition = azurerm_key_vault.this.tags == tomap({
      "seed:project"     = "example"
      "seed:environment" = "dev"
      "seed:module"      = "keyvault"
    })
    error_message = "Ohne owner bleiben die Tags des Vaults wie bisher."
  }
}

run "owner_als_tag" {
  command = plan

  variables {
    owner = "team@example.org"
  }

  assert {
    condition     = azurerm_key_vault.this.tags["owner"] == "team@example.org"
    error_message = "owner steht als Tag am Vault."
  }
}

run "owner_leer_wie_null" {
  command = plan

  variables {
    owner = ""
  }

  assert {
    condition     = !contains(keys(azurerm_key_vault.this.tags), "owner")
    error_message = "Ein leerer owner wirkt wie null: kein Tag."
  }
}

run "owner_nur_als_mail" {
  command = plan

  variables {
    owner = "team@"
  }

  expect_failures = [var.owner]
}

run "app_settings_mit_vault_uri" {
  variables {
    secrets = ["stripe-key"]
  }

  assert {
    condition = output.app_settings == {
      Secrets__StripeKey = "@Microsoft.KeyVault(VaultName=${output.key_vault_name};SecretName=stripe-key)"
      Seed__KeyVaultUri  = "https://kv-example-dev-abc123.vault.azure.net/"
    }
    error_message = "app_settings: Referenz je Secret und Seed__KeyVaultUri mit der URI des Vaults."
  }
}

# Folgt auf den Apply oben: Bei einem vorhandenen Vault steht die URI im State, der Plan kennt sie
# also, und die App-Settings der Function sind nicht erst nach dem Apply bekannt.
run "vault_uri_im_plan_bekannt" {
  command = plan

  variables {
    secrets = ["stripe-key"]
  }

  assert {
    condition     = output.app_settings["Seed__KeyVaultUri"] == "https://kv-example-dev-abc123.vault.azure.net/"
    error_message = "Bei einem vorhandenen Vault ist Seed__KeyVaultUri schon beim Plan bekannt."
  }
}

run "ohne_secrets_nur_vault_uri" {
  variables {
    secrets = []
  }

  assert {
    condition     = output.app_settings == { Seed__KeyVaultUri = "https://kv-example-dev-abc123.vault.azure.net/" }
    error_message = "Auch ohne Secrets nennt app_settings den Vault."
  }
}
