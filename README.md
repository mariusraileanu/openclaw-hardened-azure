# OpenClaw Azure Platform

Shared-platform, per-user isolated deployment of OpenClaw on Azure Container Apps.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Resource Group: rg-openclaw-shared-<env>                       │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  VNET: vnet-openclaw-shared-<env>  (10.0.0.0/16)        │   │
│  │  ┌────────────────────────────────────────────────────┐  │   │
│  │  │  Container Apps Env (internal-only):               │  │   │
│  │  │  cae-openclaw-shared-<env>                         │  │   │
│  │  │                                                    │  │   │
│  │  │  ┌──────────┐ ┌──────────┐ ┌──────────┐           │  │   │
│  │  │  │oc-alice  │ │oc-bob    │ │oc-carol  │  ...      │  │   │
│  │  │  └──────────┘ └──────────┘ └──────────┘           │  │   │
│  │  └────────────────────────────────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌────────────┐  ┌────────────┐  ┌─────────────┐               │
│  │ ACR        │  │ Key Vault  │  │ Storage     │               │
│  │ (Premium)  │  │ (RBAC)     │  │ Account     │               │
│  └────────────┘  └────────────┘  └─────────────┘               │
│                                                                 │
│  ┌──────────────────────────────┐                               │
│  │ Managed Identity             │                               │
│  │ (AcrPull + KV Secrets User) │                               │
│  └──────────────────────────────┘                               │
└─────────────────────────────────────────────────────────────────┘
```

**Key principles:**
- One shared resource group, VNet, ACR, Key Vault per environment
- Each user gets an isolated Container App (`oc-<slug>`)
- All secrets stored in Key Vault, injected via Managed Identity at runtime
- Internal-only networking -- no public endpoints
- Golden image pattern -- upstream OpenClaw wrapped with enterprise config

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) >= 2.50
- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.5
- An Azure subscription with Owner or Contributor + User Access Administrator roles
- Docker (only needed for local testing; ACR Tasks builds remotely)

## Quick Start

### 1. Set Environment Variables

```bash
export AZURE_ENVIRONMENT="dev"
export AZURE_LOCATION="eastus"
export AZURE_REGION_CODE="eus"
export AZURE_OWNER_SLUG="platform"
```

### 2. Bootstrap Shared Infrastructure

```bash
# Preview what will be created
make azure-bootstrap-plan

# Apply (creates RG, VNET, CAE, ACR, KV, Storage, Identity, RBAC)
make azure-bootstrap
```

### 3. Build & Push Golden Image

```bash
export IMAGE_TAG="v1.0.0"
make acr-build-push

# Capture the full image reference for deployments
export IMAGE_REF="$(IMAGE_TAG=v1.0.0 make -s acr-show-image)"
echo "$IMAGE_REF"
# => <acr-name>.azurecr.io/openclaw-golden:v1.0.0
```

### 4. Deploy a User

```bash
export USER_SLUG="alice"
export COMPASS_API_KEY="sk-compass-xxx"
export GRAPH_MCP_URL="https://your-mcp-gateway.example.com/alice"
export OPENCLAW_GATEWAY_AUTH_TOKEN="gw-token-xxx"

# Preview
make azure-deploy-user-plan USER_SLUG=$USER_SLUG IMAGE_REF="$IMAGE_REF"

# Apply
make azure-deploy-user USER_SLUG=$USER_SLUG IMAGE_REF="$IMAGE_REF"
``` 

### 5. Deploy Additional Users

Repeat step 4 with different `USER_SLUG` and credentials. Each user gets a
fully isolated Container App in the same shared environment.

```bash
export USER_SLUG="bob"
export COMPASS_API_KEY="sk-compass-yyy"
# ... set remaining secrets ...
make azure-deploy-user USER_SLUG=$USER_SLUG IMAGE_REF="$IMAGE_REF"
```

## Local Testing

You can run the full Golden Image setup locally using Docker Compose. This executes the `entrypoint.sh` logic to initialize the enterprise defaults into a persisted local volume.

```bash
# Export dummy credentials (or use your real ones)
export COMPASS_API_KEY="sk-compass-local"
export GRAPH_MCP_URL="http://host.docker.internal:5000"

# Build and start the container
make docker-up

# View live logs
docker compose logs -f

