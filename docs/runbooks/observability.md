# Observability

Container logs are collected in Log Analytics. Use KQL queries to inspect boot behavior, debug issues, and monitor health.

## Finding the Log Analytics Workspace ID

```bash
az monitor log-analytics workspace show \
  -n law-openclaw-prod -g rg-openclaw-prod \
  --query "customerId" -o tsv
```

## KQL Query Examples

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
