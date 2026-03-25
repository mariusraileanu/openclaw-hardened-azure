# ===========================================================================
# OpenClaw Azure Platform — Makefile
# Shared Platform + Per-User Isolated Deployment
# ===========================================================================

# ---------------------------------------------------------------------------
# User-facing variables (short-form)
#   ENV  — environment label (dev, prod, …)
#   U    — user slug (alice, bob, …)
# Override on the command line:  make add-user U=alice ENV=prod
# ---------------------------------------------------------------------------
ENV ?= dev
U   ?=

# Map short-form to internal names used by scripts, Terraform, and env files.
AZURE_ENVIRONMENT      := $(ENV)
USER_SLUG              := $(U)

# Load per-environment env file (e.g. .env.azure.dev, .env.azure.prod)
# then per-user overrides (e.g. .env.user.alice).  Per-user values win.
# The leading hyphen suppresses errors when a file does not exist.
AZURE_ENV_FILE  = .env.azure.$(ENV)
USER_ENV_FILE   = .env.user.$(U)
-include $(AZURE_ENV_FILE)
-include $(USER_ENV_FILE)
export

AZURE_LOCATION         ?= eastus
AZURE_OWNER_SLUG       ?= platform

# ---------------------------------------------------------------------------
# Derived Names (naming contract — overridable via env file for non-standard
# environments like prod whose resources were provisioned externally)
# ---------------------------------------------------------------------------
AZURE_RESOURCE_GROUP        ?= rg-openclaw-shared-$(ENV)
AZURE_CONTAINERAPPS_ENV     ?= cae-openclaw-shared-$(ENV)
AZURE_ACR_NAME              ?= openclawshared$(ENV)acr
AZURE_KEY_VAULT_NAME        ?= kvopenclawshared$(ENV)
AZURE_STORAGE_ACCOUNT_NAME  ?= stopenclawshared$(ENV)

# CAE NFS mount name (registered in the Container Apps Environment)
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
TF_STATE_RG     ?= rg-openclaw-tfstate-$(ENV)
TF_STATE_SA     ?= tfopenclawstate$(ENV)

define TF_BACKEND_CONFIG
-backend-config="resource_group_name=$(TF_STATE_RG)" \
-backend-config="storage_account_name=$(TF_STATE_SA)"
endef

# ---------------------------------------------------------------------------
# .PHONY
# ---------------------------------------------------------------------------
.PHONY: help \
        docker-up docker-down \
        deploy deploy-plan deploy-destroy tf-bootstrap-state \
        build-image show-image acr-login \
        add-user add-user-plan remove-user status logs \
        signal-build signal-deploy signal-plan \
        signal-status signal-register signal-logs-cli signal-logs-proxy \
        signal-update-phones \
        deploy-all nuke-all rebuild-all full-rebuild

# ===========================================================================
# HELP
# ===========================================================================

