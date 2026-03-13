---
name: m365-graph-gateway
description: Use when the agent needs to read or write Microsoft 365 data (mail, calendar, files, or Copilot Retrieval search) via the M365 Graph MCP gateway. Provides JSON-RPC MCP tools for Microsoft Graph with strong guardrails and confirm-gated write operations.
---

# M365 Graph Gateway Skill

This skill lets the agent call the **M365 Graph MCP gateway**, a platform-managed
service that wraps the Microsoft 365 Graph API and exposes an HTTP **MCP JSON-RPC
endpoint**.

Use this skill when you need to:

- Work with **mail**: list, search, read, draft, reply, send (with explicit confirmation)
- Work with **calendar**: list events, check availability, create/modify/cancel meetings
- Work with **files**: search and retrieve content from SharePoint and OneDrive
- Use **Copilot Retrieval API** to perform semantic search across SharePoint/OneDrive

## Execution Method — READ THIS FIRST

You call the gateway using **`curl` via your shell/exec capability**. You do NOT
need an MCP server registration, a special plugin, or any other wiring. You
already have everything you need:

1. **`bash` (shell) tool** — run `curl` commands from this host.
2. **Network access** — the gateway runs in the same VNet as this agent.
3. **Pre-authenticated** — the gateway handles Microsoft auth; no tokens needed from you.

> **If you find yourself telling the user "I don't have access to M365 tools"
> or "no MCP tool is wired" — STOP. You are wrong. Use `curl`.** This is a
> critical mistake that wastes the user's time. You always have access via
> shell commands.

## Gateway Endpoints

| Endpoint                        | Method | Purpose              |
| ------------------------------- | ------ | -------------------- |
| `${GRAPH_MCP_URL}/mcp`         | POST   | MCP JSON-RPC calls   |
| `${GRAPH_MCP_URL}/health`      | GET    | Service health check |
| `${GRAPH_MCP_URL}/auth/status` | GET    | Auth status          |

## Before Your First Tool Call

**You MUST read `references/TOOL_CONTRACT.md`** before calling any tool for the
first time in a session. It contains every tool name, parameter, response shape,
query syntax, and error code. Do not guess parameters — look them up.

## Ready-to-Use curl Commands

Below are copy-paste curl templates for the most common tasks. Replace date
values with actual dates resolved from "today" in Asia/Dubai (UTC+4).

### Check gateway health + auth

```bash
curl -s ${GRAPH_MCP_URL}/health
curl -s ${GRAPH_MCP_URL}/auth/status
```

### Today's meetings

Replace `START` and `END` with today's date boundaries in ISO 8601. For example,
if today is 2026-02-27: `start_date: "2026-02-27T00:00:00"`, `end_date: "2026-02-28T00:00:00"`.

```bash
curl -s -X POST ${GRAPH_MCP_URL}/mcp \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "find",
      "arguments": {
        "query": "meetings",
        "entity_types": ["events"],
        "start_date": "YYYY-MM-DDT00:00:00",
        "end_date": "YYYY-MM-DDT00:00:00",
        "top": 25
      }
    }
  }'
```

### Unread emails (top 10)

The `query` field supports property filters. Use `isRead:false` — NOT natural
language like "unread emails" (that returns nothing).

```bash
curl -s -X POST ${GRAPH_MCP_URL}/mcp \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "find",
      "arguments": {
        "query": "isRead:false",
        "entity_types": ["mail"],
        "top": 10
      }
    }
  }'
```

### Search emails by sender/topic

Combine property filters with keywords. See `references/TOOL_CONTRACT.md` for
the full query syntax reference.

```bash
curl -s -X POST ${GRAPH_MCP_URL}/mcp \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "find",
      "arguments": {
        "query": "from:alice budget Q4",
        "entity_types": ["mail"],
        "top": 10
      }
    }
  }'
```

### Get full email by ID

After `find` returns mail results, use the `id` field from any result to fetch
the full email body:

```bash
curl -s -X POST ${GRAPH_MCP_URL}/mcp \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "get_email",
      "arguments": {
        "message_id": "AAMk...",
        "include_full": true
      }
    }
  }'
```

### Prepare briefing for a meeting

After finding a meeting, use its `id` to generate a briefing package with
related emails, files, and attendee context:

```bash
curl -s -X POST ${GRAPH_MCP_URL}/mcp \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "prepare_meeting",
      "arguments": {
        "event_id": "AAMk..."
      }
    }
  }'
```

## Self-Diagnostic Checklist

Before asking the user for help or claiming you cannot access M365 data, run
through this checklist:

