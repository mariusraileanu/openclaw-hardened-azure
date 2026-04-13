# Memory Ops Playbook

This playbook covers common memory issues in the OpenClaw canary and the fastest path to isolate and recover.

## Baseline Context

- Memory backend: `qmd`
- Wiki layer: `memory-wiki` in bridge mode
- Active Memory: enabled for `main` agent in direct chats
- Container exec commands should use user-scoped env vars:
  - `OPENCLAW_CONFIG_FILE=/app/data/<user>/.openclaw/openclaw.json`
  - `OPENCLAW_STATE_DIR=/app/data/<user>/.openclaw`

## Fast Health Check

```bash
script -q /dev/null az containerapp exec -n ca-openclaw-prod-mlucian -g rg-openclaw-prod --command "env OPENCLAW_CONFIG_FILE=/app/data/mlucian/.openclaw/openclaw.json OPENCLAW_STATE_DIR=/app/data/mlucian/.openclaw openclaw memory status --json"
```

Expected signals:

- `backend: qmd`
- `vector.available: true`
- non-zero `files` and `chunks`

## Symptom -> Cause -> Action

### 1) Memory search feels stale or empty

Likely causes:

- index lag
- embedding pipeline backlog

Actions:

```bash
# Check health first
script -q /dev/null az containerapp exec -n ca-openclaw-prod-mlucian -g rg-openclaw-prod --command "env OPENCLAW_CONFIG_FILE=/app/data/mlucian/.openclaw/openclaw.json OPENCLAW_STATE_DIR=/app/data/mlucian/.openclaw openclaw memory status --json"

# Force rebuild
script -q /dev/null az containerapp exec -n ca-openclaw-prod-mlucian -g rg-openclaw-prod --command "env OPENCLAW_CONFIG_FILE=/app/data/mlucian/.openclaw/openclaw.json OPENCLAW_STATE_DIR=/app/data/mlucian/.openclaw openclaw memory index --force"
```

Then re-run search with a known unique token from a recent conversation.

### 2) `openclaw memory search` hangs in exec sessions

Likely causes:

- interactive shell not closing cleanly in `az containerapp exec`
- repeated exec rate limits

Actions:

- Use `bash -lc "...; exit"` in command string.
- Use `script -q /dev/null` wrapper on macOS.
- If Azure returns 429 with `retry-after`, wait the full interval before retrying.

Pattern:

```bash
script -q /dev/null az containerapp exec -n ca-openclaw-prod-mlucian -g rg-openclaw-prod --command "bash -lc \"env OPENCLAW_CONFIG_FILE=/app/data/mlucian/.openclaw/openclaw.json OPENCLAW_STATE_DIR=/app/data/mlucian/.openclaw openclaw memory search memory --max-results 3 --json; exit\""
```

### 3) Active Memory does not appear to run

Likely causes:

- chat type is not direct
- current agent id not targeted
- plugin not loaded in effective user config

Actions:

```bash
script -q /dev/null az containerapp exec -n ca-openclaw-prod-mlucian -g rg-openclaw-prod --command "env OPENCLAW_CONFIG_FILE=/app/data/mlucian/.openclaw/openclaw.json OPENCLAW_STATE_DIR=/app/data/mlucian/.openclaw openclaw plugins inspect active-memory"
```

In chat session, run:

- `/active-memory status`
- `/verbose on`
- `/trace on`

Expected behavior:

- normal assistant reply first
- Active Memory diagnostics follow as status/debug lines when toggles are enabled

### 4) Memory-wiki seems present but returns little

Likely causes:

- bridge artifacts not exported yet
- corpus mismatch for query

Actions:

```bash
script -q /dev/null az containerapp exec -n ca-openclaw-prod-mlucian -g rg-openclaw-prod --command "env OPENCLAW_CONFIG_FILE=/app/data/mlucian/.openclaw/openclaw.json OPENCLAW_STATE_DIR=/app/data/mlucian/.openclaw openclaw wiki status"
script -q /dev/null az containerapp exec -n ca-openclaw-prod-mlucian -g rg-openclaw-prod --command "env OPENCLAW_CONFIG_FILE=/app/data/mlucian/.openclaw/openclaw.json OPENCLAW_STATE_DIR=/app/data/mlucian/.openclaw openclaw wiki doctor"
```

If broad recall is needed, use shared memory search with corpus set to all from plugin config.

### 5) Dreaming promotion quality is noisy

Likely causes:

- enabled before retrieval/embedding stabilized
- insufficient evidence diversity

Actions:

- disable dreaming temporarily
- stabilize active memory + indexing first
- re-enable with conservative cadence (nightly)

## Canary Rollout Guardrails

- Keep Active Memory scoped to direct chats only during tuning.
- Keep `persistTranscripts: false` unless actively debugging.
- Keep active-memory logging on only during canary validation.
- Maintain a manual `memory index --force` safety runbook for operators.
- Treat repeated 429 exec rate limits as operational noise, not memory failure.

## Recommended Operational Cadence

- Per incident: run health check + forced index.
- Daily canary check: one known-token search and one Active Memory status check.
- Weekly: review memory-wiki doctor/lint output and stale/contradiction dashboards.