help:
	@echo "openclaw-docker-azure"
	@echo ""
	@echo "Config files:"
	@echo "  Shared infra:    .env.azure.<env>   (see .env.azure.example)"
	@echo "  Per-user:        .env.user.<slug>    (see .env.user.example)"
	@echo ""
	@echo "Local:"
	@echo "  make docker-up              Build and start locally via Docker Compose"
	@echo "  make docker-down            Stop and remove local container"
	@echo ""
	@echo "Shared Infrastructure (ENV=dev by default, override with ENV=prod):"
	@echo "  make deploy                 Provision shared infra (RG, VNet, CAE, ACR, KV, NFS)"
	@echo "  make deploy-plan            Dry-run shared infra changes"
	@echo "  make deploy-destroy         Destroy all shared infra (DANGER)"
	@echo "  make tf-bootstrap-state     Provision remote TF state backend (run once)"
	@echo ""
	@echo "Golden Image:"
	@echo "  make build-image            Build & push golden image via ACR Tasks"
	@echo "  make show-image             Print the full image reference"
	@echo "  make acr-login              Authenticate Docker to ACR"
	@echo ""
	@echo "Per-User (U=<slug> required, ENV=dev by default):"
	@echo "  make add-user U=x           Deploy Container App for user"
	@echo "  make add-user U=x ENV=prod  Deploy to prod environment"
	@echo "  make add-user-plan U=x      Dry-run user deployment"
	@echo "  make remove-user U=x        Destroy user's Container App"
	@echo "  make import-user U=x R=<tf_addr> ID=<azure_id>  Import existing Azure resource into TF state"
	@echo "  make status [U=x]           Show container status (all or specific user)"
	@echo "  make logs U=x               Tail user's container logs"
	@echo ""
	@echo "Signal Messaging:"
	@echo "  make signal-build           Build & push signal-proxy image"
	@echo "  make signal-deploy          Deploy full Signal stack (build + infra)"
	@echo "  make signal-plan            Dry-run Signal deployment"
	@echo "  make signal-status          Show Signal container status"
	@echo "  make signal-register        Open shell for phone registration"
	@echo "  make signal-logs-cli        Tail signal-cli logs"
	@echo "  make signal-logs-proxy      Tail signal-proxy logs"
	@echo "  make signal-update-phones   Sync SIGNAL_KNOWN_PHONES from .env.user.* files"
	@echo ""
	@echo "Lifecycle:"
	@echo "  make deploy-all U=x         1-click: shared + image + signal + user"
	@echo "  make nuke-all               Destroy ALL users + shared infra (DANGER)"
	@echo "  make rebuild-all            Rebuild shared infra + ALL users from .env.user.* files"
	@echo "  make full-rebuild           Full nuke then rebuild (DANGER)"

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
-var="environment=$(ENV)" \
-var="location=$(AZURE_LOCATION)" \
-var="owner_slug=$(AZURE_OWNER_SLUG)"
endef

# NFS storage account name (for firewall dance)
NFS_SA_NAME ?= nfsopenclawshared$(ENV)

# Guard: require env file exists
define check_env_file
	@test -f $(AZURE_ENV_FILE) || { echo "Missing $(AZURE_ENV_FILE) — copy from .env.azure.example"; exit 1; }
endef

# Guard: require U=<slug>
define check_user
	@[ -n "$(U)" ] || { echo "Usage: make $@ U=<slug> [ENV=$(ENV)]"; exit 1; }
endef

# Guard: all required user-deploy variables must be set
define check_user_vars
	$(if $(USER_SLUG),,$(error USER_SLUG is required — pass U=<slug>))
	$(if $(COMPASS_API_KEY),,$(error COMPASS_API_KEY is required — set in $(AZURE_ENV_FILE) or $(USER_ENV_FILE)))
	$(if $(OPENCLAW_GATEWAY_AUTH_TOKEN),,$(error OPENCLAW_GATEWAY_AUTH_TOKEN is required — set in $(AZURE_ENV_FILE) or $(USER_ENV_FILE)))
endef
unexport check_user_vars

# ===========================================================================
# LOCAL TESTING
# ===========================================================================

docker-up: ## Build and start locally via Docker Compose
	@echo "Starting local OpenClaw container on http://localhost:18789..."
	docker compose up --build -d
	@echo "Run 'docker compose logs -f' to view logs."

docker-down: ## Stop and remove local container and volumes
	docker compose down -v

# ===========================================================================
# SHARED INFRASTRUCTURE
# ===========================================================================

tf-bootstrap-state: ## Provision remote TF state backend (run once)
	@bash infra/bootstrap-state.sh

_tf-init-shared:
	terraform -chdir=$(TF_SHARED_DIR) init $(TF_BACKEND_CONFIG)

deploy: _tf-init-shared ## Provision all shared infrastructure
	$(check_env_file)
	@echo "▸ Deploying shared infra to [$(ENV)] using $(AZURE_ENV_FILE)"
	@bash infra/shared/import.sh "$(ENV)" "$(AZURE_LOCATION)" "$(AZURE_OWNER_SLUG)"
	terraform -chdir=$(TF_SHARED_DIR) apply \
		$(TF_SHARED_VARS)

deploy-plan: _tf-init-shared ## Plan shared infrastructure changes
	$(check_env_file)
	@echo "▸ Planning shared infra for [$(ENV)] using $(AZURE_ENV_FILE)"
	@bash infra/shared/import.sh "$(ENV)" "$(AZURE_LOCATION)" "$(AZURE_OWNER_SLUG)"
	terraform -chdir=$(TF_SHARED_DIR) plan \
		$(TF_SHARED_VARS)

