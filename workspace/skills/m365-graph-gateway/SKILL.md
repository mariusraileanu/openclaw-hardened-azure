---
name: m365-graph-gateway
description: Use when the agent needs to read or write Microsoft 365 data (mail, calendar, files, Teams chats, transcripts) via the M365 Graph MCP gateway. Provides JSON-RPC MCP tools for Microsoft Graph with strict identity binding, guardrails, and confirm-gated write operations.
---

# M365 Graph Gateway Skill

This skill lets the agent call the **m365-graph-mcp-gateway**, a platform-managed
service that wraps Microsoft Graph behind an HTTP MCP JSON-RPC endpoint.

Use this skill when you need to:

- Work with **mail**: search, read, thread retrieval, draft, reply, send
- Work with **calendar**: event search/retrieval, scheduling, RSVP/cancel flows
- Work with **files**: search, metadata, and content retrieval via metadata/inline/binary/parsed modes
- Work with **Teams chats**: list chats, read messages, and send messages
- Work with **meeting transcripts**: resolve meeting links and fetch transcript metadata/content

## Execution Method - Read First

Call the gateway using `curl` from the `bash` tool.

You do **not** need additional MCP server registration. You already have:

1. `bash` execution to run `curl`
2. Network access to the gateway
3. Gateway-managed Microsoft auth flow

If you catch yourself claiming "no M365 access," stop and call the gateway.

## Gateway Endpoints

| Endpoint | Method | Purpose |
| --- | --- | --- |
| `${GRAPH_MCP_URL}/mcp` | POST | MCP JSON-RPC calls |
| `${GRAPH_MCP_URL}/health` | GET | Service health check |
| `${GRAPH_MCP_URL}/auth/status` | GET | HTTP auth status |

## Mandatory Contract Source

Always read and treat this file as the canonical contract before tool calls:

- `workspace/skills/m365-graph-gateway/references/TOOL_CONTRACT.md`

Do not guess tool names, args, or response fields.

## Startup Checklist Per Session

1. Health check:

```bash
curl -s ${GRAPH_MCP_URL}/health
```

2. MCP auth status (canonical):

```bash
curl -s -X POST ${GRAPH_MCP_URL}/mcp \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": { "name": "auth", "arguments": { "action": "status" } }
  }'
```

3. If `logged_in` is false, start device flow:

```bash
curl -s -X POST ${GRAPH_MCP_URL}/mcp \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": { "name": "auth", "arguments": { "action": "login_device" } }
  }'
```

Show `verification_uri` and `user_code`, then poll `auth status`.

## Identity Binding Requirements

The gateway enforces strict identity pinning. Ensure runtime config includes:

- `EXPECTED_AAD_OBJECT_ID` (required)
- `USER_SLUG` (required)

Use `auth` `status` response fields to validate:

- `expected_object_id`
- `actual_object_id`
- `identity_match`
- `identity_binding_status` (`valid`, `invalid`, `missing`)

If binding is invalid, do not proceed with user-data operations.

## JSON-RPC Lifecycle and Transport Notes

- First request should be `initialize`
- Follow with `notifications/initialized`
- `ping` is supported
- Notifications return HTTP 204 (no body)
- Batch requests are not supported
- `/mcp` request body limit: 1 MB

## Security and Runtime Notes

- API key auth is optional and controlled by `GRAPH_MCP_API_KEY`
- If key is configured, include `Authorization: Bearer <key>`
- `/health` and `/auth/status` are never API-key gated
- `/mcp` default rate limit: 100 requests / 60-second sliding window
- Common HTTP failures:
  - 401 unauthorized
  - 413 body too large
  - 429 rate limit exceeded

JSON-RPC errors are returned in HTTP 200 responses.

## Tool Catalog (22 tools)

1. `auth`
2. `find`
3. `get_email`
4. `get_event`
5. `get_email_thread`
6. `get_file_metadata`
7. `get_file_content`
8. `compose_email`
9. `schedule_meeting`
10. `respond_to_meeting`
11. `audit_list`
12. `list_chats`
13. `get_chat`
14. `list_chat_messages`
15. `get_chat_message`
16. `send_chat_message`
17. `resolve_meeting`
18. `list_meeting_transcripts`
19. `get_meeting_transcript`
20. `get_transcript_content`
21. `retrieve_context`
22. `retrieve_context_multi`

## Write Safety Rules

These operations require confirmation workflow:

- `compose_email` with `mode` in `send`, `reply`, `reply_all`
- `schedule_meeting`
- `respond_to_meeting` for accept/decline/tentativelyAccept/cancel
- `send_chat_message`

Pattern:

1. Call without `confirm` to produce preview
2. Show preview to user
3. Re-call with `confirm: true` after explicit approval

