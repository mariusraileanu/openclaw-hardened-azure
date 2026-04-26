data "azurerm_client_config" "current" {}

locals {
  resource_group_name  = "rg-openclaw-${var.environment}"
  cae_name             = "cae-openclaw-${var.environment}"
  acr_name             = var.acr_name != "" ? var.acr_name : "openclaw${var.environment}acr"
  kv_name              = "kvopenclaw${var.environment}"
  sa_name              = var.sa_name != "" ? var.sa_name : "stopenclaw${var.environment}"
  sa_nfs_name          = "nfsopenclaw${var.environment}"
  vnet_name            = "vnet-openclaw-${var.environment}"
  identity_name        = "id-openclaw-${var.environment}"
  log_analytics_name   = "law-openclaw-${var.environment}"
  nfs_share_name       = "openclaw-data"
  cae_nfs_storage_name = "openclaw-nfs-${var.environment}"

  tags = {
    environment = var.environment
    owner       = var.owner_slug
    project     = "openclaw"
    managed_by  = "terraform"
  }

  # Parse comma-separated deployer IPs into a list, trimming whitespace
  deployer_ip_list = var.deployer_ips != "" ? [for ip in split(",", var.deployer_ips) : trimspace(ip)] : []
}

# ---------------------------------------------------------------------------
# Resource Group
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "shared" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags

  lifecycle {
    ignore_changes = [
      tags["CreatedDate"],
    ]
  }
}