deploy-destroy: _tf-init-shared ## Destroy all shared infrastructure (DANGER)
	$(check_env_file)
	@echo "▸ Destroying shared infra for [$(ENV)] using $(AZURE_ENV_FILE)"
	terraform -chdir=$(TF_SHARED_DIR) destroy \
		$(TF_SHARED_VARS)

# ===========================================================================
# GOLDEN IMAGE
# ===========================================================================

acr-login: ## Authenticate Docker to ACR
	az acr login --name $(AZURE_ACR_NAME)

build-image: ## Build & push the golden image via ACR Tasks
	$(check_env_file)
	@echo "▸ Building golden image for [$(ENV)]: $(IMAGE_REF)"
	az acr build \
		--registry $(AZURE_ACR_NAME) \
		--image openclaw-golden:$(IMAGE_TAG) \
		--file Dockerfile.wrapper .

show-image: ## Print the full image reference
	@echo "$(IMAGE_REF)"

# ===========================================================================
# PER-USER DEPLOYMENT
# ===========================================================================

_tf-init-user:
	terraform -chdir=$(TF_USER_DIR) init

_tf-workspace-user:
	$(if $(USER_SLUG),,$(error USER_SLUG is required — pass U=<slug>))
	terraform -chdir=$(TF_USER_DIR) workspace select -or-create $(USER_SLUG)

add-user: _tf-init-user _tf-workspace-user ## Deploy an isolated Container App for a user
	$(check_user)
	$(check_env_file)
	$(call check_user_vars)
	@echo "▸ Adding user '$(U)' to [$(ENV)] using $(AZURE_ENV_FILE)"
	@echo "  Container: ca-openclaw-$(ENV)-$(U)"
	@echo "  Image:     $(IMAGE_REF)"
	$(eval SIGNAL_CLI_URL_TF := $(or $(SIGNAL_CLI_URL),$(shell terraform -chdir=$(TF_SHARED_DIR) output -json signal_cli_url 2>/dev/null | tr -d '"' || echo "")))
	$(eval SIGNAL_PROXY_AUTH_TOKEN_TF := $(or $(SIGNAL_PROXY_AUTH_TOKEN),$(shell terraform -chdir=$(TF_SHARED_DIR) output -json signal_proxy_auth_token 2>/dev/null | tr -d '"' || echo "")))
	$(eval SIGNAL_VARS := )
	$(if $(and $(SIGNAL_CLI_URL_TF),$(SIGNAL_BOT_NUMBER),$(SIGNAL_USER_PHONE)), \
		$(eval SIGNAL_VARS := -var="signal_bot_number=$(SIGNAL_BOT_NUMBER)") \
		$(info Signal enabled: bot=$(SIGNAL_BOT_NUMBER) user=$(SIGNAL_USER_PHONE)), \
		$(info Signal: skipped (missing vars or proxy not deployed)))
	@set -e; \
	echo "--- Discovering GRAPH_MCP_URL for $(U) ---"; \
	GW_FQDN=$$(az containerapp show \
		-n ca-graph-mcp-gw-$(ENV)-$(U) \
		-g $(AZURE_RESOURCE_GROUP) \
		--query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null) || true; \
	if [ -z "$$GW_FQDN" ]; then \
		echo "ERROR: MCP gateway ca-graph-mcp-gw-$(ENV)-$(U) not found in $(AZURE_RESOURCE_GROUP)."; \
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
	export TF_VAR_tavily_api_key="$(TAVILY_API_KEY)"; \
	export TF_VAR_signal_user_phone="$(SIGNAL_USER_PHONE)"; \
	export TF_VAR_signal_cli_url="$(SIGNAL_CLI_URL_TF)"; \
	export TF_VAR_signal_proxy_auth_token="$(SIGNAL_PROXY_AUTH_TOKEN_TF)"; \
	terraform -chdir=$(TF_USER_DIR) apply -auto-approve \
		-var="user_slug=$(U)" \
		-var="environment=$(ENV)" \
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
	echo " User app deployed: ca-openclaw-$(ENV)-$(U)"; \
	echo "============================================="; \
	echo "GRAPH_MCP_URL : $$GRAPH_MCP_URL"; \
	echo "Image         : $(IMAGE_REF)"; \
	echo ""; \
	echo "--- Container status ---"; \
	az containerapp show -n ca-openclaw-$(ENV)-$(U) -g $(AZURE_RESOURCE_GROUP) \
		--query "{name:name, status:properties.provisioningState, revision:properties.latestRevisionName, fqdn:properties.configuration.ingress.fqdn}" \
		-o table 2>/dev/null || echo "  (could not query container status)"
	@$(MAKE) signal-update-phones ENV=$(ENV) 2>/dev/null || echo "  (signal-update-phones skipped — non-fatal)"

