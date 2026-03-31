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
OCP ?= ./platform/cli/ocp

# Map short-form to internal names used by scripts, Terraform, and env files.
AZURE_ENVIRONMENT      := $(ENV)
USER_SLUG              := $(U)

# Load layered env files directly from config/.
# Per-user values override shared values.
AZURE_ENV_FILE        = config/env/$(ENV).env
LOCAL_AZURE_ENV_FILE  = config/local/$(ENV).env
USER_ENV_FILE         = config/users/$(U).env
LOCAL_USER_ENV_FILE   = config/local/$(ENV).$(U).env
-include $(AZURE_ENV_FILE)
-include $(LOCAL_AZURE_ENV_FILE)
-include $(USER_ENV_FILE)
-include $(LOCAL_USER_ENV_FILE)
export

AZURE_LOCATION         ?= eastus
AZURE_OWNER_SLUG       ?= platform

# Lightweight defaults used by non-ocp local targets.
AZURE_RESOURCE_GROUP ?= rg-openclaw-$(ENV)
AZURE_ACR_NAME       ?= openclaw$(ENV)acr
IMAGE_TAG            ?= latest
IMAGE_REF            ?= $(AZURE_ACR_NAME).azurecr.io/openclaw-golden:$(IMAGE_TAG)

# ---------------------------------------------------------------------------
# .PHONY
# ---------------------------------------------------------------------------
.PHONY: help \
        docker-up docker-down \
        deploy deploy-plan deploy-destroy tf-bootstrap-state \
        naming-check hygiene-check config-bootstrap config-audit config-validate doctor \
        build-image show-image acr-login config-determinism-check \
        add-user add-user-plan remove-user import-user status logs \
        signal-build signal-deploy signal-plan \
        signal-status signal-register signal-logs-cli signal-logs-proxy \
        signal-update-phones \
        teams-manifest teams-manifest-all teams-validate teams-package teams-release-check \
        teams-relay-build teams-relay-deploy \
        deploy-all nuke-all rebuild-all full-rebuild

# ===========================================================================
# HELP
# ===========================================================================

help:
	@echo "openclaw-docker-azure"
	@echo ""
	@echo "CLI:"
	@echo "  ocp config bootstrap --env dev --user alice"
	@echo "  ocp config validate --env dev --user alice"
	@echo "  ocp deploy shared --env dev"
	@echo "  ocp deploy user --env dev --user alice"
	@echo "  ocp status --env dev --user alice"
	@echo "  ocp logs --env dev --user alice"
	@echo "  ocp reset --env dev --nuke-only"
	@echo ""
	@echo "Config source-of-truth:"
	@echo "  Shared:          config/env/<env>.env (+ optional config/local/<env>.env)"
	@echo "  Per-user:        config/users/<slug>.env (+ optional config/local/<env>.<slug>.env)"
	@echo "  Templates only:  *.example.env are committed; real *.env stay local"
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
	@echo "  make naming-check           Validate naming contract and resolved resource names"
	@echo "  make hygiene-check          Fail if forbidden tracked files exist"
	@echo "  make config-bootstrap [U=x] Create missing env files from templates"
	@echo "  make config-audit [U=x]     Show expected config files and stale root env files"
	@echo "  make config-validate [U=x] Validate env files against typed config schema"
	@echo "  make doctor [U=x]          Run local preflight diagnostics (tools/auth/config/naming)"
	@echo ""
	@echo "Golden Image:"
	@echo "  make build-image            Build & push golden image via ACR Tasks"
	@echo "  make show-image             Print the full image reference"
	@echo "  make acr-login              Authenticate Docker to ACR"
	@echo "  make config-determinism-check Verify deterministic runtime config build"
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
	@echo "  make signal-update-phones   Sync SIGNAL_KNOWN_PHONES from config/users/*.env"
	@echo ""
	@echo "Teams Relay:"
	@echo "  make teams-manifest ENV=dev Build Teams manifest for env"
	@echo "  make teams-manifest-all      Build Teams manifests for all envs"
	@echo "  make teams-validate ENV=dev  Validate Teams manifest for env"
	@echo "  make teams-package ENV=dev   Build Teams app zip package for env"
	@echo "  make teams-release-check     Run full local Teams release gate"
	@echo "  make teams-relay-build      Build the Teams relay Function App"
	@echo "  make teams-relay-deploy     Deploy relay (build + shared infra with relay enabled)"
	@echo ""
	@echo "Lifecycle:"
	@echo "  make deploy-all U=x         1-click: shared + image + signal + user"
	@echo "  make nuke-all               Destroy ALL users + shared infra (DANGER)"
	@echo "  make rebuild-all            Rebuild shared infra + ALL users from config/users/*.env"
	@echo "  make full-rebuild           Full nuke then rebuild (DANGER)"

