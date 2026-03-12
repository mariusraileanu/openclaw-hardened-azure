# ===========================================================================
# OpenClaw Azure Platform — Makefile
# Shared Platform + Per-User Isolated Deployment
# ===========================================================================

# ---------------------------------------------------------------------------
# Environment Configuration (override via export or command-line)
# AZURE_ENVIRONMENT must be set BEFORE the env file include so the correct
# file is loaded.  Override on the command line:  make ... AZURE_ENVIRONMENT=prod
# ---------------------------------------------------------------------------
AZURE_ENVIRONMENT      ?= dev

# Load per-environment env file (e.g. .env.azure.dev, .env.azure.prod).
# The leading hyphen suppresses errors when the file does not exist.
-include .env.azure.$(AZURE_ENVIRONMENT)
export

AZURE_LOCATION         ?= eastus
AZURE_OWNER_SLUG       ?= platform

# ---------------------------------------------------------------------------
# Derived Names (naming contract — overridable via env file for non-standard
# environments like prod whose resources were provisioned externally)
# ---------------------------------------------------------------------------
AZURE_RESOURCE_GROUP        ?= rg-openclaw-shared-$(AZURE_ENVIRONMENT)
AZURE_CONTAINERAPPS_ENV     ?= cae-openclaw-shared-$(AZURE_ENVIRONMENT)
AZURE_ACR_NAME              ?= openclawshared$(AZURE_ENVIRONMENT)acr
AZURE_KEY_VAULT_NAME        ?= kvopenclawshared$(AZURE_ENVIRONMENT)
AZURE_STORAGE_ACCOUNT_NAME  ?= stopenclawshared$(AZURE_ENVIRONMENT)

# CAE NFS mount name (registered in the Container Apps Environment)
# Dev default: openclaw-nfs  |  Prod override: openclaw-nfs-prod
CAE_NFS_STORAGE_NAME        ?= openclaw-nfs

IMAGE_TAG ?= latest
IMAGE_REF ?= $(AZURE_ACR_NAME).azurecr.io/openclaw-golden:$(IMAGE_TAG)

# Signal: derive proxy image ref from ACR name
SIGNAL_PROXY_IMAGE = $(AZURE_ACR_NAME).azurecr.io/signal-proxy:$(IMAGE_TAG)

# ---------------------------------------------------------------------------
# Terraform remote state backend (provisioned by infra/bootstrap-state.sh)
# ---------------------------------------------------------------------------
TF_SHARED_DIR   = infra/shared
TF_USER_DIR     = infra/user-app
TF_STATE_RG     ?= rg-openclaw-tfstate-$(AZURE_ENVIRONMENT)
TF_STATE_SA     ?= tfopenclawstate$(AZURE_ENVIRONMENT)

define TF_BACKEND_CONFIG
-backend-config="resource_group_name=$(TF_STATE_RG)" \
-backend-config="storage_account_name=$(TF_STATE_SA)"
endef

.PHONY: help azure-bootstrap azure-bootstrap-destroy \
        acr-build-push acr-show-image \
        azure-deploy-user azure-destroy-user \
        tf-bootstrap-state tf-init-shared tf-init-user tf-workspace-user \
        docker-up docker-down \
        nuke-all rebuild-all full-rebuild \
        signal-deploy signal-deploy-plan signal-build \
        signal-status signal-register signal-logs-cli signal-logs-proxy

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

# ===========================================================================
# HELPERS (deployer IP detection, firewall dance)
# ===========================================================================

# Detect deployer's outbound IPs (machine may egress through different IPs)
DEPLOYER_IPS = $(shell \
	ip1=$$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo ""); \
	ip2=$$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || echo ""); \
	if [ -z "$$ip1" ] && [ -z "$$ip2" ]; then echo ""; \
	elif [ "$$ip1" = "$$ip2" ] || [ -z "$$ip2" ]; then echo "$$ip1"; \
	elif [ -z "$$ip1" ]; then echo "$$ip2"; \
	else echo "$$ip1,$$ip2"; fi)

# Common Terraform vars for the shared module
define TF_SHARED_VARS
-var="environment=$(AZURE_ENVIRONMENT)" \
-var="location=$(AZURE_LOCATION)" \
-var="owner_slug=$(AZURE_OWNER_SLUG)"
endef

