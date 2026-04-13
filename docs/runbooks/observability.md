# Observability

Container logs are collected in Log Analytics. Use KQL queries to inspect boot behavior, debug issues, and monitor health.

For Teams traffic, request-level usage is emitted by the relay as structured `relay_event=...` logs and can be queried per user.

## Finding the Log Analytics Workspace ID

```bash
az monitor log-analytics workspace show \
  -n law-openclaw-prod -g rg-openclaw-prod \
  --query "customerId" -o tsv
```

## KQL Query Examples

**Request-level usage by user (last 24 hours, Teams relay):**

```kql
let windowStart = ago(24h);
AzureDiagnostics
| where TimeGenerated > windowStart
| where Resource has "func-relay-prod" or ResourceId has "/sites/func-relay-prod"
| extend rawLog = coalesce(tostring(column_ifexists("Message", "")), tostring(column_ifexists("msg_s", "")), tostring(column_ifexists("ResultDescription", "")))
| where rawLog has "relay_event="
| extend relayJson = extract(@"relay_event=(\{.*\})", 1, rawLog)
| where isnotempty(relayJson)
| extend evt = parse_json(relayJson)
| extend userSlug = tostring(evt.userSlug), result = tostring(evt.result), latencyMs = todouble(evt.latencyMs)
| where userSlug != "" and userSlug != "unknown"
| summarize requests=count(), successes=countif(result == "upstream_ok"), failures=countif(result in ("upstream_failure", "upstream_5xx", "store_error", "circuit_open")), p95_latency_ms=percentile(latencyMs, 95) by userSlug
| extend success_rate_pct = round((todouble(successes) / requests) * 100.0, 2)
| order by requests desc
```

**Recent logs for a user container (last 30 minutes):**

```kql
ContainerAppConsoleLogs_CL
| where ContainerAppName_s == 'ca-openclaw-prod-alice'
| where TimeGenerated > ago(30m)
| project TimeGenerated, Log_s
| order by TimeGenerated desc
```

**Boot/entrypoint messages (verify patching steps ran):**

```kql
ContainerAppConsoleLogs_CL
| where ContainerAppName_s == 'ca-openclaw-prod-alice'
| where Log_s has_any ("Patched Compass", "Resolving GRAPH_MCP_URL", "Removing unsupported", "listening on")
| project TimeGenerated, Log_s
| order by TimeGenerated desc
| take 20
```

**Error-level logs across all OpenClaw containers:**

```kql
ContainerAppConsoleLogs_CL
| where ContainerAppName_s startswith 'ca-openclaw-'
| where Log_s has_any ("error", "Error", "ERROR", "FATAL", "crash")
| project TimeGenerated, ContainerAppName_s, Log_s
| order by TimeGenerated desc
| take 50
```

## Running Queries from the CLI

```bash
az monitor log-analytics query \
  --workspace <workspace-customer-id> \
  --analytics-query "ContainerAppConsoleLogs_CL | where ContainerAppName_s == 'ca-openclaw-prod-alice' | where TimeGenerated > ago(1h) | project TimeGenerated, Log_s | order by TimeGenerated desc | take 20" \
  -o table
```

## Request-Level Usage CLI

```bash
# All users, last 24 hours
./platform/cli/ocp usage --env prod --hours 24

# Single user
./platform/cli/ocp usage --env prod --user alice --hours 24

# Optional: explicitly pass workspace customerId
./platform/cli/ocp usage --env prod --workspace-id <workspace-customer-id>
```

## Session-Based Message Usage CLI (Recommended for User-Level Counts)

Use this when you want per-user message volume from persisted OpenClaw session files.
It reports columns for the last 48 hours, 7 days, 14 days, and 30 days.

```bash
# All users (columns: 48h, 7d, 14d, 30d)
./platform/cli/ocp usage --env prod --source sessions

# Single user only
./platform/cli/ocp usage --env prod --source sessions --user alice

# Optional: force which container app is used as the exec probe
./platform/cli/ocp usage --env prod --source sessions --probe-user mlucian
```

Notes:

- `--source sessions` reads `/app/data/*/.openclaw/agents/main/sessions/*.jsonl*` via `az containerapp exec`.
- It counts user-originated Teams DMs by parsing embedded `System: [...] Teams DM from ...` entries.
- It deduplicates by embedded `message_id` when present and normalizes user aliases (trailing-space slug variants).

## Memory (QMD + Memory Wiki) Quick Checks

After deploying an image that enables QMD and memory-wiki:

```bash
# Verify plugin load and memory backend from the running canary
script -q /dev/null az containerapp exec -n ca-openclaw-prod-mlucian -g rg-openclaw-prod --command "openclaw plugins inspect memory-wiki"
script -q /dev/null az containerapp exec -n ca-openclaw-prod-mlucian -g rg-openclaw-prod --command "openclaw memory status --json"

# Trigger first index/embedding pass (can be slow on first run)
script -q /dev/null az containerapp exec -n ca-openclaw-prod-mlucian -g rg-openclaw-prod --command "openclaw memory index --force"
```

Recommended timeout baseline for QMD in this environment:

- `memory.qmd.limits.timeoutMs = 300000`
- `memory.qmd.update.embedTimeoutMs = 300000`
- `memory.qmd.update.updateTimeoutMs = 300000`

## Active Memory Canary Validation

Active Memory is enabled only for direct chats on the `main` agent in canary.
For troubleshooting patterns, see `docs/runbooks/memory-ops-playbook.md`.

```bash
# Inspect active-memory plugin wiring
script -q /dev/null az containerapp exec -n ca-openclaw-prod-mlucian -g rg-openclaw-prod --command "env OPENCLAW_CONFIG_FILE=/app/data/mlucian/.openclaw/openclaw.json OPENCLAW_STATE_DIR=/app/data/mlucian/.openclaw openclaw plugins inspect active-memory"

# Validate memory backend health
script -q /dev/null az containerapp exec -n ca-openclaw-prod-mlucian -g rg-openclaw-prod --command "env OPENCLAW_CONFIG_FILE=/app/data/mlucian/.openclaw/openclaw.json OPENCLAW_STATE_DIR=/app/data/mlucian/.openclaw openclaw memory status --json"

# Index safety net (manual refresh)
script -q /dev/null az containerapp exec -n ca-openclaw-prod-mlucian -g rg-openclaw-prod --command "env OPENCLAW_CONFIG_FILE=/app/data/mlucian/.openclaw/openclaw.json OPENCLAW_STATE_DIR=/app/data/mlucian/.openclaw openclaw memory index --force"
```

Recommended session checks in Teams canary chat:

- `/verbose on`
- `/trace on`
- `/active-memory status`
