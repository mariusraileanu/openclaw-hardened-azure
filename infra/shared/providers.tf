terraform {
  required_version = ">= 1.5.0"

  # Remote state backend — provisioned by infra/bootstrap-state.sh.
  # resource_group_name and storage_account_name are passed via
  # -backend-config at terraform init time (see Makefile targets).
  backend "azurerm" {
    resource_group_name  = ""
    storage_account_name = ""
    container_name       = "tfstate"
    key                  = "shared.tfstate"
    use_azuread_auth     = true
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
}