# NFS storage account name (for firewall dance)
# Dev default: nfsopenclawshared<env>  |  Prod override in .env.azure.prod
NFS_SA_NAME ?= nfsopenclawshared$(AZURE_ENVIRONMENT)

# ===========================================================================
# SHARED INFRASTRUCTURE
# ===========================================================================

tf-bootstrap-state: ## Provision remote state backend (run once per environment)
	@bash infra/bootstrap-state.sh

tf-init-shared: ## Initialize Terraform for shared infra
	terraform -chdir=$(TF_SHARED_DIR) init $(TF_BACKEND_CONFIG)

azure-bootstrap: tf-init-shared ## Provision all shared infrastructure
	@echo "============================================="
	@echo " Bootstrapping shared infra: $(AZURE_ENVIRONMENT)"
	@echo "============================================="
	@bash infra/shared/import.sh "$(AZURE_ENVIRONMENT)" "$(AZURE_LOCATION)" "$(AZURE_OWNER_SLUG)"
	terraform -chdir=$(TF_SHARED_DIR) apply \
		$(TF_SHARED_VARS)

azure-bootstrap-plan: tf-init-shared ## Plan shared infrastructure changes
	@bash infra/shared/import.sh "$(AZURE_ENVIRONMENT)" "$(AZURE_LOCATION)" "$(AZURE_OWNER_SLUG)"
	terraform -chdir=$(TF_SHARED_DIR) plan \
		$(TF_SHARED_VARS)

azure-bootstrap-destroy: tf-init-shared ## Destroy all shared infrastructure (DANGER)
	terraform -chdir=$(TF_SHARED_DIR) destroy \
		$(TF_SHARED_VARS)

# ===========================================================================
# GOLDEN IMAGE
# ===========================================================================

acr-login: ## Authenticate Docker to ACR
	az acr login --name $(AZURE_ACR_NAME)

acr-build-push: ## Build & push the golden image via ACR Tasks
	@echo "Building golden image: $(AZURE_ACR_NAME).azurecr.io/openclaw-golden:$(IMAGE_TAG)"
	az acr build \
		--registry $(AZURE_ACR_NAME) \
		--image openclaw-golden:$(IMAGE_TAG) \
		--file Dockerfile.wrapper .

acr-show-image: ## Print the full image reference (use with -s for scripting)
	@echo "$(AZURE_ACR_NAME).azurecr.io/openclaw-golden:$(IMAGE_TAG)"

# ===========================================================================
# SIGNAL MESSAGING STACK
# ===========================================================================

signal-build: ## Build & push signal-proxy image to ACR
	@echo "============================================="
	@echo " Building signal-proxy image"
	@echo "============================================="
	@echo "Temporarily opening ACR firewall for build..."
	@az acr update -n $(AZURE_ACR_NAME) --default-action Allow --output none 2>/dev/null || true
	az acr build \
		--registry $(AZURE_ACR_NAME) \
		--image signal-proxy:$(IMAGE_TAG) \
		--file signal-proxy/Dockerfile signal-proxy/
	@echo "Restoring ACR firewall to Deny..."
	@az acr update -n $(AZURE_ACR_NAME) --default-action Deny --output none 2>/dev/null || true
	@echo "Signal-proxy image pushed: $(SIGNAL_PROXY_IMAGE)"

signal-deploy: tf-init-shared signal-build ## Deploy full Signal stack (build proxy + signal-cli + proxy infra)
	@echo "============================================="
	@echo " Deploying Signal stack: $(AZURE_ENVIRONMENT)"
	@echo " Proxy image: $(SIGNAL_PROXY_IMAGE)"
	@echo "============================================="
	@echo "Detected deployer IPs: $(DEPLOYER_IPS)"
	@echo "Temporarily opening NFS firewall for Terraform..."
	@az storage account update --name $(NFS_SA_NAME) --resource-group $(AZURE_RESOURCE_GROUP) \
		--default-action Allow --output none 2>/dev/null || true
	@echo "Waiting 15s for NFS firewall propagation..."
	@sleep 15
	terraform -chdir=$(TF_SHARED_DIR) apply \
		$(TF_SHARED_VARS) \
		-var="deployer_ips=$(DEPLOYER_IPS)" \
		-var="signal_cli_enabled=true" \
		-var="signal_proxy_image=$(SIGNAL_PROXY_IMAGE)" \
		-var="signal_bot_number=$(SIGNAL_BOT_NUMBER)" \
		-var="signal_proxy_auth_token=$(SIGNAL_PROXY_AUTH_TOKEN)"
	@echo "Restoring NFS firewall to Deny..."
	@az storage account update --name $(NFS_SA_NAME) --resource-group $(AZURE_RESOURCE_GROUP) \
		--default-action Deny --output none 2>/dev/null || true
	@echo ""
	@echo "============================================="
	@echo " Signal stack deployed!"
	@echo "============================================="
	@echo "Proxy URL: (sensitive — contains auth token, use 'terraform output signal_cli_url' to view)"
	@echo "Direct URL: $$(terraform -chdir=$(TF_SHARED_DIR) output -raw signal_cli_direct_url 2>/dev/null)"
	@echo ""
	@echo "Next: run 'make signal-register' to register your bot phone number."

