# Signal Messaging Stack

Signal provides a secure messaging channel for interacting with the OpenClaw agent from a phone. The stack consists of three components:

```
Phone (Signal app)
  |
  v
signal-cli (daemon)          Container: ca-signal-cli-<env>
  |  - Bridges Signal network to HTTP API
  |  - NFS mount at /signal-data/signal-cli (registration state)
  |  - Port 8080, 1 replica, internal ingress only
  |  - Public image: ghcr.io/asamk/signal-cli
  |
  v
signal-proxy (Go router)     Container: ca-signal-proxy-<env>
  |  - Routes messages to the correct user container by phone number
  |  - Auth token verification per request
  |  - SSE fan-out for real-time message delivery
  |  - ACR image: <acr>/signal-proxy:<tag>
  |  - Port 8080, internal ingress only
  |
  v
User container               Container: ca-openclaw-<env>-<user>
   - Receives messages via SSE from the proxy
   - Processes with AI agent (Compass LLM)
   - Sends replies back through the proxy -> signal-cli -> Signal network
```

The user container's `entrypoint.sh` assembles the full Signal HTTP URL from components:

```
SIGNAL_HTTP_URL = ${SIGNAL_CLI_URL}/user/${SIGNAL_USER_PHONE}/${SIGNAL_PROXY_AUTH_TOKEN}
```

## Deploying Signal (Dev -- via Terraform)

```bash
# Set Signal vars in config/env/dev.env or config/local/dev.env
# SIGNAL_BOT_NUMBER=+15551234567
# SIGNAL_PROXY_AUTH_TOKEN=<random-token>

make signal-build          # Build & push signal-proxy image to ACR
make signal-deploy         # Deploy signal-cli + signal-proxy via Terraform
```

## Deploying Signal (Prod -- via az CLI)

When shared infrastructure has no Terraform state (provisioned externally), deploy Signal containers directly with `az` CLI or the REST API.

**1. Build and push the signal-proxy image:**

```bash
make signal-build ENV=prod
```

**2. Deploy signal-cli:**

```bash
az containerapp create \
  --name ca-signal-cli-prod \
  --resource-group rg-openclaw-prod \
  --environment cae-openclaw-prod \
  --image ghcr.io/asamk/signal-cli:latest \
  --cpu 0.5 --memory 1Gi \
  --min-replicas 1 --max-replicas 1 \
  --ingress internal --target-port 8080 \
  --args "--config" "/signal-data/signal-cli" "daemon" "--receive-mode" "on-connection" "--no-receive-stdout" "--http" "0.0.0.0:8080"
```

Then apply the NFS volume/mount update for `/signal-data` via Terraform AzAPI resources (or an equivalent ARM patch flow if deploying manually).

**3. Deploy signal-proxy:**

```bash
az containerapp create \
  --name ca-signal-proxy-prod \
  --resource-group rg-openclaw-prod \
  --environment cae-openclaw-prod \
  --image <acr>.azurecr.io/signal-proxy:latest \
  --cpu 0.25 --memory 0.5Gi \
  --min-replicas 1 --max-replicas 1 \
  --ingress internal --target-port 8080 \
  --env-vars \
    "SIGNAL_CLI_URL=http://ca-signal-cli-prod.internal.<cae-domain>" \
    "AUTH_TOKEN=<your-proxy-auth-token>"
```

> **Note:** `SIGNAL_KNOWN_PHONES` is managed automatically by `ocp signal update-phones`,
> which runs after `ocp deploy user`, `ocp user remove`, and `ocp signal deploy`
> (including their Makefile aliases). It collects
> `SIGNAL_USER_PHONE` from `config/users/*.env` plus the bot number.

**4. Set `SIGNAL_CLI_URL` in your prod shared config layer** (`config/env/prod.env` or `config/local/prod.env`) to point to the signal-proxy FQDN (not signal-cli directly):

```bash
SIGNAL_CLI_URL=http://ca-signal-proxy-prod.internal.<cae-default-domain>
```

## Registering the Signal Bot Number

Signal requires CAPTCHA verification for new number registrations:

1. Open `https://signalcaptchas.org/registration/generate` in a browser
2. Complete the CAPTCHA
3. Copy the `signalcaptcha://` token from the resulting page
4. Open a shell in the signal-cli container:

```bash
make signal-register ENV=prod
# Or directly:
az containerapp exec -n ca-signal-cli-prod -g rg-openclaw-prod --command /bin/sh
```

5. Register with the CAPTCHA token:

```bash
signal-cli --config /signal-data/signal-cli -a +YOUR_BOT_NUMBER register --captcha "signalcaptcha://..."
```

6. Enter the SMS verification code:

```bash
signal-cli --config /signal-data/signal-cli -a +YOUR_BOT_NUMBER verify CODE
```

The registration state is persisted on the NFS volume (`/signal-data/signal-cli`), so it survives container restarts.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Agent replies "Connection error." | LLM provider `baseUrl` misconfigured | Check `COMPASS_BASE_URL` env var; verify `openclaw.json` has the correct URL |
| No messages received | SSE connection dropped | Check signal-proxy logs; ensure signal-cli is running with 1 replica |
| `signal-cli spawn error: EACCES` | Harmless -- the app tries to run a local `signal-cli` binary | Ignore; messages flow through the HTTP proxy |
| Registration fails | CAPTCHA expired or wrong number format | Re-generate CAPTCHA; use E.164 format (`+` prefix) |
