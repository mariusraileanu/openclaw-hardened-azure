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

## Contract Reference (on-demand)

The full tool contract with response shapes, error codes, and edge cases:

- `workspace/skills/m365-graph-gateway/references/TOOL_CONTRACT.md`

**Do not read this file upfront.** The parameter schemas below are sufficient
for most calls. Only consult the contract when you encounter an unexpected
response shape, an unfamiliar error code, or need detailed field definitions.

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

## Identity & Security Notes

- If `auth` `status` shows `identity_binding_status` is not `valid`, stop and report the issue.
- API key auth is optional (`GRAPH_MCP_API_KEY`). If configured, add `Authorization: Bearer <key>` to `/mcp` calls.
- `/health` and `/auth/status` are never API-key gated.
- Rate limit: 100 requests / 60-second sliding window on `/mcp`.

## Auth Recovery (Mandatory)

If any tool call returns `isError: true` with `structuredContent.error_code`
equal to `AUTH_EXPIRED` or `AUTH_REQUIRED`:

1. Call `auth` with `action: "login_device"`
2. Show `verification_uri` and `user_code` to the user
3. Poll `auth` `status` every 5 seconds
4. Retry the original tool call only after:
   - `logged_in: true`
   - `graph_reachable: true`
   - `device_code_pending: false`

Do not treat 7-day re-auth prompts as outages; this is expected Conditional
Access behavior.

## Tool Catalog — Quick Reference (22 tools)

Use **exactly** these parameter names. Do not invent alternatives.
For full response shapes and edge cases, read `TOOL_CONTRACT.md`.

### auth

| Param | Type | Req | Values |
|-------|------|-----|--------|
| `action` | enum | yes | `login`, `login_device`, `logout`, `whoami`, `status` |

### find

| Param | Type | Req | Description |
|-------|------|-----|-------------|
| `query` | string | yes | Search text (min 1 char) |
| `entity_types` | string[] | no | `"mail"`, `"files"`, `"events"` (default: all) |
| `start_date` | string | no | ISO 8601 datetime — enables CalendarView for events |
| `end_date` | string | no | ISO 8601 datetime — required with `start_date` |
| `top` | integer | no | Max results 1-50 (default 10) |
| `kql` | string | no | Raw KQL query (overrides `query`) |
| `mailbox_user` | string | no | UPN/email for shared mailbox/calendar |
| `max_chars` | integer | no | Max output chars 1-50000 |

### get_email

| Param | Type | Req | Description |
|-------|------|-----|-------------|
| `message_id` | string | yes | Email ID from `find` |
| `include_full` | boolean | no | Expands body, recipients, conversation_id |
| `mailbox_user` | string | no | Shared mailbox UPN |

### get_event

| Param | Type | Req | Description |
|-------|------|-----|-------------|
| `event_id` | string | yes | Event ID from `find` |
| `include_full` | boolean | no | Expands attendees, body, online meeting details |
| `mailbox_user` | string | no | Shared calendar UPN |

### get_email_thread

| Param | Type | Req | Description |
|-------|------|-----|-------------|
| `conversation_id` | string | one of two | From `get_email` with `include_full` |
| `message_id` | string | one of two | Auto-resolves conversation_id |
| `top` | integer | no | Max messages 1-50 (default 10) |
| `include_full` | boolean | no | Expands body, recipients |
| `mailbox_user` | string | no | Shared mailbox UPN |

### get_file_metadata

| Param | Type | Req | Description |
|-------|------|-----|-------------|
| `drive_id` | string | yes | From `find` file results |
| `item_id` | string | yes | From `find` file results |
| `include_full` | boolean | no | Expands created/modified by, parent ref |

### get_file_content

| Param | Type | Req | Description |
|-------|------|-----|-------------|
| `drive_id` | string | yes | From `find` file results |
| `item_id` | string | yes | From `find` file results |
| `mode` | enum | no | `metadata` (default), `inline`, `binary`, `parsed` |
| `max_chars` | integer | no | Max chars 1-50000 (inline/parsed) |

### compose_email

| Param | Type | Req | Description |
|-------|------|-----|-------------|
| `mode` | enum | yes | `draft`, `send`, `reply`, `reply_all` |
| `to` | string/string[] | for draft/send | Recipient(s) |
| `subject` | string | for draft/send | Subject line |
| `body_html` | string | yes | HTML body |
| `message_id` | string | for reply modes | ID of message to reply to |
| `confirm` | boolean | no | `true` to execute send/reply |
| `mailbox_user` | string | no | Shared mailbox UPN |

### schedule_meeting