# ---------------------------------------------------------------------------
# Virtual Network (internal-only Container Apps)
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "shared" {
  name                = local.vnet_name
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

# CAE subnet — /21 gives 2048 addresses, required minimum for Container Apps
resource "azurerm_subnet" "cae" {
  name                 = "snet-cae"
  resource_group_name  = azurerm_resource_group.shared.name
  virtual_network_name = azurerm_virtual_network.shared.name
  address_prefixes     = [var.subnet_cae_cidr]

  service_endpoints = ["Microsoft.Storage"]

  delegation {
    name = "containerapp-delegation"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Private endpoint subnet — separate from CAE, no delegation needed
resource "azurerm_subnet" "pe" {
  name                 = "snet-pe"
  resource_group_name  = azurerm_resource_group.shared.name
  virtual_network_name = azurerm_virtual_network.shared.name
  address_prefixes     = [var.subnet_pe_cidr]

  # Allow NSG rules to apply to private endpoint traffic (default is Disabled)
  private_endpoint_network_policies = "NetworkSecurityGroupEnabled"
}

# ---------------------------------------------------------------------------
# Network Security Group (CAE subnet)
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "cae" {
  name                = "nsg-snet-cae-${var.environment}"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  tags                = local.tags

  # --- Inbound rules ---

  # Allow all traffic within the VNet (container-to-container + PE access)
  security_rule {
    name                       = "AllowVNetInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  # Allow HTTPS from Internet (only when CAE supports external ingress, e.g. for
  # Microsoft Teams webhook callbacks). Azure Container Apps terminates TLS and
  # forwards traffic to the container on the configured target_port.
  dynamic "security_rule" {
    for_each = var.cae_internal_only ? [] : [1]
    content {
      name                       = "AllowHTTPSInbound"
      priority                   = 200
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "443"
      source_address_prefix      = "Internet"
      destination_address_prefix = "VirtualNetwork"
    }
  }

  # Explicit deny-all inbound catch-all
  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # --- Outbound rules ---

  # Allow all traffic within the VNet (container-to-container + PE access)
  security_rule {
    name                       = "AllowVNetOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  # Allow HTTPS outbound (Signal servers, MCP gateway, COMPASS API)
  security_rule {
    name                       = "AllowHTTPSOutbound"
    priority                   = 200
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }

  # Allow DNS outbound (required for name resolution)
  security_rule {
    name                       = "AllowDNSOutbound"
    priority                   = 300
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "53"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Allow NTP outbound (time synchronisation)
  security_rule {
    name                       = "AllowNTPOutbound"
    priority                   = 400
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "123"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Explicit deny-all outbound catch-all
  security_rule {
    name                       = "DenyAllOutbound"
    priority                   = 4096
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

resource "azurerm_subnet_network_security_group_association" "cae" {
  subnet_id                 = azurerm_subnet.cae.id
  network_security_group_id = azurerm_network_security_group.cae.id
}

# ---------------------------------------------------------------------------
# Network Security Group (PE subnet)
# ---------------------------------------------------------------------------
# With private_endpoint_network_policies = "NetworkSecurityGroupEnabled" on the
# PE subnet, these rules apply to private endpoint traffic. Only the CAE subnet
# (containers) should be able to reach the private endpoints.
resource "azurerm_network_security_group" "pe" {
  name                = "nsg-snet-pe-${var.environment}"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  tags                = local.tags

  # --- Inbound rules ---

  # Allow HTTPS from CAE subnet to PEs (Key Vault + ACR)
  security_rule {
    name                       = "AllowCAEtoHTTPS"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.subnet_cae_cidr
    destination_address_prefix = "VirtualNetwork"
  }

  # Allow NFS from CAE subnet to NFS storage PE (NFSv4.1 = port 2049)
  security_rule {
    name                       = "AllowCAEtoNFS"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "2049"
    source_address_prefix      = var.subnet_cae_cidr
    destination_address_prefix = "VirtualNetwork"
  }

  # Explicit deny-all inbound catch-all
  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

resource "azurerm_subnet_network_security_group_association" "pe" {
  subnet_id                 = azurerm_subnet.pe.id
  network_security_group_id = azurerm_network_security_group.pe.id
}

# ---------------------------------------------------------------------------
# User-Assigned Managed Identity (shared by all user apps)
# ---------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "shared" {
  name                = local.identity_name
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  tags                = local.tags

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

# ---------------------------------------------------------------------------
# Log Analytics Workspace (required by Container Apps Environment)
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "shared" {
  name                = local.log_analytics_name
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  sku                 = "PerGB2018"
  retention_in_days   = 90
  tags                = local.tags

  # Phase 4c: Prevent accidental destruction of log data
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [tags["CreatedDate"]]
  }
}

# ---------------------------------------------------------------------------
# Container Apps Environment (VNET-integrated)
# When cae_internal_only=true: internal LB only (no public endpoints).
# When cae_internal_only=false: external LB allows per-app public ingress
# (e.g. for Teams webhook). Apps default to internal unless external_enabled=true.
# ---------------------------------------------------------------------------
resource "azurerm_container_app_environment" "shared" {
  name                           = local.cae_name
  location                       = azurerm_resource_group.shared.location
  resource_group_name            = azurerm_resource_group.shared.name
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.shared.id
  infrastructure_subnet_id       = azurerm_subnet.cae.id
  internal_load_balancer_enabled = var.cae_internal_only
  tags                           = local.tags

  lifecycle {
    ignore_changes = [
      log_analytics_workspace_id,
      infrastructure_resource_group_name, # Azure auto-populates; treating as drift forces CAE replacement
      workload_profile,
      tags["CreatedDate"],
    ]
  }
}

# ---------------------------------------------------------------------------
# Azure Container Registry (Premium for private endpoint support)
# ---------------------------------------------------------------------------
resource "azurerm_container_registry" "shared" {
  name                          = local.acr_name
  location                      = azurerm_resource_group.shared.location
  resource_group_name           = azurerm_resource_group.shared.name
  sku                           = "Premium"
  admin_enabled                 = false
  public_network_access_enabled = length(local.deployer_ip_list) > 0 ? true : false
  tags                          = local.tags

  # When deployer IPs are set, allow only those IPs; otherwise block all public access
  dynamic "network_rule_set" {
    for_each = length(local.deployer_ip_list) > 0 ? [1] : []
    content {
      default_action = "Deny"
      dynamic "ip_rule" {
        for_each = local.deployer_ip_list
        content {
          action   = "Allow"
          ip_range = "${ip_rule.value}/32"
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

# AcrPull role for the shared managed identity
resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.shared.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.shared.principal_id
}

# ---------------------------------------------------------------------------
# Azure Key Vault (RBAC authorization model)
# ---------------------------------------------------------------------------
resource "azurerm_key_vault" "shared" {
  name                       = local.kv_name
  location                   = azurerm_resource_group.shared.location
  resource_group_name        = azurerm_resource_group.shared.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 90
  tags                       = local.tags

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = local.deployer_ip_list
  }

  # Phase 4c: Prevent accidental destruction of Key Vault (secrets, certs)
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [tags["CreatedDate"]]
  }
}

# Key Vault Secrets Officer role for the deploying principal (to push secrets)
resource "azurerm_role_assignment" "kv_secrets_officer" {
  scope                = azurerm_key_vault.shared.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ---------------------------------------------------------------------------
# Storage Account (general purpose)
# ---------------------------------------------------------------------------
# Uses azapi instead of azurerm because the azurerm provider's data-plane
# polling uses key-based auth which fails when shared_access_key_enabled=false
# (required by Azure policy in prod subscription).
resource "azapi_resource" "shared_storage" {
  type      = "Microsoft.Storage/storageAccounts@2023-05-01"
  name      = local.sa_name
  location  = azurerm_resource_group.shared.location
  parent_id = azurerm_resource_group.shared.id
  tags      = local.tags

  body = {
    kind = "StorageV2"
    sku = {
      name = "Standard_LRS"
    }
    properties = {
      minimumTlsVersion        = "TLS1_2"
      supportsHttpsTrafficOnly = true
      publicNetworkAccess      = "Disabled"
      allowSharedKeyAccess     = false
      allowBlobPublicAccess    = false
      networkAcls = {
        defaultAction = "Deny"
        bypass        = "AzureServices"
        virtualNetworkRules = [
          { id = azurerm_subnet.cae.id }
        ]
        ipRules = [for ip in local.deployer_ip_list : { value = ip }]
      }
      encryption = {
        services = {
          blob = { enabled = true }
          file = { enabled = true }
        }
        keySource = "Microsoft.Storage"
      }
    }
  }

  response_export_values = ["properties.primaryEndpoints.blob"]

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [tags["CreatedDate"]]
  }
}

# Blob soft-delete policy — set via azapi since the SA is managed by azapi
resource "azapi_update_resource" "shared_storage_blob_service" {
  type      = "Microsoft.Storage/storageAccounts/blobServices@2023-05-01"
  name      = "default"
  parent_id = azapi_resource.shared_storage.id

  body = {
    properties = {
      deleteRetentionPolicy = {
        enabled = true
        days    = 7
      }
      containerDeleteRetentionPolicy = {
        enabled = true
        days    = 7
      }
    }
  }
}

locals {
  shared_sa_id = azapi_resource.shared_storage.id
}

# ---------------------------------------------------------------------------
# Premium NFS FileStorage Account (persistent storage for Container Apps)
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "nfs" {
  name                          = local.sa_nfs_name
  location                      = azurerm_resource_group.shared.location
  resource_group_name           = azurerm_resource_group.shared.name
  account_tier                  = "Premium"
  account_kind                  = "FileStorage"
  account_replication_type      = "LRS"
  min_tls_version               = "TLS1_2"
  https_traffic_only_enabled    = false # NFS requires this to be false
  public_network_access_enabled = false
  shared_access_key_enabled     = false

  network_rules {
    default_action             = "Deny"
    bypass                     = ["AzureServices"]
    virtual_network_subnet_ids = [azurerm_subnet.cae.id]
    ip_rules                   = local.deployer_ip_list
  }

  tags = local.tags

  # Phase 4c: Prevent accidental destruction of stateful NFS storage
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [tags["CreatedDate"]]
  }
}

# NFS file share for OpenClaw persistent data
resource "azurerm_storage_share" "openclaw_data" {
  name               = local.nfs_share_name
  storage_account_id = azurerm_storage_account.nfs.id
  enabled_protocol   = "NFS"
  quota              = var.nfs_share_quota_gb
}

# ---------------------------------------------------------------------------
# Mount NFS share into Container Apps Environment
# ---------------------------------------------------------------------------
# NOTE: azurerm_container_app_environment_storage only supports SMB (AzureFile).
# NFS storage registration is managed via CLI because ARM PUT for this resource
# currently rejects nfsAzureFile payload shape in this tenant.
resource "null_resource" "cae_nfs_storage" {
  triggers = {
    cae_name     = azurerm_container_app_environment.shared.name
    rg_name      = azurerm_resource_group.shared.name
    storage_name = local.cae_nfs_storage_name
    account      = azurerm_storage_account.nfs.name
    share_name   = azurerm_storage_share.openclaw_data.name
  }

  provisioner "local-exec" {
    command = <<-EOT
      az containerapp env storage set \
        --name ${self.triggers.cae_name} \
        --resource-group ${self.triggers.rg_name} \
        --storage-name ${self.triggers.storage_name} \
        --storage-type NfsAzureFile \
        --server ${self.triggers.account}.file.core.windows.net \
        --file-share /${self.triggers.account}/${self.triggers.share_name} \
        --access-mode ReadWrite \
        --output none
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      az containerapp env storage remove \
        --name ${self.triggers.cae_name} \
        --resource-group ${self.triggers.rg_name} \
        --storage-name ${self.triggers.storage_name} \
        --yes \
        --output none 2>/dev/null || true
    EOT
  }

  depends_on = [azurerm_storage_share.openclaw_data]
}

# ===========================================================================
# Private Endpoints + Private DNS Zones
# ===========================================================================

# ---------------------------------------------------------------------------
# Private DNS Zones
# ---------------------------------------------------------------------------
resource "azurerm_private_dns_zone" "kv" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.shared.name
  tags                = local.tags

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

resource "azurerm_private_dns_zone" "acr" {
  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.shared.name
  tags                = local.tags

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

resource "azurerm_private_dns_zone" "file" {
  name                = "privatelink.file.core.windows.net"
  resource_group_name = azurerm_resource_group.shared.name
  tags                = local.tags

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

# Container Apps Environment internal DNS — required so the relay Function App
# (and any other VNet-integrated resource) can resolve *.internal.<cae_domain>.
resource "azurerm_private_dns_zone" "cae" {
  name                = azurerm_container_app_environment.shared.default_domain
  resource_group_name = azurerm_resource_group.shared.name
  tags                = local.tags

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

resource "azurerm_private_dns_a_record" "cae_wildcard" {
  name                = "*"
  zone_name           = azurerm_private_dns_zone.cae.name
  resource_group_name = azurerm_resource_group.shared.name
  ttl                 = 300
  records             = [azurerm_container_app_environment.shared.static_ip_address]
  tags                = local.tags

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

# ---------------------------------------------------------------------------
# VNet Links (so Container Apps can resolve private DNS)
# ---------------------------------------------------------------------------
resource "azurerm_private_dns_zone_virtual_network_link" "cae" {
  name                  = "link-cae"
  resource_group_name   = azurerm_resource_group.shared.name
  private_dns_zone_name = azurerm_private_dns_zone.cae.name
  virtual_network_id    = azurerm_virtual_network.shared.id
  registration_enabled  = false
  tags                  = local.tags

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "kv" {
  name                  = "link-kv"
  resource_group_name   = azurerm_resource_group.shared.name
  private_dns_zone_name = azurerm_private_dns_zone.kv.name
  virtual_network_id    = azurerm_virtual_network.shared.id
  registration_enabled  = false
  tags                  = local.tags

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  name                  = "link-acr"
  resource_group_name   = azurerm_resource_group.shared.name
  private_dns_zone_name = azurerm_private_dns_zone.acr.name
  virtual_network_id    = azurerm_virtual_network.shared.id
  registration_enabled  = false
  tags                  = local.tags

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "file" {
  name                  = "link-file"
  resource_group_name   = azurerm_resource_group.shared.name
  private_dns_zone_name = azurerm_private_dns_zone.file.name
  virtual_network_id    = azurerm_virtual_network.shared.id
  registration_enabled  = false
  tags                  = local.tags

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

# ---------------------------------------------------------------------------
# Private Endpoint: Key Vault
# ---------------------------------------------------------------------------
resource "azurerm_private_endpoint" "kv" {
  name                = "pe-kv-${var.environment}"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-kv"
    private_connection_resource_id = azurerm_key_vault.shared.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.kv.id]
  }

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

# ---------------------------------------------------------------------------
# Private Endpoint: ACR
# ---------------------------------------------------------------------------
resource "azurerm_private_endpoint" "acr" {
  name                = "pe-acr-${var.environment}"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-acr"
    private_connection_resource_id = azurerm_container_registry.shared.id
    is_manual_connection           = false
    subresource_names              = ["registry"]
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr.id]
  }

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

# ---------------------------------------------------------------------------
# Private Endpoint: NFS Storage
# ---------------------------------------------------------------------------
resource "azurerm_private_endpoint" "nfs" {
  name                = "pe-nfs-${var.environment}"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-nfs"
    private_connection_resource_id = azurerm_storage_account.nfs.id
    is_manual_connection           = false
    subresource_names              = ["file"]
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.file.id]
  }

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

# ===========================================================================
# Phase 4: Observability & Governance
# ===========================================================================

# ---------------------------------------------------------------------------
# 4a: Diagnostic Settings — stream PaaS audit/metric logs to Log Analytics
# ---------------------------------------------------------------------------

# Key Vault diagnostics: audit events (secret access, policy changes)
resource "azurerm_monitor_diagnostic_setting" "kv" {
  name                       = "diag-kv-to-law"
  target_resource_id         = azurerm_key_vault.shared.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.shared.id

  enabled_log {
    category = "AuditEvent"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# ACR diagnostics: login events, image push/pull, repository events
resource "azurerm_monitor_diagnostic_setting" "acr" {
  name                       = "diag-acr-to-law"
  target_resource_id         = azurerm_container_registry.shared.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.shared.id

  enabled_log {
    category = "ContainerRegistryLoginEvents"
  }

  enabled_log {
    category = "ContainerRegistryRepositoryEvents"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# General storage account diagnostics (account-level metrics only;
# blob/file/table/queue diagnostics require separate target resource IDs)
resource "azurerm_monitor_diagnostic_setting" "storage" {
  name                       = "diag-storage-to-law"
  target_resource_id         = azapi_resource.shared_storage.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.shared.id

  enabled_metric {
    category = "Transaction"
  }
}

# NFS storage account diagnostics (account-level metrics)
resource "azurerm_monitor_diagnostic_setting" "nfs_storage" {
  name                       = "diag-nfs-to-law"
  target_resource_id         = azurerm_storage_account.nfs.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.shared.id

  enabled_metric {
    category = "Transaction"
  }
}

# Teams relay Function App diagnostics: structured relay events + metrics
resource "azurerm_monitor_diagnostic_setting" "relay" {
  count                      = var.msteams_relay_enabled ? 1 : 0
  name                       = "diag-relay-to-law"
  target_resource_id         = azurerm_linux_function_app.relay[0].id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.shared.id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# ===========================================================================
# Signal-CLI Daemon (shared messaging relay)
# ===========================================================================
# Runs a single signal-cli daemon with HTTP JSON-RPC + SSE endpoints.
# User OpenClaw containers connect to it via httpUrl. The daemon handles
# all Signal protocol operations (encryption, key storage, message routing).
# Must be exactly 1 replica — Signal only allows one active client per number.

resource "azurerm_container_app" "signal_cli" {
  count                        = var.signal_cli_enabled ? 1 : 0
  name                         = "ca-signal-cli-${var.environment}"
  container_app_environment_id = azurerm_container_app_environment.shared.id
  resource_group_name          = azurerm_resource_group.shared.name
  revision_mode                = "Single"
  tags                         = local.tags

  lifecycle {
    ignore_changes = [
      template[0].volume,                     # Managed via azapi_update_resource (NfsAzureFile workaround)
      template[0].container[0].volume_mounts, # Added by AzAPI after creation
      workload_profile_name,                  # Azure auto-sets to "Consumption"
      tags["CreatedDate"],
    ]
  }

  ingress {
    external_enabled           = false
    target_port                = 8080
    transport                  = "http"
    allow_insecure_connections = true # Required for HTTP SSE connections within VNet

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1 # MUST be exactly 1 — Signal protocol constraint

    # NOTE: volume is NOT defined here. The azurerm provider only supports
    # "AzureFile" but the CAE storage mount is NfsAzureFile, which causes a
    # 400 error. The azapi_update_resource.signal_nfs_volume_patch adds the NFS
    # volume + container volumeMount after creation.

    container {
      name   = "signal-cli"
      image  = var.signal_cli_image
      cpu    = var.signal_cli_cpu
      memory = var.signal_cli_memory

      # signal-cli daemon with HTTP JSON-RPC on port 8080
      # --verbose: detailed logging for debugging SSE/registration issues
      # --config: NFS-persisted data directory
      # --account: single-account mode (required for SSE event dispatch)
      # --receive-mode=on-start: begins receiving messages immediately
      args = concat(
        ["--verbose", "--config", "/signal-data"],
        var.signal_bot_number != "" ? ["--account", var.signal_bot_number] : [],
        ["daemon", "--http", "0.0.0.0:8080", "--receive-mode=on-start"],
      )

      # NOTE: volume_mounts not defined here — added by AzAPI patch

      # Startup probe: JVM takes a while to initialize
      # 10 * 10s = 100s max startup time
      startup_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/api/v1/check"
        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 10
      }

      # Liveness probe: restart if daemon becomes unresponsive
      liveness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/api/v1/check"
        initial_delay           = 1
        interval_seconds        = 60
        timeout                 = 10
        failure_count_threshold = 3
      }
    }
  }
}

# Patch signal-cli: add NfsAzureFile volume + container volumeMount via AzAPI
# ---------------------------------------------------------------------------
# The azurerm provider cannot create a container app with NfsAzureFile volumes
# (only supports "AzureFile", but the CAE storage is registered as NfsAzureFile).
# So we create the container app bare (no volume/mounts), then AzAPI patches in
# the NFS volume and updates the container spec in one ARM update.
# IMPORTANT: The PATCH body must include the COMPLETE container spec
# (args, probes, resources) because Azure replaces the entire containers array.

locals {
  signal_cli_args = concat(
    ["--verbose", "--config", "/signal-data"],
    var.signal_bot_number != "" ? ["--account", var.signal_bot_number] : [],
    ["daemon", "--http", "0.0.0.0:8080", "--receive-mode=on-start"],
  )

  signal_nfs_patch_body = jsonencode({
    properties = {
      template = {
        volumes = [
          {
            name        = "signal-data"
            storageName = local.cae_nfs_storage_name
            storageType = "NfsAzureFile"
          }
        ]
        containers = [
          {
            name  = "signal-cli"
            image = var.signal_cli_image
            resources = {
              cpu    = var.signal_cli_cpu
              memory = var.signal_cli_memory
            }
            args = local.signal_cli_args
            volumeMounts = [
              {
                volumeName = "signal-data"
                mountPath  = "/signal-data"
              }
            ]
            probes = [
              {
                type = "Startup"
                httpGet = {
                  port = 8080
                  path = "/api/v1/check"
                }
                periodSeconds    = 10
                timeoutSeconds   = 5
                failureThreshold = 10
              },
              {
                type = "Liveness"
                httpGet = {
                  port = 8080
                  path = "/api/v1/check"
                }
                initialDelaySeconds = 1
                periodSeconds       = 60
                timeoutSeconds      = 10
                failureThreshold    = 3
              }
            ]
          }
        ]
      }
    }
  })
}

resource "azapi_update_resource" "signal_nfs_volume_patch" {
  count = var.signal_cli_enabled ? 1 : 0

  type        = "Microsoft.App/containerApps@2024-03-01"
  resource_id = azurerm_container_app.signal_cli[0].id
  body        = local.signal_nfs_patch_body

  depends_on = [
    azurerm_container_app.signal_cli,
    null_resource.cae_nfs_storage,
  ]
}

data "azapi_resource" "signal_cli_template" {
  count = var.signal_cli_enabled ? 1 : 0

  type        = "Microsoft.App/containerApps@2024-03-01"
  resource_id = azurerm_container_app.signal_cli[0].id

  response_export_values = ["*"]

  depends_on = [azapi_update_resource.signal_nfs_volume_patch]
}

check "signal_cli_nfs_mount_present" {
  assert {
    condition     = !var.signal_cli_enabled || (can(regex("NfsAzureFile", jsonencode(data.azapi_resource.signal_cli_template[0].output))) && can(regex("signal-data", jsonencode(data.azapi_resource.signal_cli_template[0].output))) && can(regex("/signal-data", jsonencode(data.azapi_resource.signal_cli_template[0].output))))
    error_message = "Signal container app is missing expected NFS volume or mount after AzAPI patch."
  }
}

# ===========================================================================
# Signal Routing Proxy (shared, internal-only)
# ===========================================================================
resource "azurerm_container_app" "signal_proxy" {
  count                        = var.signal_cli_enabled && var.signal_proxy_image != "" ? 1 : 0
  name                         = "ca-signal-proxy-${var.environment}"
  container_app_environment_id = azurerm_container_app_environment.shared.id
  resource_group_name          = azurerm_resource_group.shared.name
  revision_mode                = "Single"
  tags                         = local.tags

  lifecycle {
    ignore_changes = [
      workload_profile_name, # Azure auto-sets to "Consumption"
      tags["CreatedDate"],
    ]
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.shared.id]
  }

  registry {
    server   = "${local.acr_name}.azurecr.io"
    identity = azurerm_user_assigned_identity.shared.id
  }

  # Auth token secret (only added when a token is configured)
  dynamic "secret" {
    for_each = var.signal_proxy_auth_token != "" ? [1] : []
    content {
      name  = "auth-token"
      value = var.signal_proxy_auth_token
    }
  }

  ingress {
    external_enabled           = false
    target_port                = 8080
    transport                  = "http"
    allow_insecure_connections = true # Required for HTTP POST from OpenClaw (avoids 301 redirect dropping body)

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1 # Stateful SSE connections; scale later with shared state if needed

    container {
      name   = "signal-proxy"
      image  = var.signal_proxy_image
      cpu    = var.signal_proxy_cpu
      memory = var.signal_proxy_memory

      env {
        name  = "SIGNAL_CLI_URL"
        value = "http://${azurerm_container_app.signal_cli[0].ingress[0].fqdn}"
      }

      env {
        name  = "LISTEN_ADDR"
        value = ":8080"
      }

      # Auth token (only set when configured; proxy runs without auth if empty)
      dynamic "env" {
        for_each = var.signal_proxy_auth_token != "" ? [1] : []
        content {
          name        = "AUTH_TOKEN"
          secret_name = "auth-token"
        }
      }

      # Startup probe: proxy should start quickly (no JVM)
      # 6 * 5s = 30s max startup time
      startup_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/healthz"
        interval_seconds        = 5
        timeout                 = 3
        failure_count_threshold = 6
      }

      # Liveness probe: restart if proxy becomes unresponsive
      liveness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/healthz"
        initial_delay           = 1
        interval_seconds        = 30
        timeout                 = 5
        failure_count_threshold = 3
      }
    }
  }

  depends_on = [azurerm_container_app.signal_cli]
}

# ===========================================================================
# Microsoft Teams Webhook Relay (Azure Function — Flex Consumption)
# ===========================================================================
# A stateless HTTP proxy that receives Bot Framework webhooks on a public
# endpoint and forwards them to the corresponding internal Container App.
# One Function App serves ALL users via payload-based routing:
#   POST /api/messages → ca-openclaw-{env}-{user_slug}.{cae_domain}:3978/api/messages
# Uses Flex Consumption (FC1) plan: scales to zero, ~$2/month at low traffic.

# ---------------------------------------------------------------------------
# Functions subnet (VNet integration for outbound traffic to internal CAE)
# ---------------------------------------------------------------------------
resource "azurerm_subnet" "func" {
  count                = var.msteams_relay_enabled ? 1 : 0
  name                 = "snet-func"
  resource_group_name  = azurerm_resource_group.shared.name
  virtual_network_name = azurerm_virtual_network.shared.name
  address_prefixes     = [var.subnet_func_cidr]

  delegation {
    name = "func-delegation"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# ---------------------------------------------------------------------------
# Storage account for Function App runtime (Flex Consumption uses blob)
# ---------------------------------------------------------------------------
# Uses azapi for the same shared-key-disabled compatibility reason as shared_storage above.
resource "azapi_resource" "func_storage" {
  count     = var.msteams_relay_enabled ? 1 : 0
  type      = "Microsoft.Storage/storageAccounts@2023-05-01"
  name      = "strelayopenclaw${var.environment}"
  location  = azurerm_resource_group.shared.location
  parent_id = azurerm_resource_group.shared.id
  tags      = local.tags

  body = {
    kind = "StorageV2"
    sku = {
      name = "Standard_LRS"
    }
    properties = {
      minimumTlsVersion        = "TLS1_2"
      supportsHttpsTrafficOnly = true
      publicNetworkAccess      = "Disabled"
      allowSharedKeyAccess     = false
      allowBlobPublicAccess    = false
    }
  }

  response_export_values = ["properties.primaryEndpoints.blob"]

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

# Blob container for Function App deployment packages — created via azapi
# since the parent SA is managed by azapi (avoids azurerm data-plane auth issues).
resource "azapi_resource" "func_deploy_container" {
  count     = var.msteams_relay_enabled ? 1 : 0
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01"
  name      = "function-deployments"
  parent_id = "${azapi_resource.func_storage[0].id}/blobServices/default"

  body = {
    properties = {
      publicAccess = "None"
    }
  }
}

resource "azapi_resource" "func_board_queue" {
  count     = var.msteams_relay_enabled ? 1 : 0
  type      = "Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01"
  name      = "teams-board-requests"
  parent_id = "${azapi_resource.func_storage[0].id}/queueServices/default"

  body = {
    properties = {}
  }
}

# RBAC: managed identity needs blob access for Function App deployment storage
resource "azurerm_role_assignment" "func_storage_blob" {
  count                = var.msteams_relay_enabled ? 1 : 0
  scope                = azapi_resource.func_storage[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.shared.principal_id
}

# RBAC: managed identity needs queue access for Functions host/runtime internals
resource "azurerm_role_assignment" "func_storage_queue_contributor" {
  count                = var.msteams_relay_enabled ? 1 : 0
  scope                = azapi_resource.func_storage[0].id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_user_assigned_identity.shared.principal_id
}

# Teams routing registry table (aad_object_id -> upstream_url)
resource "azapi_resource" "func_routing_table" {
  count     = var.msteams_relay_enabled ? 1 : 0
  type      = "Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01"
  name      = "userrouting"
  parent_id = "${azapi_resource.func_storage[0].id}/tableServices/default"

  body = {
    properties = {}
  }
}

# RBAC: relay identity needs Azure Table reads for routing lookups
resource "azurerm_role_assignment" "func_storage_table_reader" {
  count                = var.msteams_relay_enabled ? 1 : 0
  scope                = azapi_resource.func_storage[0].id
  role_definition_name = "Storage Table Data Reader"
  principal_id         = azurerm_user_assigned_identity.shared.principal_id
}

# RBAC: managed identity needs table writes for host/runtime internals
resource "azurerm_role_assignment" "func_storage_table_contributor_identity" {
  count                = var.msteams_relay_enabled ? 1 : 0
  scope                = azapi_resource.func_storage[0].id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_user_assigned_identity.shared.principal_id
}

# RBAC: deploying principal can manage routing entries (Table data-plane)
resource "azurerm_role_assignment" "func_storage_table_contributor_current" {
  count                = var.msteams_relay_enabled ? 1 : 0
  scope                = azapi_resource.func_storage[0].id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ---------------------------------------------------------------------------
# Service Plan (Elastic Premium EP1 — required for VNet integration)
# ---------------------------------------------------------------------------
resource "azurerm_service_plan" "relay" {
  count               = var.msteams_relay_enabled ? 1 : 0
  name                = "asp-relay-${var.environment}"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  os_type             = "Linux"
  sku_name            = "EP1"
  tags                = local.tags

  lifecycle {
    ignore_changes = [tags["CreatedDate"]]
  }
}

# ---------------------------------------------------------------------------
# Function App (Elastic Premium — Teams webhook relay)
# ---------------------------------------------------------------------------
# Uses Elastic Premium (EP1) with VNet integration to reach the internal CAE.
# Regular Consumption (Y1) doesn't support VNet integration.  Flex Consumption
# (FC1) was the original choice but prod policy enforces publicNetworkAccess=
# Disabled and allowSharedKeyAccess=false on storage accounts, which breaks
# Flex Consumption's Kudu-based deployment pipeline.  EP1 with
# azurerm_linux_function_app supports `func azure functionapp publish`
# through the Kudu SCM site (which uses ARM auth, not storage shared keys).
resource "azurerm_linux_function_app" "relay" {
  count               = var.msteams_relay_enabled ? 1 : 0
  name                = var.func_relay_name != "" ? var.func_relay_name : "func-relay-${var.environment}"
  location            = azurerm_resource_group.shared.location
  resource_group_name = azurerm_resource_group.shared.name
  service_plan_id     = azurerm_service_plan.relay[0].id

  storage_account_name          = azapi_resource.func_storage[0].name
  storage_uses_managed_identity = true

  virtual_network_subnet_id = azurerm_subnet.func[0].id

  app_settings = {
    CAE_DEFAULT_DOMAIN                = azurerm_container_app_environment.shared.default_domain
    ENVIRONMENT                       = var.environment
    ROUTING_PROVIDER                  = "azure_table"
    ROUTING_STORAGE_ACCOUNT_NAME      = azapi_resource.func_storage[0].name
    ROUTING_TABLE_NAME                = azapi_resource.func_routing_table[0].name
    ROUTING_CACHE_TTL_SEC             = "600"
    ROUTING_FAILURE_THRESHOLD         = "3"
    ROUTING_CIRCUIT_OPEN_SEC          = "60"
    MSTEAMS_EXPECTED_TENANT_ID        = var.msteams_tenant_id
    MSTEAMS_APP_ID                    = var.msteams_app_id
    MSTEAMS_APP_SECRET_VALUE          = var.msteams_app_secret_value != "" ? "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.msteams_app_password[0].versionless_id})" : ""
    MSTEAMS_BOT_TOKEN_TENANT_ID       = var.msteams_tenant_id
    MSTEAMS_BOARD_QUEUE_NAME          = azapi_resource.func_board_queue[0].name
    MSTEAMS_BOARD_UPSTREAM_TIMEOUT_MS = "600000"
    WEBSITE_RUN_FROM_PACKAGE          = "1"
    AzureWebJobsStorage__accountName  = azapi_resource.func_storage[0].name
    AzureWebJobsStorage__credential   = "managedidentity"
    AzureWebJobsStorage__clientId     = azurerm_user_assigned_identity.shared.client_id
  }

  site_config {
    vnet_route_all_enabled = true

    application_stack {
      node_version = "20"
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.shared.id]
  }

  key_vault_reference_identity_id = azurerm_user_assigned_identity.shared.id

  tags = local.tags

  lifecycle {
    ignore_changes = [
      tags["CreatedDate"],
      app_settings["WEBSITE_RUN_FROM_PACKAGE"],
    ]
  }
}

# ---------------------------------------------------------------------------
# Shared Azure Bot Service (single registration for all users)
# ---------------------------------------------------------------------------
# One bot serves all users. The relay Function App routes incoming Bot
# Framework POST requests to the correct per-user Container App based on
# the sender's AAD Object ID (resolved from the Azure Table routing registry).

locals {
  msteams_bot_enabled = var.msteams_relay_enabled && var.msteams_app_id != ""
}

resource "azurerm_bot_service_azure_bot" "shared" {
  count               = local.msteams_bot_enabled ? 1 : 0
  name                = var.bot_name != "" ? var.bot_name : "bot-openclaw-${var.environment}"
  resource_group_name = azurerm_resource_group.shared.name
  location            = "global"
  sku                 = "F0"
  microsoft_app_id    = var.msteams_app_id
  microsoft_app_type  = "SingleTenant"

  microsoft_app_tenant_id = var.msteams_tenant_id

  endpoint = "https://${azurerm_linux_function_app.relay[0].default_hostname}/api/messages"

  tags = local.tags

  lifecycle {
    ignore_changes = [
      endpoint, # May be updated externally
      tags["CreatedDate"],
    ]
  }
}

resource "azurerm_bot_channel_ms_teams" "shared" {
  count               = local.msteams_bot_enabled ? 1 : 0
  bot_name            = azurerm_bot_service_azure_bot.shared[0].name
  resource_group_name = azurerm_resource_group.shared.name
  location            = azurerm_bot_service_azure_bot.shared[0].location
}

# Store the shared bot password in Key Vault (referenced by all user containers)
resource "azurerm_key_vault_secret" "msteams_app_password" {
  count        = local.msteams_bot_enabled && var.msteams_app_secret_value != "" ? 1 : 0
  name         = "shared-msteams-app-password"
  value        = var.msteams_app_secret_value
  key_vault_id = azurerm_key_vault.shared.id
  content_type = "text/plain"
  tags         = local.tags

  lifecycle {
    ignore_changes = [
      value,
      tags["CreatedDate"],
    ]
  }
}