1. **Check health**: `curl -s ${GRAPH_MCP_URL}/health`
   - Connection refused or no response → gateway is down. Tell the user to
     contact platform admin.
   - HTTP 200 with `"status":"ok"` → gateway is healthy, proceed.

2. **Check auth**: `curl -s ${GRAPH_MCP_URL}/auth/status`
   - `"authenticated":false` → gateway needs re-auth. Tell the user.
   - `"authenticated":true` → gateway is ready.

3. **Read TOOL_CONTRACT.md**: if you haven't already, read
   `references/TOOL_CONTRACT.md` for the exact tool name, parameters, and
   query syntax.

4. **Try the curl call**: construct and run the curl command. If it fails:
   - Parse the error response (`content[0].text` or `isError` field).
   - Adjust parameters and retry.
   - Only after 2 failed attempts with different approaches should you ask the
     user for guidance — and include the full error response when you do.

## Safety & Guardrails

The gateway provides its own strong guardrails. Key points (see TOOL_CONTRACT
for full list):

- **Write operations require `confirm=true`** in their arguments. This includes:
  - Sending mail (`compose_email` with mode `send`, `reply`, `reply_all`)
  - Creating calendar events (`schedule_meeting`)
  - Responding to invites (`respond_to_meeting` — accept, decline, cancel)
- Outbound **email recipients are domain-allowlisted**.
- Attachments have size/quantity limits.
- HTML is sanitized.
- An **audit log** records all write actions and blocked attempts.

As the agent:

1. Prefer **read-only operations** first (search, list, get) to gather context.
2. For any write operation (send mail, create meeting, etc.):
   - Clearly summarize the intended action to the user.
   - Require an explicit user confirmation.
   - Only then call the tool with `confirm=true`.
3. If a write request is blocked by guardrails or allowlists, explain the error
   and offer safer alternatives.

## Tool Selection Quick Reference

| User asks about...        | Tool to use        | Key params                                    |
| ------------------------- | ------------------ | --------------------------------------------- |
| Today's/tomorrow's schedule | `find`           | `entity_types:["events"]`, `start_date`, `end_date` |
| Unread emails             | `find`             | `query:"isRead:false"`, `entity_types:["mail"]` |
| Emails from someone       | `find`             | `query:"from:name topic"`, `entity_types:["mail"]` |
| Full email body           | `get_email`        | `message_id`, `include_full:true`             |
| Meeting details           | `get_event`        | `event_id`, `include_full:true`               |
| Meeting prep/briefing     | `prepare_meeting`  | `event_id` or `subject`                       |
| Send/reply to email       | `compose_email`    | `mode`, `to`, `subject`, `body_html`, `confirm:true` |
| Schedule a meeting        | `schedule_meeting` | `subject`, `attendees`, times, `confirm:true` |
| Accept/decline invite     | `respond_to_meeting` | `event_id`, `action`, `confirm:true`        |
| File/doc search           | `find`             | `entity_types:["files"]`                      |
| Summarize a document      | `summarize`        | `query` or `drive_id`+`item_id`               |
| Audit trail               | `audit_list`       | `limit`                                       |

## Troubleshooting

If the gateway is not responding:

1. **Check health**: `curl -s ${GRAPH_MCP_URL}/health`
   - No response or connection refused: the gateway container may be scaled to
     zero or stopped. Ask the platform administrator to restart it.
   - HTTP 200 with `"status":"ok"`: the gateway is healthy.

2. **Check auth**: `curl -s ${GRAPH_MCP_URL}/auth/status`
   - If the response indicates no authenticated user: the gateway needs to be
     re-authenticated. Contact the platform administrator.

3. **Parse error responses**: Every failed tool call returns an error in
   `content[0].text` with a `CODE: message` format. Common codes:
   - `AUTH_REQUIRED` → call `auth` tool or escalate
   - `VALIDATION_ERROR` → check your parameters against TOOL_CONTRACT.md
   - `UPSTREAM_ERROR` → Microsoft Graph API issue, retry or escalate

## When to Use This Skill

Trigger this skill when the user asks for anything that clearly involves their
**Microsoft 365 account**, for example:

- "What meetings do I have today/tomorrow?"
- "Show my unread emails"
- "Find all emails from Alice about the Q4 launch"
- "Search my OneDrive for the latest budget spreadsheet"
- "Draft (and then send, after confirmation) an email to the leadership team"
- "Prepare me for my 2pm meeting"
- "Schedule a 30-min Teams call with Bob tomorrow morning"
- "Search across mail, calendar, and files for references to project Falcon"

For generic questions that do not require live access to the user's M365
workspace, use normal model reasoning instead of this gateway.
