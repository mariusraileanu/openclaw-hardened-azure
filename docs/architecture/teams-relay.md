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
    |  - Maps activity.from.aadObjectId --> user slug via MSTEAMS_USER_SLUG_MAP
    |  - 15-second request timeout
    |
    v  POST http://ca-openclaw-<env>-<slug>.internal.<cae-domain>:3978/api/messages
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
- A legacy route (`/api/messages/{user_slug}`) exists for direct testing
- The relay is stateless -- all state lives in the user container
- The relay uses VNet integration to reach internal-only container apps

## Relay Function App (`teams-relay/`)

The relay is a single Azure Function (`src/functions/messages.ts`) deployed as a Function App:

| Setting | Value |
|---------|-------|
| Runtime | Node.js (TypeScript) |
| Trigger | HTTP POST `/api/messages` |
| Auth level | Anonymous (Bot Framework handles JWT auth) |
| Timeout | 15 seconds |
| Networking | VNet-integrated (reaches internal CAE ingress) |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `CAE_DEFAULT_DOMAIN` | Default domain of the Container Apps Environment |
| `ENVIRONMENT` | Environment label (`dev`, `prod`) |
| `OPENCLAW_HOST_PREFIX` | Container app name prefix (default: `ca-openclaw`) |
| `UPSTREAM_PORT` | Port on user container (default: `3978`) |
| `UPSTREAM_HOST_STYLE` | `internal` or `external` (default: `internal`) |
| `MSTEAMS_USER_SLUG_MAP` | JSON map of AAD Object ID to user slug |

### User Slug Resolution

The relay extracts `activity.from.aadObjectId` from the Bot Framework Activity payload and looks it up in `MSTEAMS_USER_SLUG_MAP`:

```json
{
  "aad-object-id-lowercase": "alice",
  "another-aad-object-id": "bob"
}
```

If no mapping is found, the relay returns 404. AAD Object IDs are normalized to lowercase for case-insensitive matching.

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