signal-deploy-plan: tf-init-shared ## Plan Signal stack deployment (dry run)
	@echo "Detected deployer IPs: $(DEPLOYER_IPS)"
	terraform -chdir=$(TF_SHARED_DIR) plan \
		$(TF_SHARED_VARS) \
		-var="deployer_ips=$(DEPLOYER_IPS)" \
		-var="signal_cli_enabled=true" \
		-var="signal_proxy_image=$(SIGNAL_PROXY_IMAGE)" \
		-var="signal_bot_number=$(SIGNAL_BOT_NUMBER)" \
		-var="signal_proxy_auth_token=$(SIGNAL_PROXY_AUTH_TOKEN)"

signal-status: ## Show status of Signal containers
	@echo "=== signal-cli daemon ==="
	@az containerapp show -n ca-signal-cli-$(AZURE_ENVIRONMENT) -g $(AZURE_RESOURCE_GROUP) \
		--query "{name:name, status:properties.provisioningState, revision:properties.latestRevisionName, fqdn:properties.configuration.ingress.fqdn}" \
		-o table 2>/dev/null || echo "  Not deployed"
	@echo ""
	@echo "=== signal-proxy ==="
	@az containerapp show -n ca-signal-proxy-$(AZURE_ENVIRONMENT) -g $(AZURE_RESOURCE_GROUP) \
		--query "{name:name, status:properties.provisioningState, revision:properties.latestRevisionName, fqdn:properties.configuration.ingress.fqdn}" \
		-o table 2>/dev/null || echo "  Not deployed"

signal-register: ## Open shell in signal-cli container for phone registration
	@echo "Opening shell in signal-cli container..."
	@echo "Run: signal-cli -a +YOURNUMBER register"
	@echo "Then: signal-cli -a +YOURNUMBER verify CODE"
	@echo ""
	az containerapp exec \
		--name ca-signal-cli-$(AZURE_ENVIRONMENT) \
		--resource-group $(AZURE_RESOURCE_GROUP) \
		--command /bin/sh

signal-logs-cli: ## Tail signal-cli container logs
	az containerapp logs show \
		--name ca-signal-cli-$(AZURE_ENVIRONMENT) \
		--resource-group $(AZURE_RESOURCE_GROUP) \
		--follow --tail 100

signal-logs-proxy: ## Tail signal-proxy container logs
	az containerapp logs show \
		--name ca-signal-proxy-$(AZURE_ENVIRONMENT) \
		--resource-group $(AZURE_RESOURCE_GROUP) \
		--follow --tail 100

# ===========================================================================
# PER-USER DEPLOYMENT
# ===========================================================================

# Guard: all required variables must be set
# IMAGE_REF defaults automatically from ACR_NAME + IMAGE_TAG
# GRAPH_MCP_URL is auto-discovered from Azure at deploy time
define check_user_vars
	$(if $(USER_SLUG),,$(error USER_SLUG is required))
	$(if $(COMPASS_API_KEY),,$(error COMPASS_API_KEY is required — set in .env.azure.$(AZURE_ENVIRONMENT)))
	$(if $(OPENCLAW_GATEWAY_AUTH_TOKEN),,$(error OPENCLAW_GATEWAY_AUTH_TOKEN is required — set in .env.azure.$(AZURE_ENVIRONMENT)))
endef
unexport check_user_vars