## Domain Guardrails

Outbound recipients/attendees are checked against allowlists.

- Config key: `guardrails.email.allowDomains`
- Runtime override: `GRAPH_MCP_ALLOW_DOMAINS` (JSON array)
- Violations return `FORBIDDEN`

Applies to:

- `compose_email` recipients
- `schedule_meeting` attendees

## High-Value Calling Patterns

### Meetings on a specific day

Resolve relative date to concrete ISO datetimes, then:

```bash
curl -s -X POST ${GRAPH_MCP_URL}/mcp \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "id": 10,
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

### Unread emails

Use property filter query syntax:

```bash
curl -s -X POST ${GRAPH_MCP_URL}/mcp \
  -H 'Content-Type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "id": 11,
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

### Email thread workflow

1. `find` mail
2. `get_email` (`include_full: true`) to get `conversation_id`
3. `get_email_thread`

### File access workflow

Prefer metadata first:

1. `find` files
2. `get_file_content` with default `mode: metadata` and use `download_url`
3. Use `mode: inline` or `mode: binary` only when needed
4. Use `mode: parsed` for supported Office/PDF formats when readable extracted text is needed

### Teams transcript workflow

1. `list_chats` with `chat_type: meeting`
2. `get_chat` to retrieve `join_web_url`
3. `resolve_meeting`
4. `list_meeting_transcripts`
5. `get_transcript_content`

Handle best-effort outcomes gracefully:

- `MEETING_NOT_RESOLVABLE`
- `TRANSCRIPT_NOT_AVAILABLE` / `available: false`

## Workflow Examples (Contract-Aligned)

These mirror the canonical examples in `TOOL_CONTRACT.md`.

### Show meetings on Monday

1. Resolve relative date to concrete ISO range.
2. Call `find` with `entity_types: ["events"]`, `start_date`, `end_date`.

### What is on my calendar this week

Call `find` with `entity_types: ["events"]` and week boundary dates.

### Find emails from John about budget and reply

1. `find` for mail
2. `get_email` with `include_full: true`
3. `get_email_thread` for full conversation context
4. `compose_email` in `reply` mode with confirm flow

### Prepare for a specific meeting

1. `find` events in the target time window
2. `get_event` with `include_full: true`
3. Additional `find` over mail/files using subject or attendee context

### Schedule a 30-minute Teams call

Use `schedule_meeting` with `preferred_start`, `preferred_end`,
`duration_minutes`, and `teams_meeting: true`, then confirm.

### Read a found document

1. `find` files
2. `get_file_content` in default metadata mode first
3. Use `download_url`, or call inline/binary mode only when needed

### Catch up on an email thread

1. `find` mail
2. `get_email` with `include_full: true` for `conversation_id`
3. `get_email_thread`

### Get transcript from a recent meeting

1. `list_chats` with `chat_type: "meeting"`
2. `get_chat` to obtain `join_web_url`
3. `resolve_meeting`
4. `list_meeting_transcripts`
5. `get_transcript_content`

### Understand what was discussed in a Teams chat

1. `list_chats`
2. `list_chat_messages`
3. Optionally `get_chat_message` for a specific message

### Send a message to a Teams chat

1. Identify chat via `list_chats`
2. `send_chat_message` with confirm flow

### Find semantic context across SharePoint/OneDrive

Use retrieval tools when the user asks for grounding context, not strict search hits:

1. `retrieve_context` for one query
2. `retrieve_context_multi` for up to 20 queries in one batch

Use optional KQL/structured filters as defined in the contract.

## Troubleshooting Sequence

1. Verify `${GRAPH_MCP_URL}/health`
2. Verify MCP `auth` `status`
3. Check identity-binding fields in `status`
4. Re-read `TOOL_CONTRACT.md` and correct params
5. Retry with corrected args
6. Escalate with exact error payload if still failing

## Timezone Guidance

Calendar behavior follows gateway `config.yaml` default timezone
(`calendar.defaultTimezone`).

When user gives ambiguous local times, resolve them against configured default.

## Output and Caching Guidance

- Default responses are high-signal/minimal
- Use `include_full: true` where supported for deeper detail
- Expect short-lived micro-cache on many `get_*` reads (30s TTL)
- Do not assume `find`, `get_file_content`, `retrieve_context`, `retrieve_context_multi`, or `get_transcript_content` are cached

## When to Use This Skill

Use for any request involving Microsoft 365 account data:

- calendar/schedule/meetings
- email search/read/reply/send
- OneDrive/SharePoint file discovery/content
- Teams chats and messages
- Teams meeting transcript retrieval

For purely conceptual requests with no live M365 data need, normal reasoning is sufficient.