add-user-plan: _tf-init-user _tf-workspace-user ## Plan a user deployment (dry run)
	$(check_user)
	$(check_env_file)
	$(call check_user_vars)
	@echo "▸ Planning user '$(U)' on [$(ENV)] using $(AZURE_ENV_FILE)"
	$(eval SIGNAL_CLI_URL_TF := $(or $(SIGNAL_CLI_URL),$(shell terraform -chdir=$(TF_SHARED_DIR) output -json signal_cli_url 2>/dev/null | tr -d '"' || echo "")))
	$(eval SIGNAL_PROXY_AUTH_TOKEN_TF := $(or $(SIGNAL_PROXY_AUTH_TOKEN),$(shell terraform -chdir=$(TF_SHARED_DIR) output -json signal_proxy_auth_token 2>/dev/null | tr -d '"' || echo "")))
	$(eval SIGNAL_VARS := )
	$(if $(and $(SIGNAL_CLI_URL_TF),$(SIGNAL_BOT_NUMBER),$(SIGNAL_USER_PHONE)), \
		$(eval SIGNAL_VARS := -var="signal_bot_number=$(SIGNAL_BOT_NUMBER)") \
		$(info Signal enabled: bot=$(SIGNAL_BOT_NUMBER) user=$(SIGNAL_USER_PHONE)), \
		$(info Signal: skipped (missing vars or proxy not deployed)))
	@set -e; \
	echo "--- Discovering GRAPH_MCP_URL for $(U) ---"; \
	GW_FQDN=$$(az containerapp show \
		-n ca-graph-mcp-gw-$(ENV)-$(U) \
		-g $(AZURE_RESOURCE_GROUP) \
		--query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null) || true; \
	if [ -z "$$GW_FQDN" ]; then \
		echo "ERROR: MCP gateway ca-graph-mcp-gw-$(ENV)-$(U) not found in $(AZURE_RESOURCE_GROUP)."; \
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
	export TF_VAR_tavily_api_key="$(TAVILY_API_KEY)"; \
	export TF_VAR_signal_user_phone="$(SIGNAL_USER_PHONE)"; \
	export TF_VAR_signal_cli_url="$(SIGNAL_CLI_URL_TF)"; \
	export TF_VAR_signal_proxy_auth_token="$(SIGNAL_PROXY_AUTH_TOKEN_TF)"; \
	terraform -chdir=$(TF_USER_DIR) plan \
		-var="user_slug=$(U)" \
		-var="environment=$(ENV)" \
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

remove-user: _tf-init-user _tf-workspace-user ## Destroy a user's Container App
	$(check_user)
	$(check_env_file)
	@echo "▸ Removing user '$(U)' from [$(ENV)] using $(AZURE_ENV_FILE)"
	@set -e; \
	echo "============================================="; \
	echo " Destroying user app: ca-openclaw-$(ENV)-$(U)"; \
	echo " Environment: $(ENV)"; \
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
		-var="user_slug=$(U)" \
		-var="environment=$(ENV)" \
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
	echo " User app destroyed: ca-openclaw-$(ENV)-$(U)"; \
	echo "============================================="; \
	echo "Note: NFS data at /data/$(U)/ is preserved."
	@$(MAKE) signal-update-phones ENV=$(ENV) 2>/dev/null || echo "  (signal-update-phones skipped — non-fatal)"

