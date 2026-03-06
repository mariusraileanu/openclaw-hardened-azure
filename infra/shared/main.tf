data "azurerm_client_config" "current" {}

locals {
  resource_group_name = "rg-openclaw-shared-${var.environment}"
  cae_name            = "cae-openclaw-shared-${var.environment}"
  acr_name            = "openclawshared${var.environment}acr"
  kv_name             = "kvopenclawshared${var.environment}"
  sa_name             = "stopenclawshared${var.environment}"
  sa_nfs_name         = "nfsopenclawshared${var.environment}"
  vnet_name           = "vnet-openclaw-shared-${var.environment}"
  identity_name       = "id-openclaw-shared-${var.environment}"
  log_analytics_name  = "law-openclaw-shared-${var.environment}"
  nfs_share_name      = "openclaw-data"

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
    ignore_changes = [tags["CreatedDate"]]
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
# Container Apps Environment (VNET-integrated, internal only)
# ---------------------------------------------------------------------------
resource "azurerm_container_app_environment" "shared" {
  name                           = local.cae_name
  location                       = azurerm_resource_group.shared.location
  resource_group_name            = azurerm_resource_group.shared.name
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.shared.id
  infrastructure_subnet_id       = azurerm_subnet.cae.id
  internal_load_balancer_enabled = true
  tags                           = local.tags

  lifecycle {
    ignore_changes = [
      log_analytics_workspace_id,
      infrastructure_resource_group_name, # Azure auto-populates; treating as drift forces CAE replacement
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
resource "azurerm_storage_account" "shared" {
  name                       = local.sa_name
  location                   = azurerm_resource_group.shared.location
  resource_group_name        = azurerm_resource_group.shared.name
  account_tier               = "Standard"
  account_replication_type   = "LRS"
  min_tls_version            = "TLS1_2"
  https_traffic_only_enabled = true
  tags                       = local.tags

  # NOTE: shared_access_key_enabled cannot be set to false because the
  # azurerm provider uses key-based auth to read storage properties.
  # TODO: revisit — azurerm v4.x supports AAD-based data-plane operations.

  # Phase 4b: Blob soft delete (7-day recovery window)
  blob_properties {
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }

  network_rules {
    default_action             = "Deny"
    bypass                     = ["AzureServices"]
    virtual_network_subnet_ids = [azurerm_subnet.cae.id]
    ip_rules                   = local.deployer_ip_list
  }

  # Phase 4c: Prevent accidental destruction of stateful storage
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [tags["CreatedDate"]]
  }
}

# ---------------------------------------------------------------------------
# Premium NFS FileStorage Account (persistent storage for Container Apps)
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "nfs" {
  name                       = local.sa_nfs_name
  location                   = azurerm_resource_group.shared.location
  resource_group_name        = azurerm_resource_group.shared.name
  account_tier               = "Premium"
  account_kind               = "FileStorage"
  account_replication_type   = "LRS"
  min_tls_version            = "TLS1_2"
  https_traffic_only_enabled = false # NFS requires this to be false

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
# NFS mounts require the "NfsAzureFile" storage type, which is only available
# via the Azure CLI / REST API (preview feature). We use a null_resource to
# manage this out-of-band.
resource "null_resource" "nfs_mount" {
  triggers = {
    cae_name = azurerm_container_app_environment.shared.name
    rg_name  = azurerm_resource_group.shared.name
    account  = azurerm_storage_account.nfs.name
    share    = azurerm_storage_share.openclaw_data.name
  }

  provisioner "local-exec" {
    command = <<-EOT
      az containerapp env storage set \
        --name ${self.triggers.cae_name} \
        --resource-group ${self.triggers.rg_name} \
        --storage-name openclaw-nfs \
        --storage-type NfsAzureFile \
        --server ${self.triggers.account}.file.core.windows.net \
        --file-share /${self.triggers.account}/${self.triggers.share} \
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
        --storage-name openclaw-nfs \
        --yes \
        --output none 2>/dev/null || true
    EOT
  }
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

# ---------------------------------------------------------------------------
# VNet Links (so Container Apps can resolve private DNS)
# ---------------------------------------------------------------------------
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
  target_resource_id         = azurerm_storage_account.shared.id
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
      template[0].volume,                     # Managed via null_resource (NfsAzureFile workaround)
      template[0].container[0].volume_mounts, # Added by null_resource after creation
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
    # 400 error. The null_resource.signal_nfs_volume_patch below adds the NFS
    # volume + container volumeMount via REST API after creation.

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

      # NOTE: volume_mounts not defined here — added by null_resource patch

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

# Patch signal-cli: add NfsAzureFile volume + container volumeMount via REST API
# ---------------------------------------------------------------------------
# The azurerm provider cannot create a container app with NfsAzureFile volumes
# (only supports "AzureFile", but the CAE storage is registered as NfsAzureFile).
# So we create the container app bare (no volume/mounts), then this
# null_resource patches in the NFS volume and updates the container spec
# to include the volumeMount — all in a single atomic REST PATCH.
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
            storageName = "openclaw-nfs"
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

resource "null_resource" "signal_nfs_volume_patch" {
  count = var.signal_cli_enabled ? 1 : 0

  triggers = {
    app_id     = azurerm_container_app.signal_cli[0].id
    patch_hash = sha256(local.signal_nfs_patch_body)
  }

  provisioner "local-exec" {
    command = <<-EOT
      for i in $(seq 1 30); do
        state=$(az containerapp show --ids ${azurerm_container_app.signal_cli[0].id} --query "properties.provisioningState" -o tsv 2>/dev/null)
        if [ "$state" = "Succeeded" ] || [ "$state" = "Failed" ]; then break; fi
        sleep 10
      done

      az rest --method PATCH \
        --uri "${azurerm_container_app.signal_cli[0].id}?api-version=2024-03-01" \
        --body '${replace(local.signal_nfs_patch_body, "'", "\\'")}' \
        --output none
    EOT
  }

  depends_on = [azurerm_container_app.signal_cli]
}

# ===========================================================================
# Signal Routing Proxy (SSE fan-out by sender phone number)
# ===========================================================================
# Sits between signal-cli and all user OpenClaw containers. Maintains one
# upstream SSE connection to signal-cli, parses sourceNumber from each event,
# and fans out only to the subscriber matching that phone number.
# User apps connect to /user/{phone}/api/v1/events and /user/{phone}/api/v1/rpc.
# This provides per-user message isolation without modifying signal-cli or OpenClaw.

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