tf-init-user: ## Initialize Terraform for user-app module
	terraform -chdir=$(TF_USER_DIR) init

tf-workspace-user: ## Select (or create) a per-user Terraform workspace
	$(if $(USER_SLUG),,$(error USER_SLUG is required))
	terraform -chdir=$(TF_USER_DIR) workspace select -or-create $(USER_SLUG)

azure-deploy-user: tf-init-user tf-workspace-user ## Deploy an isolated Container App for a user
	$(call check_user_vars)
	@echo "============================================="
	@echo " Deploying user app: ca-openclaw-$(AZURE_ENVIRONMENT)-$(USER_SLUG)"
	@echo " Image: $(IMAGE_REF)"
	@echo " Environment: $(AZURE_ENVIRONMENT)"
	@echo "============================================="
	$(eval SIGNAL_CLI_URL_TF := $(or $(SIGNAL_CLI_URL),$(shell terraform -chdir=$(TF_SHARED_DIR) output -json signal_cli_url 2>/dev/null | tr -d '"' || echo "")))
	$(eval SIGNAL_PROXY_AUTH_TOKEN_TF := $(or $(SIGNAL_PROXY_AUTH_TOKEN),$(shell terraform -chdir=$(TF_SHARED_DIR) output -json signal_proxy_auth_token 2>/dev/null | tr -d '"' || echo "")))
	$(eval SIGNAL_VARS := )
	$(if $(and $(SIGNAL_CLI_URL_TF),$(SIGNAL_BOT_NUMBER),$(SIGNAL_USER_PHONE)), \
		$(eval SIGNAL_VARS := -var="signal_bot_number=$(SIGNAL_BOT_NUMBER)") \
		$(info Signal enabled: bot=$(SIGNAL_BOT_NUMBER) user=$(SIGNAL_USER_PHONE)), \
		$(info Signal: skipped (missing vars or proxy not deployed)))
	@set -e; \
	echo "--- Discovering GRAPH_MCP_URL for $(USER_SLUG) ---"; \
	GW_FQDN=$$(az containerapp show \
		-n ca-graph-mcp-gw-$(AZURE_ENVIRONMENT)-$(USER_SLUG) \
		-g $(AZURE_RESOURCE_GROUP) \
		--query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null) || true; \
	if [ -z "$$GW_FQDN" ]; then \
		echo "ERROR: MCP gateway ca-graph-mcp-gw-$(AZURE_ENVIRONMENT)-$(USER_SLUG) not found in $(AZURE_RESOURCE_GROUP)."; \
		echo "Deploy the gateway first, then re-run this target."; \
		exit 1; \
	fi; \
	GRAPH_MCP_URL="http://$$GW_FQDN"; \
	echo "GRAPH_MCP_URL=$$GRAPH_MCP_URL"; \
	echo ""; \
	echo "--- Opening firewalls for Terraform ---"; \
	echo "Detected deployer IPs: $(DEPLOYER_IPS)"; \
	az storage account update --name $(NFS_SA_NAME) --resource-group $(AZURE_RESOURCE_GROUP) \
		--default-action Allow --output none; \
	for ip in $$(echo "$(DEPLOYER_IPS)" | tr ',' ' '); do \
		az keyvault network-rule add --name $(AZURE_KEY_VAULT_NAME) --resource-group $(AZURE_RESOURCE_GROUP) \
			--ip-address $$ip/32 --output none 2>/dev/null || true; \
	done; \
	echo "Waiting 15s for firewall propagation..."; \
	sleep 15; \
	echo ""; \
	echo "--- Running Terraform apply ---"; \
	export TF_VAR_compass_base_url="$(COMPASS_BASE_URL)"; \
	export TF_VAR_compass_api_key="$(COMPASS_API_KEY)"; \
	export TF_VAR_openclaw_gateway_auth_token="$(OPENCLAW_GATEWAY_AUTH_TOKEN)"; \
	export TF_VAR_signal_user_phone="$(SIGNAL_USER_PHONE)"; \
	export TF_VAR_signal_cli_url="$(SIGNAL_CLI_URL_TF)"; \
	export TF_VAR_signal_proxy_auth_token="$(SIGNAL_PROXY_AUTH_TOKEN_TF)"; \
	terraform -chdir=$(TF_USER_DIR) apply \
		-var="user_slug=$(USER_SLUG)" \
		-var="environment=$(AZURE_ENVIRONMENT)" \
		-var="location=$(AZURE_LOCATION)" \
		-var="image_ref=$(IMAGE_REF)" \
		-var="graph_mcp_url=$$GRAPH_MCP_URL" \
		-var="resource_group_name=$(AZURE_RESOURCE_GROUP)" \
		-var="key_vault_name=$(AZURE_KEY_VAULT_NAME)" \
		-var="acr_name=$(AZURE_ACR_NAME)" \
		-var="cae_name=$(AZURE_CONTAINERAPPS_ENV)" \
		-var="cae_nfs_storage_name=$(CAE_NFS_STORAGE_NAME)" \
		$(SIGNAL_VARS) ; \
	rc=$$?; \
	echo ""; \
	echo "--- Closing firewalls ---"; \
	az storage account update --name $(NFS_SA_NAME) --resource-group $(AZURE_RESOURCE_GROUP) \
		--default-action Deny --output none 2>/dev/null || true; \
	for ip in $$(echo "$(DEPLOYER_IPS)" | tr ',' ' '); do \
		az keyvault network-rule remove --name $(AZURE_KEY_VAULT_NAME) --resource-group $(AZURE_RESOURCE_GROUP) \
			--ip-address $$ip/32 --output none 2>/dev/null || true; \
	done; \
	if [ $$rc -ne 0 ]; then \
		echo ""; \
		echo "ERROR: Terraform apply failed (exit code $$rc). Firewalls have been closed."; \
		exit $$rc; \
	fi; \
	echo ""; \
	echo "============================================="; \
	echo " User app deployed: ca-openclaw-$(AZURE_ENVIRONMENT)-$(USER_SLUG)"; \
	echo "============================================="; \
	echo "GRAPH_MCP_URL : $$GRAPH_MCP_URL"; \
	echo "Image         : $(IMAGE_REF)"; \
	echo ""; \
	echo "--- Container status ---"; \
	az containerapp show -n ca-openclaw-$(AZURE_ENVIRONMENT)-$(USER_SLUG) -g $(AZURE_RESOURCE_GROUP) \
		--query "{name:name, status:properties.provisioningState, revision:properties.latestRevisionName, fqdn:properties.configuration.ingress.fqdn}" \
		-o table 2>/dev/null || echo "  (could not query container status)"