import-user: _tf-init-user _tf-workspace-user ## Import an existing Azure resource into user TF state (R=<addr> ID=<azure_id>)
	$(check_user)
	$(check_env_file)
	@[ -n "$(R)" ] || { echo "Usage: make import-user U=<slug> R=<tf_resource_addr> ID=<azure_resource_id> [ENV=$(ENV)]"; exit 1; }
	@[ -n "$(ID)" ] || { echo "Usage: make import-user U=<slug> R=<tf_resource_addr> ID=<azure_resource_id> [ENV=$(ENV)]"; exit 1; }
	@echo "▸ Importing resource into TF state for user '$(U)' on [$(ENV)]"
	@echo "  Resource: $(R)"
	@echo "  ID:       $(ID)"
	$(eval SIGNAL_CLI_URL_TF := $(or $(SIGNAL_CLI_URL),$(shell terraform -chdir=$(TF_SHARED_DIR) output -json signal_cli_url 2>/dev/null | tr -d '"' || echo "")))
	$(eval SIGNAL_PROXY_AUTH_TOKEN_TF := $(or $(SIGNAL_PROXY_AUTH_TOKEN),$(shell terraform -chdir=$(TF_SHARED_DIR) output -json signal_proxy_auth_token 2>/dev/null | tr -d '"' || echo "")))
	$(eval SIGNAL_VARS := )
	$(if $(and $(SIGNAL_CLI_URL_TF),$(SIGNAL_BOT_NUMBER),$(SIGNAL_USER_PHONE)), \
		$(eval SIGNAL_VARS := -var="signal_bot_number=$(SIGNAL_BOT_NUMBER)"), \
		)
	@set -e; \
	echo "--- Discovering GRAPH_MCP_URL for $(U) ---"; \
	GW_FQDN=$$(az containerapp show \
		-n ca-graph-mcp-gw-$(ENV)-$(U) \
		-g $(AZURE_RESOURCE_GROUP) \
		--query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null) || true; \
	if [ -z "$$GW_FQDN" ]; then \
		echo "WARNING: MCP gateway ca-graph-mcp-gw-$(ENV)-$(U) not found. Using placeholder."; \
		GRAPH_MCP_URL="placeholder"; \
	else \
		GRAPH_MCP_URL="http://$$GW_FQDN"; \
	fi; \
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
	echo "--- Running Terraform import ---"; \
	export TF_VAR_compass_base_url="$(COMPASS_BASE_URL)"; \
	export TF_VAR_compass_api_key="$(COMPASS_API_KEY)"; \
	export TF_VAR_openclaw_gateway_auth_token="$(OPENCLAW_GATEWAY_AUTH_TOKEN)"; \
	export TF_VAR_tavily_api_key="$(TAVILY_API_KEY)"; \
	export TF_VAR_signal_user_phone="$(SIGNAL_USER_PHONE)"; \
	export TF_VAR_signal_cli_url="$(SIGNAL_CLI_URL_TF)"; \
	export TF_VAR_signal_proxy_auth_token="$(SIGNAL_PROXY_AUTH_TOKEN_TF)"; \
	terraform -chdir=$(TF_USER_DIR) import \
		-var="user_slug=$(U)" \
		-var="environment=$(ENV)" \
		-var="location=$(AZURE_LOCATION)" \
		-var="image_ref=$(IMAGE_REF)" \
		-var="graph_mcp_url=$$GRAPH_MCP_URL" \
		-var="resource_group_name=$(AZURE_RESOURCE_GROUP)" \
		-var="key_vault_name=$(AZURE_KEY_VAULT_NAME)" \
		-var="acr_name=$(AZURE_ACR_NAME)" \
		-var="cae_name=$(AZURE_CONTAINERAPPS_ENV)" \
		-var="cae_nfs_storage_name=$(CAE_NFS_STORAGE_NAME)" \
		$(SIGNAL_VARS) \
		"$(R)" "$(ID)"; \
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
		echo "ERROR: Terraform import failed (exit code $$rc). Firewalls have been closed."; \
		exit $$rc; \
	fi; \
	echo ""; \
	echo "============================================="; \
	echo " Imported $(R) into $(U) workspace"; \
	echo "============================================="

