terraform {
  required_version = ">= 1.5.0"

  # State backend — for environments with Azure Policy blocking public storage
  # access, use local state.  For environments with remote state, override by
  # running:  terraform init -backend-config="..." -reconfigure
  # See Makefile tf-init-user target.
  backend "local" {}

  required_providers {
    azapi = {
      source  = "azure/azapi"
      version = "~> 1.13"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "azapi" {}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
}

provider "azuread" {}