azure-deploy-user-plan: tf-init-user tf-workspace-user ## Plan a user deployment (dry run)
	$(call check_user_vars)
	$(eval SIGNAL_CLI_URL_TF := $(or $(SIGNAL_CLI_URL),$(shell terraform -chdir=$(TF_SHARED_DIR) output -json signal_cli_url 2>/dev/null | tr -d '"' || echo "")))
	$(eval SIGNAL_PROXY_AUTH_TOKEN_TF := $(or $(SIGNAL_PROXY_AUTH_TOKEN),$(shell terraform -chdir=$(TF_SHARED_DIR) output -json signal_proxy_auth_token 2>/dev/null | tr -d '"' || echo "")))
	$(eval SIGNAL_VARS := )
	$(if $(and $(SIGNAL_CLI_URL_TF),$(SIGNAL_BOT_NUMBER),$(SIGNAL_USER_PHONE)), \
		$(eval SIGNAL_VARS := -var="signal_bot_number=$(SIGNAL_BOT_NUMBER)") \
		$(info Signal enabled: bot=$(SIGNAL_BOT_NUMBER) user=$(SIGNAL_USER_PHONE)), \
		$(info Signal: skipped (missing vars or proxy not deployed)))
	@set -e; \
	echo "--- Discovering GRAPH_MCP_URL for $(USER_SLUG) ---"; \
	GW_FQDN=$$(az containerapp show \
		-n ca-graph-mcp-gw-$(AZURE_ENVIRONMENT)-$(USER_SLUG) \
		-g $(AZURE_RESOURCE_GROUP) \
		--query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null) || true; \
	if [ -z "$$GW_FQDN" ]; then \
		echo "ERROR: MCP gateway ca-graph-mcp-gw-$(AZURE_ENVIRONMENT)-$(USER_SLUG) not found in $(AZURE_RESOURCE_GROUP)."; \
		echo "Deploy the gateway first, then re-run this target."; \
		exit 1; \
	fi; \
	GRAPH_MCP_URL="http://$$GW_FQDN"; \
	echo "GRAPH_MCP_URL=$$GRAPH_MCP_URL"; \
	echo ""; \
	echo "--- Opening firewalls for Terraform ---"; \
	echo "Detected deployer IPs: $(DEPLOYER_IPS)"; \
	az storage account update --name $(NFS_SA_NAME) --resource-group $(AZURE_RESOURCE_GROUP) \
		--default-action Allow --output none; \
	for ip in $$(echo "$(DEPLOYER_IPS)" | tr ',' ' '); do \
		az keyvault network-rule add --name $(AZURE_KEY_VAULT_NAME) --resource-group $(AZURE_RESOURCE_GROUP) \
			--ip-address $$ip/32 --output none 2>/dev/null || true; \
	done; \
	echo "Waiting 15s for firewall propagation..."; \
	sleep 15; \
	echo ""; \
	echo "--- Running Terraform plan ---"; \
	export TF_VAR_compass_base_url="$(COMPASS_BASE_URL)"; \
	export TF_VAR_compass_api_key="$(COMPASS_API_KEY)"; \
	export TF_VAR_openclaw_gateway_auth_token="$(OPENCLAW_GATEWAY_AUTH_TOKEN)"; \
	export TF_VAR_signal_user_phone="$(SIGNAL_USER_PHONE)"; \
	export TF_VAR_signal_cli_url="$(SIGNAL_CLI_URL_TF)"; \
	export TF_VAR_signal_proxy_auth_token="$(SIGNAL_PROXY_AUTH_TOKEN_TF)"; \
	terraform -chdir=$(TF_USER_DIR) plan \
		-var="user_slug=$(USER_SLUG)" \
		-var="environment=$(AZURE_ENVIRONMENT)" \
		-var="location=$(AZURE_LOCATION)" \
		-var="image_ref=$(IMAGE_REF)" \
		-var="graph_mcp_url=$$GRAPH_MCP_URL" \
		-var="resource_group_name=$(AZURE_RESOURCE_GROUP)" \
		-var="key_vault_name=$(AZURE_KEY_VAULT_NAME)" \
		-var="acr_name=$(AZURE_ACR_NAME)" \
		-var="cae_name=$(AZURE_CONTAINERAPPS_ENV)" \
		-var="cae_nfs_storage_name=$(CAE_NFS_STORAGE_NAME)" \
		$(SIGNAL_VARS) ; \
	rc=$$?; \
	echo ""; \
	echo "--- Closing firewalls ---"; \
	az storage account update --name $(NFS_SA_NAME) --resource-group $(AZURE_RESOURCE_GROUP) \
		--default-action Deny --output none 2>/dev/null || true; \
	for ip in $$(echo "$(DEPLOYER_IPS)" | tr ',' ' '); do \
		az keyvault network-rule remove --name $(AZURE_KEY_VAULT_NAME) --resource-group $(AZURE_RESOURCE_GROUP) \
			--ip-address $$ip/32 --output none 2>/dev/null || true; \
	done; \
	if [ $$rc -ne 0 ]; then \
		echo "ERROR: Terraform plan failed (exit code $$rc). Firewalls have been closed."; \
		exit $$rc; \
	fi