status: ## Show container status (all users, or specific with U=x)
	$(check_env_file)
	@echo "▸ Status for [$(ENV)] using $(AZURE_ENV_FILE)"
	@if [ -n "$(U)" ]; then \
		echo ""; \
		echo "=== ca-openclaw-$(ENV)-$(U) ==="; \
		az containerapp show -n ca-openclaw-$(ENV)-$(U) -g $(AZURE_RESOURCE_GROUP) \
			--query "{name:name, status:properties.provisioningState, revision:properties.latestRevisionName, fqdn:properties.configuration.ingress.fqdn}" \
			-o table 2>/dev/null || echo "  Not deployed"; \
	else \
		echo ""; \
		echo "=== All OpenClaw container apps in $(AZURE_RESOURCE_GROUP) ==="; \
		az containerapp list -g $(AZURE_RESOURCE_GROUP) \
			--query "[?starts_with(name,'ca-openclaw-')].{name:name, status:properties.provisioningState, revision:properties.latestRevisionName}" \
			-o table 2>/dev/null || echo "  None found"; \
	fi

logs: ## Tail user's container logs
	$(check_user)
	$(check_env_file)
	@echo "▸ Logs for '$(U)' on [$(ENV)] using $(AZURE_ENV_FILE)"
	az containerapp logs show \
		--name ca-openclaw-$(ENV)-$(U) \
		--resource-group $(AZURE_RESOURCE_GROUP) \
		--follow --tail 100

# ===========================================================================
# SIGNAL MESSAGING STACK
# ===========================================================================

signal-build: ## Build & push signal-proxy image to ACR
	$(check_env_file)
	@echo "▸ Building signal-proxy image for [$(ENV)]"
	@echo "Temporarily opening ACR firewall for build..."
	@az acr update -n $(AZURE_ACR_NAME) --default-action Allow --output none 2>/dev/null || true
	az acr build \
		--registry $(AZURE_ACR_NAME) \
		--image signal-proxy:$(IMAGE_TAG) \
		--file signal-proxy/Dockerfile signal-proxy/
	@echo "Restoring ACR firewall to Deny..."
	@az acr update -n $(AZURE_ACR_NAME) --default-action Deny --output none 2>/dev/null || true
	@echo "Signal-proxy image pushed: $(SIGNAL_PROXY_IMAGE)"

signal-deploy: _tf-init-shared signal-build ## Deploy full Signal stack (build proxy + signal-cli + proxy infra)
	$(check_env_file)
	@echo "▸ Deploying Signal stack to [$(ENV)]"
	@echo "  Proxy image: $(SIGNAL_PROXY_IMAGE)"
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
	@$(MAKE) signal-update-phones ENV=$(ENV) 2>/dev/null || echo "  (signal-update-phones skipped — non-fatal)"

signal-plan: _tf-init-shared ## Plan Signal stack deployment (dry run)
	$(check_env_file)
	@echo "▸ Planning Signal stack for [$(ENV)]"
	@echo "Detected deployer IPs: $(DEPLOYER_IPS)"
	terraform -chdir=$(TF_SHARED_DIR) plan \
		$(TF_SHARED_VARS) \
		-var="deployer_ips=$(DEPLOYER_IPS)" \
		-var="signal_cli_enabled=true" \
		-var="signal_proxy_image=$(SIGNAL_PROXY_IMAGE)" \
		-var="signal_bot_number=$(SIGNAL_BOT_NUMBER)" \
		-var="signal_proxy_auth_token=$(SIGNAL_PROXY_AUTH_TOKEN)"

signal-status: ## Show status of Signal containers
	$(check_env_file)
	@echo "▸ Signal status for [$(ENV)]"
	@echo ""
	@echo "=== signal-cli daemon ==="
	@az containerapp show -n ca-signal-cli-$(ENV) -g $(AZURE_RESOURCE_GROUP) \
		--query "{name:name, status:properties.provisioningState, revision:properties.latestRevisionName, fqdn:properties.configuration.ingress.fqdn}" \
		-o table 2>/dev/null || echo "  Not deployed"
	@echo ""
	@echo "=== signal-proxy ==="
	@az containerapp show -n ca-signal-proxy-$(ENV) -g $(AZURE_RESOURCE_GROUP) \
		--query "{name:name, status:properties.provisioningState, revision:properties.latestRevisionName, fqdn:properties.configuration.ingress.fqdn}" \
		-o table 2>/dev/null || echo "  Not deployed"