| Param | Type | Req | Description |
|-------|------|-----|-------------|
| `subject` | string | yes | Meeting subject |
| `attendees` | string[] | no | Email addresses |
| `start` / `end` | string | option A | Explicit ISO 8601 with offset |
| `preferred_start` / `preferred_end` | string | option B | Window for auto free-slot |
| `duration_minutes` | integer | no | 1-480, default 60 |
| `timezone` | string | no | IANA timezone |
| `teams_meeting` | boolean | no | `true` for Teams link |
| `agenda` | string | no | Agenda text |
| `confirm` | boolean | no | `true` to create |
| `mailbox_user` | string | no | Shared calendar UPN |

### respond_to_meeting

| Param | Type | Req | Description |
|-------|------|-----|-------------|
| `event_id` | string | yes | Event ID |
| `action` | enum | yes | `accept`, `decline`, `tentativelyAccept`, `cancel`, `reply_all_draft` |
| `comment` | string | no | Comment with response |
| `confirm` | boolean | no | `true` to execute |
| `mailbox_user` | string | no | Shared calendar UPN |

### audit_list

| Param | Type | Req | Description |
|-------|------|-----|-------------|
| `limit` | integer | no | 1-1000, default 100 |

### list_chats

| Param | Type | Req | Description |
|-------|------|-----|-------------|
| `top` | integer | no | 1-50, default 10 |
| `chat_type` | enum | no | `oneOnOne`, `group`, `meeting` |
| `expand_members` | boolean | no | Include member list |
| `include_full` | boolean | no | Expands tenant, web URL, meeting info |

### get_chat

| Param | Type | Req | Description |
|-------|------|-----|-------------|
| `chat_id` | string | yes | Chat ID |
| `include_full` | boolean | no | Expands tenant, meeting info, members |

### list_chat_messages / get_chat_message

| Param | Type | Req | Description |
|-------|------|-----|-------------|
| `chat_id` | string | yes | Chat ID |
| `message_id` | string | get only | Message ID |
| `top` | integer | no | 1-50, default 10 (list only) |
| `include_full` | boolean | no | Expands importance, web URL, attachments |

### send_chat_message

| Param | Type | Req | Description |
|-------|------|-----|-------------|
| `chat_id` | string | yes | Existing chat ID |
| `content` | string | yes | Plain text message |
| `confirm` | boolean | no | `true` to send |

### resolve_meeting

| Param | Type | Req | Description |
|-------|------|-----|-------------|
| `join_web_url` | string | yes | Teams meeting join URL |

### list_meeting_transcripts / get_meeting_transcript

| Param | Type | Req | Description |
|-------|------|-----|-------------|
| `meeting_id` | string | yes | From `resolve_meeting` |
| `transcript_id` | string | get only | Transcript ID |

### get_transcript_content

| Param | Type | Req | Description |
|-------|------|-----|-------------|
| `meeting_id` | string | yes | Meeting ID |
| `transcript_id` | string | yes | Transcript ID |
| `max_chars` | integer | no | 1-50000 |

### retrieve_context

| Param | Type | Req | Description |
|-------|------|-----|-------------|
| `query` | string | yes | Natural language (max 1500 chars) |
| `data_source` | enum | no | `sharePoint` (default), `oneDriveBusiness`, `externalItem` |
| `max_results` | integer | no | 1-25, default 10 |
| `filter_expression` | string | no | Raw KQL filter |
| `filter_author` | string | no | Author name |
| `filter_file_extension` | string | no | e.g. `docx`, `pdf` |
| `filter_filename` | string | no | Partial match |
| `filter_path` | string | no | SharePoint/OneDrive path |
| `filter_site_id` | string | no | SharePoint Site ID |
| `filter_title` | string | no | Document title |
| `filter_modified_after` | string | no | ISO date |
| `filter_join` | enum | no | `AND` (default), `OR` |

### retrieve_context_multi

| Param | Type | Req | Description |
|-------|------|-----|-------------|
| `queries` | string[] | yes | 1-20 queries, each max 1500 chars |
| `data_source` | enum | no | Same as `retrieve_context` |
| `max_results` | integer | no | 1-25, default 10 |
| (filter params) | | no | Same as `retrieve_context`, shared across all queries |

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

`compose_email` mode specifics:

- `send` without `confirm` returns a preview
- `reply` / `reply_all` without `confirm` creates a draft
- `draft` always creates a draft (no `confirm` required)

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

## Mandatory Behavioral Rules

- **Never claim you lack M365 access.** The gateway is always running. If a user asks about calendar, email, files, OneDrive, SharePoint, or Teams — call the gateway.
- Write operations (send email, create meeting, send chat) require user confirmation + `confirm: true`.
- For email search, use property filters (`isRead:false`, `from:alice`) not natural language.
- For SharePoint/OneDrive files, use M365 file tools only (`find` -> `get_file_content` with `mode:"parsed"`). Do not use Tavily/web extract tools for these.
- If you only have a SharePoint `web_url`, run `find` again to get `drive_id` and `item_id`, then call `get_file_content`.
- If a curl call fails, parse the error, adjust, and retry before asking the user.

For purely conceptual requests with no live M365 data need, normal reasoning is sufficient.