azure-destroy-user: tf-init-user tf-workspace-user ## Destroy a user's Container App
	$(if $(USER_SLUG),,$(error USER_SLUG is required))
	@set -e; \
	echo "============================================="; \
	echo " Destroying user app: ca-openclaw-$(AZURE_ENVIRONMENT)-$(USER_SLUG)"; \
	echo " Environment: $(AZURE_ENVIRONMENT)"; \
	echo "============================================="; \
	echo ""; \
	echo "--- Opening firewalls for Terraform ---"; \
	echo "Detected deployer IPs: $(DEPLOYER_IPS)"; \
	az storage account update --name $(NFS_SA_NAME) --resource-group $(AZURE_RESOURCE_GROUP) \
		--default-action Allow --output none; \
	for ip in $$(echo "$(DEPLOYER_IPS)" | tr ',' ' '); do \
		az keyvault network-rule add --name $(AZURE_KEY_VAULT_NAME) --resource-group $(AZURE_RESOURCE_GROUP) \
			--ip-address $$ip/32 --output none 2>/dev/null || true; \
	done; \
	echo "Waiting 15s for firewall propagation..."; \
	sleep 15; \
	echo ""; \
	echo "--- Running Terraform destroy ---"; \
	export TF_VAR_compass_api_key="placeholder"; \
	export TF_VAR_openclaw_gateway_auth_token="placeholder"; \
	terraform -chdir=$(TF_USER_DIR) destroy \
		-var="user_slug=$(USER_SLUG)" \
		-var="environment=$(AZURE_ENVIRONMENT)" \
		-var="location=$(AZURE_LOCATION)" \
		-var="image_ref=placeholder" \
		-var="graph_mcp_url=placeholder" \
		-var="resource_group_name=$(AZURE_RESOURCE_GROUP)" \
		-var="key_vault_name=$(AZURE_KEY_VAULT_NAME)" \
		-var="acr_name=$(AZURE_ACR_NAME)" \
		-var="cae_name=$(AZURE_CONTAINERAPPS_ENV)" \
		-var="cae_nfs_storage_name=$(CAE_NFS_STORAGE_NAME)" ; \
	rc=$$?; \
	echo ""; \
	echo "--- Closing firewalls ---"; \
	az storage account update --name $(NFS_SA_NAME) --resource-group $(AZURE_RESOURCE_GROUP) \
		--default-action Deny --output none 2>/dev/null || true; \
	for ip in $$(echo "$(DEPLOYER_IPS)" | tr ',' ' '); do \
		az keyvault network-rule remove --name $(AZURE_KEY_VAULT_NAME) --resource-group $(AZURE_RESOURCE_GROUP) \
			--ip-address $$ip/32 --output none 2>/dev/null || true; \
	done; \
	if [ $$rc -ne 0 ]; then \
		echo "ERROR: Terraform destroy failed (exit code $$rc). Firewalls have been closed."; \
		exit $$rc; \
	fi; \
	echo ""; \
	echo "============================================="; \
	echo " User app destroyed: ca-openclaw-$(AZURE_ENVIRONMENT)-$(USER_SLUG)"; \
	echo "============================================="; \
	echo "Note: NFS data at /data/$(USER_SLUG)/ is preserved."

