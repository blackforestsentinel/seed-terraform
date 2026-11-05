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

run "owner_nur_als_mail" {
  command = plan

  variables {
    owner = "team@"
  }

  expect_failures = [var.owner]
}