# Teardown the container and data volumes
make docker-down
```

## Makefile Targets

| Target | Description |
|---|---|
| `make help` | List all available targets |
| `make azure-bootstrap` | Provision shared infra (RG, VNET, CAE, ACR, KV, SA) |
| `make azure-bootstrap-plan` | Dry-run shared infra changes |
| `make azure-bootstrap-destroy` | Tear down all shared infra (**DANGER**) |
| `make acr-build-push` | Build and push golden image to ACR |
| `make acr-show-image` | Print full image reference |
| `make azure-deploy-user` | Deploy isolated Container App for a user |
| `make azure-deploy-user-plan` | Dry-run user deployment |
| `make azure-destroy-user` | Destroy a user's Container App |

## File Structure

```
.
├── Makefile                     # Orchestration entry point
├── README.md                    # This file
├── Dockerfile.wrapper           # Golden image (wraps upstream OpenClaw)
├── openclaw.json.example        # Enterprise model defaults
├── .gitignore                   # Terraform state, secrets exclusions
└── infra/
    ├── shared/                  # Shared infrastructure Terraform root
    │   ├── providers.tf
    │   ├── variables.tf
    │   ├── main.tf
    │   └── outputs.tf
    └── user-app/                # Per-user Container App Terraform root
        ├── providers.tf
        ├── variables.tf
        ├── main.tf
        └── outputs.tf
```

## Security Model

### Secrets Management
- All secrets are stored in Azure Key Vault with RBAC authorization enabled
- Container Apps reference secrets via Key Vault `secretRef` through Managed Identity
- The deploying principal receives `Key Vault Secrets Officer` role to push secrets
- The shared Managed Identity receives `Key Vault Secrets User` role (read-only)
- No secrets are baked into the container image or stored in source control

### Network Isolation
- The Container Apps Environment is deployed into a VNet with `internal_load_balancer_enabled = true`
- All Container App ingress is set to `external_enabled = false`
- No public IP addresses are allocated
- Inter-app communication stays within the VNet

### Container Registry
- ACR admin user is disabled; authentication is via Managed Identity + `AcrPull` RBAC
- Premium SKU enables private endpoint support (can be wired if needed)

### Runtime Sandbox
- Container App Resource limits: 0.5 CPU, 1Gi memory per Container App
- The application automatically isolates gateway and runtime execution within the container.

## Upgrade & Versioning Strategy

### Upgrading OpenClaw Version
1. Update the `FROM` tag in `Dockerfile.wrapper`
2. Build a new golden image with an incremented tag:
   ```bash
   export IMAGE_TAG="v1.1.0"
   make acr-build-push
   ```
3. Roll out to users individually or all at once:
   ```bash
   export IMAGE_REF="$(IMAGE_TAG=v1.1.0 make -s acr-show-image)"
   make azure-deploy-user USER_SLUG=alice IMAGE_REF="$IMAGE_REF"
   ```

### Rolling Back
Deploy the previous image tag:
```bash
export IMAGE_REF="$(IMAGE_TAG=v1.0.0 make -s acr-show-image)"
make azure-deploy-user USER_SLUG=alice IMAGE_REF="$IMAGE_REF"
```

### Terraform State
For production, configure a remote backend (Azure Storage):
```hcl
# Add to infra/shared/providers.tf and infra/user-app/providers.tf
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "stterraformstate"
    container_name       = "tfstate"
    key                  = "openclaw-shared.tfstate"  # or "openclaw-user-<slug>.tfstate"
  }
}
```

### Multi-User State Isolation
Each user deployment should use a separate Terraform workspace or state key
to prevent state collisions:
```bash
terraform -chdir=infra/user-app workspace new alice
terraform -chdir=infra/user-app workspace select alice
```

The Makefile can be extended to automate this by adding workspace selection
before `apply`/`destroy` calls.

## Assumptions

- Upstream OpenClaw image is available at `ghcr.io/openclaw/openclaw:latest`
- OpenClaw listens on port `8080` by default
- OpenClaw reads config from the path specified in `OPENCLAW_CONFIG_FILE`
- Compass provider at `https://your-llm-provider.example.com/v1` supports the OpenAI completions API
- The deploying user has sufficient Azure RBAC to create resource groups and role assignments
