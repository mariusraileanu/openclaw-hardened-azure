variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
}

variable "owner_slug" {
  description = "Owner identifier for tagging"
  type        = string
  default     = "platform"
}

variable "nfs_share_quota_gb" {
  description = "NFS file share quota in GB (minimum 100 for Premium FileStorage)"
  type        = number
  default     = 100
}

variable "deployer_ips" {
  description = "Comma-separated list of deployer public IPs (for ACR/KV/Storage firewall rules). Use 'curl -s ifconfig.me && curl -s https://api.ipify.org' to find yours. Leave empty to skip IP allowlisting."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Networking (CIDRs)
# ---------------------------------------------------------------------------
variable "vnet_cidr" {
  description = "Address space for the virtual network"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cae_cidr" {
  description = "CIDR for the Container Apps Environment subnet (/21 minimum = 2048 addresses)"
  type        = string
  default     = "10.0.0.0/21"
}

variable "subnet_pe_cidr" {
  description = "CIDR for the private endpoints subnet"
  type        = string
  default     = "10.0.8.0/24"
}

# ---------------------------------------------------------------------------
# Signal-CLI Daemon (shared messaging relay)
# ---------------------------------------------------------------------------
variable "signal_cli_enabled" {
  description = "Deploy the shared signal-cli daemon container app"
  type        = bool
  default     = false
}

variable "signal_cli_image" {
  description = "signal-cli Docker image reference"
  type        = string
  default     = "ghcr.io/asamk/signal-cli:latest"
}

variable "signal_cli_cpu" {
  description = "CPU allocation for the signal-cli container (in cores)"
  type        = number
  default     = 0.5
}

variable "signal_cli_memory" {
  description = "Memory allocation for the signal-cli container"
  type        = string
  default     = "1Gi"
}

# ---------------------------------------------------------------------------
# Signal Routing Proxy (SSE fan-out by sender phone number)
# ---------------------------------------------------------------------------
variable "signal_proxy_image" {
  description = "signal-proxy Docker image reference (built and pushed to ACR)"
  type        = string
  default     = "" # Set at apply time, e.g. openclawshareddevacr.azurecr.io/signal-proxy:latest
}

variable "signal_proxy_cpu" {
  description = "CPU allocation for the signal-proxy container (in cores)"
  type        = number
  default     = 0.25
}

variable "signal_proxy_memory" {
  description = "Memory allocation for the signal-proxy container"
  type        = string
  default     = "0.5Gi"
}

variable "signal_proxy_auth_token" {
  description = "Shared secret for signal-proxy authentication. Callers must include ?token=<value> in the URL. Leave empty to disable auth (not recommended in production)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "signal_bot_number" {
  description = "Registered Signal bot phone number (e.g. +15551234567). Used as --account flag for signal-cli single-account mode."
  type        = string
  default     = ""
}
