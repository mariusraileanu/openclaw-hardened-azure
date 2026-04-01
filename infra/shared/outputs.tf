output "resource_group_name" {
  description = "Name of the shared resource group (consumed by user-app module)"
  value       = azurerm_resource_group.shared.name
}

output "cae_name" {
  description = "Name of the shared Container Apps Environment"
  value       = azurerm_container_app_environment.shared.name
}

output "cae_id" {
  description = "Resource ID of the shared Container Apps Environment"
  value       = azurerm_container_app_environment.shared.id
}

output "cae_default_domain" {
  description = "Default domain of the VNet-integrated CAE (internal only)"
  value       = azurerm_container_app_environment.shared.default_domain
}

output "cae_static_ip" {
  description = "Static internal IP of the CAE load balancer"
  value       = azurerm_container_app_environment.shared.static_ip_address
}

output "acr_name" {
  description = "Name of the Azure Container Registry"
  value       = azurerm_container_registry.shared.name
}

output "acr_login_server" {
  description = "Login server URL for the Azure Container Registry"
  value       = azurerm_container_registry.shared.login_server
}

output "key_vault_name" {
  description = "Name of the shared Key Vault (stores per-user secrets)"
  value       = azurerm_key_vault.shared.name
}

output "key_vault_id" {
  description = "Resource ID of the shared Key Vault"
  value       = azurerm_key_vault.shared.id
}

output "key_vault_uri" {
  description = "URI of the shared Key Vault"
  value       = azurerm_key_vault.shared.vault_uri
}

output "storage_account_name" {
  description = "Name of the shared storage account"
  value       = azapi_resource.shared_storage.name
}

output "managed_identity_id" {
  description = "Resource ID of the shared user-assigned managed identity"
  value       = azurerm_user_assigned_identity.shared.id
}

output "managed_identity_principal_id" {
  description = "Principal (object) ID of the shared managed identity — used for RBAC assignments"
  value       = azurerm_user_assigned_identity.shared.principal_id
}

output "managed_identity_client_id" {
  description = "Client ID of the shared managed identity — used for workload authentication"
  value       = azurerm_user_assigned_identity.shared.client_id
}

output "nfs_storage_account_name" {
  description = "Name of the NFS-enabled storage account for user data volumes"
  value       = azurerm_storage_account.nfs.name
}

output "nfs_share_name" {
  description = "Name of the Azure Files NFS share mounted into user containers"
  value       = azurerm_storage_share.openclaw_data.name
}

output "cae_nfs_storage_name" {
  description = "Name of the NFS storage mount registered in the Container Apps Environment"
  value       = "openclaw-nfs-${var.environment}"
}

output "vnet_id" {
  description = "Resource ID of the shared virtual network"
  value       = azurerm_virtual_network.shared.id
}

output "cae_subnet_id" {
  description = "Resource ID of the Container Apps Environment subnet"
  value       = azurerm_subnet.cae.id
}

output "pe_subnet_id" {
  description = "Resource ID of the private endpoints subnet"
  value       = azurerm_subnet.pe.id
}

# ---------------------------------------------------------------------------
# Signal-CLI Daemon
# ---------------------------------------------------------------------------
output "signal_cli_fqdn" {
  description = "Internal FQDN of the signal-cli daemon (direct access, for admin/debug only)"
  value       = var.signal_cli_enabled ? azurerm_container_app.signal_cli[0].ingress[0].fqdn : ""
}

output "signal_cli_direct_url" {
  description = "Direct HTTP URL to the signal-cli daemon (bypass proxy, for admin/debug only)"
  value       = var.signal_cli_enabled ? "http://${azurerm_container_app.signal_cli[0].ingress[0].fqdn}" : ""
}

# ---------------------------------------------------------------------------
# Signal Routing Proxy
# ---------------------------------------------------------------------------
output "signal_proxy_fqdn" {
  description = "Internal FQDN of the signal routing proxy"
  value       = var.signal_cli_enabled && var.signal_proxy_image != "" ? azurerm_container_app.signal_proxy[0].ingress[0].fqdn : ""
}

output "signal_cli_url" {
  description = "Base HTTP URL for user OpenClaw containers to connect to Signal (points to routing proxy when available, falls back to signal-cli direct). Auth token is provided separately via signal_proxy_auth_token output."

  value = (
    var.signal_cli_enabled && var.signal_proxy_image != ""
    ? "http://${azurerm_container_app.signal_proxy[0].ingress[0].fqdn}"
    : var.signal_cli_enabled
    ? "http://${azurerm_container_app.signal_cli[0].ingress[0].fqdn}"
    : ""
  )
}

output "signal_proxy_auth_token" {
  description = "Auth token for the signal routing proxy. Passed to user containers as a separate env var and appended as ?token= query parameter."
  sensitive   = true
  value       = var.signal_proxy_auth_token
}

# ---------------------------------------------------------------------------
# Microsoft Teams Webhook Relay + Shared Bot
# ---------------------------------------------------------------------------
output "teams_relay_hostname" {
  description = "Public hostname of the Teams webhook relay Function App (empty if relay disabled)"
  value       = var.msteams_relay_enabled ? azurerm_linux_function_app.relay[0].default_hostname : ""
}

output "teams_relay_enabled" {
  description = "Whether the Teams relay Function App is deployed"
  value       = var.msteams_relay_enabled
}

output "msteams_app_id" {
  description = "Shared Teams bot App Registration client ID (empty if bot not deployed)"
  value       = local.msteams_bot_enabled ? var.msteams_app_id : ""
}

output "msteams_app_password_secret_id" {
  description = "Key Vault secret versionless ID for the shared bot password (empty if bot not deployed)"
  value       = local.msteams_bot_enabled && var.msteams_app_secret_value != "" ? azurerm_key_vault_secret.msteams_app_password[0].versionless_id : ""
}

output "msteams_bot_name" {
  description = "Name of the shared Azure Bot Service resource (empty if bot not deployed)"
  value       = local.msteams_bot_enabled ? azurerm_bot_service_azure_bot.shared[0].name : ""
}

output "msteams_tenant_id" {
  description = "Azure AD tenant ID for the shared Teams bot (empty if not configured)"
  value       = var.msteams_tenant_id
}