signal-register: ## Open shell in signal-cli container for phone registration
	$(check_env_file)
	@echo "Opening shell in signal-cli container..."
	@echo "Run: signal-cli -a +YOURNUMBER register"
	@echo "Then: signal-cli -a +YOURNUMBER verify CODE"
	@echo ""
	az containerapp exec \
		--name ca-signal-cli-$(ENV) \
		--resource-group $(AZURE_RESOURCE_GROUP) \
		--command /bin/sh

signal-logs-cli: ## Tail signal-cli container logs
	$(check_env_file)
	az containerapp logs show \
		--name ca-signal-cli-$(ENV) \
		--resource-group $(AZURE_RESOURCE_GROUP) \
		--follow --tail 100

signal-logs-proxy: ## Tail signal-proxy container logs
	$(check_env_file)
	az containerapp logs show \
		--name ca-signal-proxy-$(ENV) \
		--resource-group $(AZURE_RESOURCE_GROUP) \
		--follow --tail 100

signal-update-phones: ## Sync SIGNAL_KNOWN_PHONES on signal-proxy from .env.user.* files
	$(check_env_file)
	@[ -n "$(SIGNAL_BOT_NUMBER)" ] || { echo "SIGNAL_BOT_NUMBER not set — skipping signal-update-phones"; exit 0; }
	@echo "▸ Updating SIGNAL_KNOWN_PHONES on ca-signal-proxy-$(ENV)"
	@PHONES="$(SIGNAL_BOT_NUMBER)"; \
	for f in .env.user.*; do \
		case "$$f" in *.example|*.swp|*~) continue ;; esac; \
		[ -f "$$f" ] || continue; \
		p=$$(grep -E '^SIGNAL_USER_PHONE=' "$$f" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' "'"'"''); \
		if [ -n "$$p" ]; then \
			PHONES="$$PHONES,$$p"; \
		fi; \
	done; \
	echo "  Phones: $$PHONES"; \
	az containerapp update \
		--name ca-signal-proxy-$(ENV) \
		--resource-group $(AZURE_RESOURCE_GROUP) \
		--set-env-vars "SIGNAL_KNOWN_PHONES=$$PHONES" \
		--output none; \
	echo "  SIGNAL_KNOWN_PHONES updated on ca-signal-proxy-$(ENV)"

# ===========================================================================
# 1-CLICK DEPLOYMENT
# ===========================================================================

deploy-all: deploy build-image ## 1-Click: Shared Infra + Golden Image + Signal (if set) + User App
	$(eval IMAGE_REF := $(shell make -s show-image))
	@echo "Golden image: $(IMAGE_REF)"
	@if [ -n "$(SIGNAL_BOT_NUMBER)" ]; then \
		echo "SIGNAL_BOT_NUMBER is set — deploying Signal stack..."; \
		$(MAKE) signal-deploy; \
	else \
		echo "SIGNAL_BOT_NUMBER not set — skipping Signal stack"; \
	fi
	@echo "Deploying User App..."
	@IMAGE_REF=$(IMAGE_REF) $(MAKE) add-user

# ===========================================================================
# PLATFORM RESET (see REBUILD.md for full details)
# These operate on ALL users discovered from .env.user.* files.
# ===========================================================================

nuke-all: ## DANGER: Destroy ALL users + shared infra
	@echo "============================================="
	@echo " NUKE ALL — $(ENV)"
	@echo "============================================="
	./platform-reset.sh -e $(ENV) --nuke-only

rebuild-all: ## Rebuild shared infra + ALL users from .env.user.* files
	@echo "============================================="
	@echo " REBUILD ALL — $(ENV)"
	@echo "============================================="
	./platform-reset.sh -e $(ENV) --rebuild-only

full-rebuild: ## DANGER: Full nuke then rebuild (end-to-end)
	@echo "============================================="
	@echo " FULL REBUILD — $(ENV)"
	@echo "============================================="
	./platform-reset.sh -e $(ENV)