# Guard: require env file exists
define check_env_file
	@test -f $(AZURE_ENV_FILE) || { echo "Missing $(AZURE_ENV_FILE) — run 'make config-bootstrap ENV=$(ENV)$(if $(U), U=$(U),)'"; exit 1; }
endef

define check_prod_destructive_guard
	@if [ "$(ENV)" = "prod" ]; then \
		if [ "$(ALLOW_PROD_DESTRUCTIVE)" != "true" ]; then \
			echo "ERROR: prod destructive action blocked."; \
			echo "Set ALLOW_PROD_DESTRUCTIVE=true and BREAK_GLASS_TICKET=INC-12345 (or CHG-12345)."; \
			exit 1; \
		fi; \
		if [ -z "$(BREAK_GLASS_TICKET)" ]; then \
			echo "ERROR: BREAK_GLASS_TICKET is required for prod destructive actions."; \
			exit 1; \
		fi; \
	fi
endef


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

naming-check: ## Validate naming contract and print resolved names
	$(check_env_file)
	@ENV_NAME=$(ENV) scripts/naming-contract.sh validate
	@echo "Resolved names (ENV=$(ENV)):"
	@echo "  AZURE_RESOURCE_GROUP      = $$(ENV_NAME=$(ENV) scripts/naming-contract.sh get AZURE_RESOURCE_GROUP)"
	@echo "  AZURE_CONTAINERAPPS_ENV   = $$(ENV_NAME=$(ENV) scripts/naming-contract.sh get AZURE_CONTAINERAPPS_ENV)"
	@echo "  AZURE_ACR_NAME            = $$(ENV_NAME=$(ENV) scripts/naming-contract.sh get AZURE_ACR_NAME)"
	@echo "  AZURE_KEY_VAULT_NAME      = $$(ENV_NAME=$(ENV) scripts/naming-contract.sh get AZURE_KEY_VAULT_NAME)"
	@echo "  NFS_SA_NAME               = $$(ENV_NAME=$(ENV) scripts/naming-contract.sh get NFS_SA_NAME)"
	@echo "  CAE_NFS_STORAGE_NAME      = $$(ENV_NAME=$(ENV) scripts/naming-contract.sh get CAE_NFS_STORAGE_NAME)"
	@echo "  TF_STATE_RG               = $$(ENV_NAME=$(ENV) scripts/naming-contract.sh get TF_STATE_RG)"
	@echo "  TF_STATE_SA               = $$(ENV_NAME=$(ENV) scripts/naming-contract.sh get TF_STATE_SA)"
	@echo "  TF_STATE_KEY              = $$(ENV_NAME=$(ENV) scripts/naming-contract.sh get TF_STATE_KEY)"

hygiene-check: ## Fail if forbidden tracked files exist
	@./scripts/hygiene-check.sh

config-bootstrap: ## Ensure local config exists (delegates to ocp)
	@$(OCP) config bootstrap --env "$(ENV)" $(if $(U),--user "$(U)",)

config-audit: ## Show rendered config paths and stale root env files
	@echo "Shared env: $(AZURE_ENV_FILE)"
	@echo "Shared local override: $(LOCAL_AZURE_ENV_FILE)"
	@if [ -n "$(U)" ]; then \
		echo "User env: $(USER_ENV_FILE)"; \
		echo "User local override: $(LOCAL_USER_ENV_FILE)"; \
	fi
	@if ls .env.azure.* >/dev/null 2>&1 || ls .env.user.* >/dev/null 2>&1; then \
		echo "WARNING: legacy root env files detected (deprecated):"; \
		ls -1 .env.azure.* .env.user.* 2>/dev/null | sed '/\.example$$/d' || true; \
	fi

config-validate: ## Validate layered env files against typed schema (delegates to ocp)
	@$(OCP) config validate --env "$(ENV)" $(if $(U),--user "$(U)",)

doctor: ## Run local preflight diagnostics (delegates to ocp)
	@$(OCP) doctor --env "$(ENV)" $(if $(U),--user "$(U)",)

deploy: ## Provision all shared infrastructure (delegates to ocp)
	@$(OCP) deploy shared --env "$(ENV)"

