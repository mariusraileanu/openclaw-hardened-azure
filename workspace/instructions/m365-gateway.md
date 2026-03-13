# M365 Graph Gateway — Always-On Instructions

You have **live access to the user's Microsoft 365 account** (calendar, email,
files) through an internal HTTP gateway. This is not hypothetical — the gateway
is running and pre-authenticated.

## How to call it

Use the `bash` tool to run `curl` commands against the gateway:

```
${GRAPH_MCP_URL}/mcp          — MCP JSON-RPC endpoint (POST)
${GRAPH_MCP_URL}/health        — health check (GET)
${GRAPH_MCP_URL}/auth/status   — auth status (GET)
```

## When to use it

Any time the user asks about **calendar, meetings, schedule, emails, mail,
files, OneDrive, SharePoint** — you MUST call the gateway. Do NOT say "I don't
have access to your calendar" or "I'm not connected to your real calendar."
That is always wrong. You have access. Use it.

## Quick examples

**Today's meetings** (replace dates with actual today in Asia/Dubai):

```bash
curl -s -X POST ${GRAPH_MCP_URL}/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"find","arguments":{"query":"meetings","entity_types":["events"],"start_date":"YYYY-MM-DDT00:00:00","end_date":"YYYY-MM-DDT00:00:00","top":25}}}'
```

**Unread emails** (use `isRead:false`, NOT natural language):

```bash
curl -s -X POST ${GRAPH_MCP_URL}/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"find","arguments":{"query":"isRead:false","entity_types":["mail"],"top":10}}}'
```

## Before first use in a session

1. Load the full skill docs: call `skill({ name: "m365-graph-gateway" })` — this
   gives you TOOL_CONTRACT.md with every tool name, parameter, and error code.
2. Check health: `curl -s ${GRAPH_MCP_URL}/health`
3. Check auth: `curl -s ${GRAPH_MCP_URL}/auth/status`

## Critical rules

- The shell tool is called `bash`, not `exec`. Use `bash` to run curl.
- Write operations (send email, create meeting) require user confirmation first,
  then pass `confirm: true` in the tool arguments.
- For email search, use property filters like `isRead:false` or `from:alice` —
  not natural language descriptions.
- If a curl call fails, parse the error, adjust, and retry before asking the user.
