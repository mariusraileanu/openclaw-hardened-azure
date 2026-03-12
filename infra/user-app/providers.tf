terraform {
  required_version = ">= 1.5.0"

  # State backend — for environments with Azure Policy blocking public storage
  # access, use local state.  For environments with remote state, override by
  # running:  terraform init -backend-config="..." -reconfigure
  # See Makefile tf-init-user target.
  backend "local" {}

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