# ===========================================================================
# LOCAL TESTING
# ===========================================================================

docker-up: ## Build and start the OpenClaw container locally via Docker Compose
	@echo "Starting local OpenClaw container on http://localhost:18789..."
	docker compose up --build -d
	@echo "Run 'docker compose logs -f' to view logs."

docker-down: ## Stop and remove the local OpenClaw container and its volumes
	docker compose down -v

# ===========================================================================
# 1-CLICK DEPLOYMENT
# ===========================================================================

deploy-all: azure-bootstrap acr-build-push ## 1-Click: Shared Infra + Golden Image + Signal (if set) + User App
	$(eval IMAGE_REF := $(shell make -s acr-show-image))
	@echo "Golden image: $(IMAGE_REF)"
	@if [ -n "$(SIGNAL_BOT_NUMBER)" ]; then \
		echo "SIGNAL_BOT_NUMBER is set — deploying Signal stack..."; \
		$(MAKE) signal-deploy; \
	else \
		echo "SIGNAL_BOT_NUMBER not set — skipping Signal stack"; \
	fi
	@echo "Deploying User App..."
	@IMAGE_REF=$(IMAGE_REF) $(MAKE) azure-deploy-user

# ===========================================================================
# NUKE & REBUILD (see REBUILD.md for full details)
# ===========================================================================

nuke-all: ## DANGER: Destroy everything (all container apps + shared infra + clean state)
	@echo "============================================="
	@echo " NUKE ALL — $(AZURE_ENVIRONMENT)"
	@echo "============================================="
	./rebuild.sh --nuke-only

rebuild-all: ## Rebuild from scratch (shared infra + golden image + user app)
	@echo "============================================="
	@echo " REBUILD ALL — $(AZURE_ENVIRONMENT)"
	@echo "============================================="
	./rebuild.sh --rebuild-only

full-rebuild: ## DANGER: Full nuke then rebuild (end-to-end)
	@echo "============================================="
	@echo " FULL REBUILD — $(AZURE_ENVIRONMENT)"
	@echo "============================================="
	./rebuild.sh
