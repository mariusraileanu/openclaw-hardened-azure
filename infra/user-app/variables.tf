variable "user_slug" {
  description = "Unique slug for the user (used in app name and secret prefixes)"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.user_slug))
    error_message = "user_slug must be 3-20 lowercase alphanumeric/hyphen characters, start with letter, end with alphanumeric."
  }
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

# ---------------------------------------------------------------------------
# Shared Resources (looked up by name via data sources)
# ---------------------------------------------------------------------------
variable "resource_group_name" {
  description = "Name of the shared resource group containing CAE, ACR, KV (e.g. rg-openclaw-prod)"
  type        = string
}

variable "key_vault_name" {
  description = "Name of the shared Key Vault (e.g. kvopenclawprod)"
  type        = string
}

variable "acr_name" {
  description = "Name of the Azure Container Registry (e.g. openclawprodacr)"
  type        = string
}

variable "cae_name" {
  description = "Name of the Container Apps Environment (e.g. cae-openclaw-prod)"
  type        = string
}

variable "cae_nfs_storage_name" {
  description = "Name of the NFS storage mount registered in the CAE (e.g. openclaw-nfs-prod)"
  type        = string
  default     = "openclaw-nfs"
}

# ---------------------------------------------------------------------------
# Container Configuration
# ---------------------------------------------------------------------------
variable "image_ref" {
  description = "Full container image reference (e.g. myacr.azurecr.io/openclaw-golden:v1.0.0)"
  type        = string
}

variable "compass_base_url" {
  description = "Compass provider base URL (e.g. https://api.core42.ai/v1)"
  type        = string
  default     = "https://api.core42.ai/v1"
}

variable "compass_api_key" {
  description = "Compass provider API key"
  type        = string
  sensitive   = true
}

variable "graph_mcp_url" {
  description = "Graph MCP endpoint URL"
  type        = string
  sensitive   = true
}

variable "openclaw_gateway_auth_token" {
  description = "OpenClaw gateway authentication token"
  type        = string
  sensitive   = true
}

variable "cpu" {
  description = "CPU allocation for the container (in cores)"
  type        = number
  default     = 1.0
}

variable "memory" {
  description = "Memory allocation for the container"
  type        = string
  default     = "2Gi"
}

variable "min_replicas" {
  description = "Minimum replica count"
  type        = number
  default     = 1
}

variable "max_replicas" {
  description = "Maximum replica count"
  type        = number
  default     = 1
}

# ---------------------------------------------------------------------------
# Signal Channel (optional)
# ---------------------------------------------------------------------------
variable "signal_cli_url" {
  description = "Base HTTP URL of the shared signal proxy/daemon (e.g. http://host). Auth token is passed separately via signal_proxy_auth_token. Leave empty to skip Signal."
  type        = string
  default     = ""
}

variable "signal_proxy_auth_token" {
  description = "Auth token for the signal routing proxy. Appended as ?token= query parameter by the entrypoint script."
  type        = string
  default     = ""
  sensitive   = true
}

variable "signal_bot_number" {
  description = "Signal bot phone number in E.164 format (e.g. +15551234567). Must match the number registered in signal-cli."
  type        = string
  default     = ""
}

variable "signal_user_phone" {
  description = "User's Signal phone number in E.164 format (for allowFrom). Only this number can DM the bot."
  type        = string
  default     = ""
}