deploy-plan: ## Plan shared infrastructure changes (delegates to ocp)
	@$(OCP) deploy shared --env "$(ENV)" --plan

deploy-destroy: ## Destroy all shared infrastructure (DANGER, delegates to ocp)
	@$(OCP) deploy shared --env "$(ENV)" --destroy

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

config-determinism-check: ## Verify deterministic OpenClaw config assembly
	@./scripts/check-config-determinism.sh

# ===========================================================================
# PER-USER DEPLOYMENT
# ===========================================================================

add-user: ## Deploy an isolated Container App for a user (delegates to ocp)
	@$(OCP) deploy user --env "$(ENV)" --user "$(U)"

add-user-plan: ## Plan a user deployment (dry run, delegates to ocp)
	@$(OCP) deploy user --env "$(ENV)" --user "$(U)" --plan

remove-user: ## Destroy a user's Container App (delegates to ocp)
	@$(OCP) user remove --env "$(ENV)" --user "$(U)"

import-user: ## Import an existing Azure resource into user TF state (R=<addr> ID=<azure_id>)
	@$(OCP) user import --env "$(ENV)" --user "$(U)" --resource "$(R)" --azure-id "$(ID)"

status: ## Show container status (all users, or specific with U=x, delegates to ocp)
	@$(OCP) status --env "$(ENV)" $(if $(U),--user "$(U)",)

logs: ## Tail user's container logs (delegates to ocp)
	@$(OCP) logs --env "$(ENV)" --user "$(U)"

# ===========================================================================
# SIGNAL MESSAGING STACK
# ===========================================================================

signal-build: ## Build & push signal-proxy image to ACR
	@$(OCP) signal build --env "$(ENV)"

signal-deploy: ## Deploy full Signal stack (build proxy + signal-cli + proxy infra)
	@$(OCP) signal deploy --env "$(ENV)"

signal-plan: ## Plan Signal stack deployment (dry run)
	@$(OCP) signal deploy --env "$(ENV)" --plan

signal-status: ## Show status of Signal containers
	@$(OCP) signal status --env "$(ENV)"

signal-register: ## Open shell in signal-cli container for phone registration
	@$(OCP) signal register --env "$(ENV)"

signal-logs-cli: ## Tail signal-cli container logs
	@$(OCP) signal logs-cli --env "$(ENV)"

signal-logs-proxy: ## Tail signal-proxy container logs
	@$(OCP) signal logs-proxy --env "$(ENV)"

signal-update-phones: ## Sync SIGNAL_KNOWN_PHONES on signal-proxy from config/users/*.env
	@$(OCP) signal update-phones --env "$(ENV)"

# ===========================================================================
# TEAMS RELAY (Azure Function — webhook proxy for internal CAE)
# ===========================================================================

teams-manifest: ## Render Teams manifest for ENV (dev|stage|prod)
	@$(OCP) teams manifest --env "$(ENV)"

teams-manifest-all: ## Render Teams manifests for dev, stage, and prod
	@$(OCP) teams manifest-all

teams-validate: ## Validate rendered Teams manifest for ENV
	@$(OCP) teams validate --env "$(ENV)"

teams-package: ## Build Teams package zip for ENV (dev|stage|prod)
	@$(OCP) teams package --env "$(ENV)"

teams-release-check: ## Full local release gate for Teams app
	@$(OCP) teams release-check


teams-relay-build: ## Build the Teams relay Function App
	@$(OCP) teams relay-build --env "$(ENV)"

teams-relay-deploy: ## Deploy relay (build + shared infra with relay enabled)
	@$(OCP) teams relay-deploy --env "$(ENV)"

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
# These operate on ALL users discovered from config/users/*.env.
# ===========================================================================

nuke-all: ## DANGER: Destroy ALL users + shared infra
	$(check_prod_destructive_guard)
	@echo "============================================="
	@echo " NUKE ALL — $(ENV)"
	@echo "============================================="
	@$(OCP) reset --env "$(ENV)" --nuke-only

rebuild-all: ## Rebuild shared infra + ALL users from config/users/*.env
	$(check_prod_destructive_guard)
	@echo "============================================="
	@echo " REBUILD ALL — $(ENV)"
	@echo "============================================="
	@$(OCP) reset --env "$(ENV)" --rebuild-only

full-rebuild: ## DANGER: Full nuke then rebuild (end-to-end)
	$(check_prod_destructive_guard)
	@echo "============================================="
	@echo " FULL REBUILD — $(ENV)"
	@echo "============================================="
	@$(OCP) reset --env "$(ENV)"
