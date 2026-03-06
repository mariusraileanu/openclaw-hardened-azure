terraform {
  required_version = ">= 1.5.0"

  # Remote state backend — provisioned by infra/bootstrap-state.sh.
  # resource_group_name and storage_account_name are passed via
  # -backend-config at terraform init time (see Makefile targets).
  # Per-user isolation: Terraform workspaces prefix the key automatically
  # (e.g. env:<user-slug>/user-app.tfstate).
  backend "azurerm" {
    resource_group_name  = ""
    storage_account_name = ""
    container_name       = "tfstate"
    key                  = "user-app.tfstate"
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
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
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
