# Teams Relay & Manifest Architecture

How Microsoft Teams messages reach per-user OpenClaw containers and how the Teams app manifest is packaged.

## Message Flow

```
Microsoft Teams
    |
    v
Azure Bot Service (single shared bot registration)
    |
    v  POST /api/messages
Teams Relay Function App (func-relay-openclaw-<env>)
    |  - VNet-integrated Azure Function (Node.js / TypeScript)
    |  - Parses Bot Framework Activity payload
    |  - Resolves activity.from.aadObjectId from Azure Table Storage
    |  - 15-second upstream timeout + per-user short-circuit
    |
    v  POST {upstream_url}/api/messages
Loopback Proxy (inside user container, port 18789 ingress)
    |
    v  POST /api/messages --> 127.0.0.1:3978
Teams Bot Framework SDK (inside user container)
    |
    v
OpenClaw agent processes message, sends reply back through Bot Framework
```

**Key design decisions:**

- Single Azure Bot registration serves all users (one App ID, one `/api/messages` endpoint)
- User routing is done by AAD Object ID lookup, not by URL path
- Upstream URL is read from routing registry (no hostname inference)
- Routing records are cached in-memory (TTL) for low-latency resolution
- Teams-facing failures are graceful (`200` with user-friendly message)
- The relay uses VNet integration to reach internal-only container apps

## Relay Function App (`teams-relay/`)

The relay is a single Azure Function (`src/functions/messages.ts`) deployed as a Function App:

| Setting | Value |
|---------|-------|
| Runtime | Node.js (TypeScript) |
| Trigger | HTTP POST `/api/messages` |
| Auth level | Anonymous (Bot Framework handles JWT auth) |
| Internal debug | GET `/internal/routing/{aadObjectId}` (`authLevel: function`) |
| Timeout | 15 seconds |
| Networking | VNet-integrated (reaches internal CAE ingress) |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `ROUTING_STORAGE_ACCOUNT_NAME` | Storage account hosting the routing table |
| `ROUTING_TABLE_NAME` | Routing table name (default: `userrouting`) |
| `ROUTING_CACHE_TTL_SEC` | In-memory routing cache TTL in seconds (default: `600`) |
| `ROUTING_FAILURE_THRESHOLD` | Consecutive upstream failures before opening circuit (default: `3`) |
| `ROUTING_CIRCUIT_OPEN_SEC` | Circuit open duration in seconds (default: `60`) |
| `MSTEAMS_EXPECTED_TENANT_ID` | Optional tenant guard for incoming Teams payload |

### Routing Resolution

The relay extracts `activity.from.aadObjectId`, validates it, and resolves a routing record from Azure Table Storage (`userrouting`).

Routing entity contract:

```json
{
  "aad_object_id": "string",
  "user_slug": "string",
  "upstream_url": "string",
  "status": "active | provisioning | disabled",
  "updated_at": "timestamp"
}
```

Resolution behavior:

- cache hit: use in-memory record
- cache miss: query table, validate record, cache result
- `active`: forward to `POST {upstream_url}/api/messages`
- `provisioning`: return `200` + "Your assistant is being set up"
- `disabled`: return `200` + "Your assistant is currently unavailable"
- missing/invalid mapping: return `200` + "No assistant configured"
- upstream failures: return `200` + "Assistant temporarily unavailable"

All requests propagate `x-correlation-id` through relay logs and upstream calls.

### Build & Deploy

```bash
./platform/cli/ocp teams relay-build --env dev     # Build the Function App
./platform/cli/ocp teams relay-deploy --env dev     # Deploy (build + shared infra with relay enabled)
```

## Teams App Manifest (`teams-app/`)

The manifest is built from a base template with environment-specific overlays:

```
teams-app/
  base.manifest.json       # Shared schema, bot ID, icons, permissions
  env/
    dev.json               # Dev overlay (name, description, validDomains, version)
    stage.json             # Stage overlay
    prod.json              # Prod overlay
  render-manifest.mjs      # Merges base + overlay into manifest.json
  check-manifest.mjs       # Validates rendered manifest against Teams schema
  package-teams-app.sh     # Packages manifest.json + icons into distributable zip
  color.png                # Bot icon (192x192)
  outline.png              # Bot icon (32x32, transparent)
```

**Policy:**

- Single App ID (`e7a3d250-...`) across all environments
- Environment identity is controlled by overlay content (name, description, validDomains, version)
- Overlay content changes must include an explicit `version` bump
- Stage/prod changes should go through your internal approval process

### Commands

```bash
./platform/cli/ocp teams manifest --env dev       # Render manifest for one env
./platform/cli/ocp teams manifest-all             # Render all environments
./platform/cli/ocp teams validate --env dev       # Validate rendered manifest
./platform/cli/ocp teams package --env prod       # Build distributable zip
./platform/cli/ocp teams release-check            # Full local release gate
```

Output artifacts are written to `teams-app/dist/<env>/` (git-ignored).

### Release Checklist

Before publishing a Teams package:

```bash
./platform/cli/ocp teams manifest-all
./platform/cli/ocp teams validate --env dev
./platform/cli/ocp teams validate --env stage
./platform/cli/ocp teams validate --env prod
./platform/cli/ocp teams package --env dev
./platform/cli/ocp teams package --env stage
./platform/cli/ocp teams package --env prod
```

Optional integrity check:

```bash
sha256sum teams-app/dist/dev/openclaw-teams-dev.zip
sha256sum teams-app/dist/stage/openclaw-teams-stage.zip
sha256sum teams-app/dist/prod/openclaw-teams-prod.zip
```
