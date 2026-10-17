# terraform -chdir=storage init -backend=false && terraform -chdir=storage test
# Läuft gegen einen Mock des azurerm-Providers, ohne Subscription und ohne Rechte.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      subscription_id = "11111111-1111-1111-1111-111111111111"
      tenant_id       = "22222222-2222-2222-2222-222222222222"
      object_id       = "33333333-3333-3333-3333-333333333333"
    }
  }

  # Der Provider prüft Ressourcen-IDs auch gegen den Mock; deshalb echte Formen.
  mock_resource "azurerm_storage_account" {
    defaults = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-example-dev/providers/Microsoft.Storage/storageAccounts/stexampledevdata000000"
    }
  }

  mock_resource "azurerm_storage_container" {
    defaults = {
      id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-example-dev/providers/Microsoft.Storage/storageAccounts/stexampledevdata000000/blobServices/default/containers/uploads"
    }
  }
}

# Der Container extension bekommt eine eigene ID, damit die Rolle nachweislich nur dort landet.
override_resource {
  target = azurerm_storage_container.this["extension"]
  values = {
    id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-example-dev/providers/Microsoft.Storage/storageAccounts/stexampledevdata000000/blobServices/default/containers/extension"
  }
}

variables {
  name                           = "example"
  environment                    = "dev"
  resource_group_name            = "rg-example-dev"
  location                       = "westeurope"
  function_identity_principal_id = "44444444-4444-4444-4444-444444444444"
  function_identity_client_id    = "55555555-5555-5555-5555-555555555555"
}

run "ohne_publisher_keine_rolle" {
  variables {
    containers = ["extension"]
  }

  assert {
    condition     = length(azurerm_role_assignment.extension_publisher) == 0
    error_message = "Ohne extension_publisher_principal_id keine Rolle auf dem Container extension."
  }

  assert {
    condition = {
      for k, r in azurerm_role_assignment.function : k => [r.scope, r.principal_id]
      } == {
      for role in ["Storage Blob Data Contributor", "Storage Queue Data Contributor", "Storage Table Data Contributor"] :
      role => [azurerm_storage_account.this.id, "44444444-4444-4444-4444-444444444444"]
    }
    error_message = "Die Datenrollen der Function bleiben unverändert auf dem Account."
  }
}

run "publisher_mit_container_extension" {
  variables {
    containers                       = ["uploads", "extension"]
    extension_publisher_principal_id = "66666666-6666-6666-6666-666666666666"
  }

  assert {
    condition     = length(azurerm_role_assignment.extension_publisher) == 1
    error_message = "Mit Container extension und Principal genau eine Rolle für die Veröffentlichung."
  }

  assert {
    condition     = azurerm_role_assignment.extension_publisher[0].scope == azurerm_storage_container.this["extension"].id && endswith(azurerm_role_assignment.extension_publisher[0].scope, "/containers/extension")
    error_message = "Die Rolle gilt nur für den Container extension, nicht für den Account oder andere Container."
  }

  assert {
    condition     = azurerm_role_assignment.extension_publisher[0].role_definition_name == "Storage Blob Data Contributor" && azurerm_role_assignment.extension_publisher[0].principal_id == "66666666-6666-6666-6666-666666666666"
    error_message = "Storage Blob Data Contributor für die angegebene Identität."
  }

  assert {
    condition     = length(azurerm_role_assignment.function) == 3
    error_message = "Die Datenrollen der Function bleiben."
  }
}

run "publisher_ohne_container_extension" {
  variables {
    containers                       = ["uploads"]
    extension_publisher_principal_id = "66666666-6666-6666-6666-666666666666"
  }

  assert {
    condition     = length(azurerm_role_assignment.extension_publisher) == 0
    error_message = "Ohne Container extension keine Rolle, auch mit Principal."
  }
}

run "publisher_ohne_container" {
  variables {
    extension_publisher_principal_id = "66666666-6666-6666-6666-666666666666"
  }

  assert {
    condition     = length(azurerm_role_assignment.extension_publisher) == 0 && length(azurerm_storage_container.this) == 0
    error_message = "Ohne Container weder Container noch Rolle."
  }
}

run "publisher_keine_object_id" {
  command = plan

  variables {
    containers                       = ["extension"]
    extension_publisher_principal_id = "sc-example"
  }

  expect_failures = [var.extension_publisher_principal_id]
}
