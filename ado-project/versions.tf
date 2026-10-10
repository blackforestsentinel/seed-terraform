terraform {
  required_version = ">= 1.9"

  required_providers {
    azuredevops = {
      source  = "microsoft/azuredevops"
      version = ">= 1.16, < 2.0"
    }
  }
}
