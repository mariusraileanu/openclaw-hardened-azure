# Tool Contract — m365-graph-mcp-gateway

This document is the canonical reference for agents consuming the MCP gateway.
Pass it as system-prompt context or reference documentation so the LLM knows
every tool name, parameter, response shape, and best-practice calling pattern.

---

## Transport

| Endpoint       | Method | Description               |
| -------------- | ------ | ------------------------- |
| `/mcp`         | POST   | MCP JSON-RPC (HTTP mode)  |
| `stdin/stdout` | —      | MCP JSON-RPC (stdio mode) |

All calls use JSON-RPC 2.0:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "<tool_name>",
    "arguments": {}
  }
}
```

**Request size limit**: The maximum request body is **1 MB** (1,048,576 bytes).
Requests exceeding this limit receive HTTP **413 Request Entity Too Large**.

---

## Authentication

The `/mcp` endpoint supports optional API key authentication via the
`GRAPH_MCP_API_KEY` environment variable.

| Configuration        | Behavior                                                    |
| -------------------- | ----------------------------------------------------------- |
| Key not set or empty | Open access — no `Authorization` header required            |
| Key set              | Requires `Authorization: Bearer <key>` on every `/mcp` call |

- `/health` and `/auth/status` are **never** gated by the API key.
- Uses **constant-time comparison** (`crypto.timingSafeEqual`) to prevent timing attacks.
- Returns HTTP **401** with `{"error": "Unauthorized: invalid or missing API key"}` on failure.

```bash
# With API key configured
curl -s http://localhost:3000/mcp \
  -H "Authorization: Bearer $GRAPH_MCP_API_KEY" \
  -d '{"jsonrpc":"2.0","id":1,"method":"ping"}'
```

---

## Protocol Lifecycle

### `initialize`

Clients **must** send `initialize` as the first request. The server validates the
client's requested `protocolVersion` and returns its own capabilities.

**Request:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-03-26",
    "capabilities": {},
    "clientInfo": { "name": "my-agent", "version": "1.0" }
  }
}
```

**Response:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-03-26",
    "capabilities": { "tools": { "listChanged": false } },
    "serverInfo": { "name": "m365-graph-mcp-gateway", "version": "1.0.0" }
  }
}
```

If the client sends an unsupported `protocolVersion`, the server returns a
`-32602` error with the list of supported versions.

After receiving the `initialize` response, the client should send a
`notifications/initialized` notification to complete the handshake.

### `ping`

Health check at the protocol level. Returns an empty result.

```json
// Request
{ "jsonrpc": "2.0", "id": 42, "method": "ping" }

// Response
{ "jsonrpc": "2.0", "id": 42, "result": {} }
```

### Notifications

Notifications are JSON-RPC messages with **no `id` field**. The server returns
HTTP **204 No Content** with no body. Supported notifications:

| Notification                | Description                                          |
| --------------------------- | ---------------------------------------------------- |
| `notifications/initialized` | Client signals it has completed initialization       |
| `notifications/cancelled`   | Client requests cancellation of an in-flight request |

`notifications/cancelled` accepts `params.requestId` (the `id` of the request to
cancel). If the request is still in-flight, it will be aborted.

### Rate Limiting

The `/mcp` endpoint enforces a per-client sliding-window rate limit. The default
is **100 requests per 60-second window**. When exceeded, the server returns:

- HTTP **429 Too Many Requests**
- Body: `{"error": "Rate limit exceeded. Try again in Ns."}`
- `Retry-After` header with the number of seconds to wait

Rate limiting is applied **after** API key authentication but **before** JSON-RPC
processing. Health and auth status endpoints are not rate-limited.

### Security Headers

All HTTP responses include the following hardened headers:

| Header                   | Value      |
| ------------------------ | ---------- |
| `X-Content-Type-Options` | `nosniff`  |
| `X-Frame-Options`        | `DENY`     |
| `Cache-Control`          | `no-store` |

### HTTP Timeouts

| Timeout            | Value | Description                              |
| ------------------ | ----- | ---------------------------------------- |
| Request timeout    | 180 s | Max wall-clock time for a single request |
| Headers timeout    | 10 s  | Max time to receive request headers      |
| Keep-alive timeout | 5 s   | Idle connection lifetime                 |

---

## JSON-RPC Validation

All inbound messages are validated against JSON-RPC 2.0 before dispatch.
Validation errors are returned with HTTP **200** (per JSON-RPC spec) and the
appropriate error code:

| Code     | Meaning                  | Example cause                                                         |
| -------- | ------------------------ | --------------------------------------------------------------------- |
| `-32700` | Parse error              | Body is not valid JSON                                                |
| `-32600` | Invalid Request          | Missing `jsonrpc:"2.0"`, bad `id` type, missing `method`              |
| `-32601` | Method not found         | Unknown method (not `initialize`, `ping`, `tools/list`, `tools/call`) |
| `-32602` | Invalid params           | Unsupported protocol version in `initialize`                          |
| `-32000` | Server error (catch-all) | Unhandled exception during tool execution                             |

**Key rules:**

- JSON-RPC errors always return HTTP 200. Only HTTP-level issues use non-200 codes (401 auth, 413 body too large, 429 rate limit, 404 unknown route).
- The `id` in error responses mirrors the request's `id` (or `null` if the `id` was invalid or absent).
- Array bodies (batch requests) are rejected with `-32600` — batch mode is not supported.

---

## Request Logging

Every request to `/mcp` is logged as structured JSON to stdout. Each log entry
includes:

| Field         | Description                                          |
| ------------- | ---------------------------------------------------- |
| `method`      | JSON-RPC method (e.g. `tools/call`, `ping`)          |
| `id`          | Request ID (string, number, or null)                 |
| `tool`        | Tool name (only for `tools/call` requests)           |
| `duration_ms` | Wall-clock time from request parse to response write |
| `status`      | `"ok"` or `"error"`                                  |
| `error_code`  | JSON-RPC error code (only on errors)                 |

Notifications (messages with no `id`) are **not** logged — only requests that
produce a response are recorded.

---

## Response Shape

Every `tools/call` response follows this contract:

```json
{
  "content": [{ "type": "text", "text": "Human-readable summary" }],
  "structuredContent": { "...": "machine-parseable payload" },
  "isError": true
}
```

- `content[0].text` — human-readable summary with titles, links, and snippets (same as `structuredContent.summary`)
- `structuredContent` — full structured data for programmatic use
- `isError` — only present (and `true`) on failures

### Error Responses

Errors use a `CODE: message` pattern:

| Code               | Meaning                                    |
| ------------------ | ------------------------------------------ |
| `AUTH_REQUIRED`    | Not logged in — call `auth` first          |
| `AUTH_EXPIRED`     | Token expired — re-authenticate via `auth` |
| `VALIDATION_ERROR` | Missing or invalid parameters              |
| `FORBIDDEN`        | Recipient domain not in allowlist          |
| `NOT_FOUND`        | Resource not found                         |
| `UPSTREAM_ERROR`   | Microsoft Graph API error                  |
| `INTERNAL_ERROR`   | Unexpected server error                    |

---

## Write Safety

These operations require `confirm=true` in the arguments. Without it, they
return a preview payload with `requires_confirmation: true` so the agent can
show the user what will happen before committing.

- `compose_email` with `mode: "send"`, `"reply"`, or `"reply_all"`
- `schedule_meeting`
- `respond_to_meeting` (accept, decline, tentativelyAccept, cancel)

**Pattern**: first call without `confirm` to get a preview, then re-call with
`confirm: true` after user approval.

---

## Domain Allowlist

All outbound recipient/attendee email addresses are checked against a
configurable domain allowlist before any email is sent or meeting is scheduled.

- **Configuration**: `guardrails.email.allowDomains` in `config.yaml`
- **Pattern matching**: supports exact domains (`contoso.com`) and wildcard
  suffixes (`*.contoso.com` matches `contoso.com` and all subdomains)
- **Error**: returns `FORBIDDEN` with message
  `"Domain @example.com is not in allowlist"` if no pattern matches
- **Applies to**: `compose_email` (all recipients in `to`), `schedule_meeting`
  (all attendees)
- **Runtime override**: set the `GRAPH_MCP_ALLOW_DOMAINS` environment variable
  to a JSON array of domain patterns (e.g.
  `["*.contoso.com", "*.fabrikam.com"]`). When present, this overrides the
  YAML list entirely.

---

## Tools Reference (11 tools)

### 1. `auth`

Authenticate with Microsoft Graph.

| Parameter | Type | Required | Description                                                                                              |
| --------- | ---- | -------- | -------------------------------------------------------------------------------------------------------- |
| `action`  | enum | yes      | `"login"` (interactive browser), `"login_device"` (device code for headless/SSH), `"logout"`, `"whoami"` |

**Example** — check current user:

```json
{ "name": "auth", "arguments": { "action": "whoami" } }
```

**Response** (`whoami`):

```json
{
  "id": "user-uuid",
  "display_name": "Jane Doe",
  "mail": "jane@contoso.com",
  "user_principal_name": "jane@contoso.com"
}
```

---

### 2. `find`

Search across Microsoft 365 — mail, files, and calendar events.

| Parameter      | Type     | Required | Description                                                                                                       |
| -------------- | -------- | -------- | ----------------------------------------------------------------------------------------------------------------- |
| `query`        | string   | yes      | Search query (min 1 char). Natural language: `"emails from John about Q4"`, `"budget spreadsheets"`, `"meetings"` |
| `kql`          | string   | no       | Raw KQL query passed directly to Graph Search API. When provided, overrides `query` for the search request.       |
| `entity_types` | string[] | no       | Filter to specific types: `"mail"`, `"files"`, `"events"`. Default: all three.                                    |
| `start_date`   | string   | no       | ISO 8601 datetime for date-range event queries. Example: `"2026-02-23T00:00:00"`                                  |
| `end_date`     | string   | no       | ISO 8601 datetime. Required alongside `start_date`. Example: `"2026-02-24T00:00:00"`                              |
| `top`          | integer  | no       | Max results (1-50, default 10)                                                                                    |
| `max_chars`    | integer  | no       | Max output chars (1-50000, default from config)                                                                   |

#### Event search behavior

There are two modes for event search, selected automatically:

**Date-range mode** (when `start_date` AND `end_date` are provided):

- Uses the CalendarView API — returns all events in the range including expanded recurring instances
- Results include: organizer (name + email), attendees (name, email, response status), location, Teams join URL, body preview
- Provider: `"calendar-view"`
- **Important**: resolve relative dates to concrete ISO 8601 before calling. Examples:
  - "Monday" (today is Sat Feb 21) → `start_date: "2026-02-23T00:00:00"`, `end_date: "2026-02-24T00:00:00"`
  - "next week" → `start_date: "2026-02-23T00:00:00"`, `end_date: "2026-03-02T00:00:00"`
  - "tomorrow" → `start_date: "2026-02-22T00:00:00"`, `end_date: "2026-02-23T00:00:00"`

**Text-search mode** (no dates provided):

- Uses Graph Search API — full-text search across all events
- Good for queries like "find the Q4 planning meeting" or "meetings with John"
- Results may span all time periods; no date filtering
- Provider: `"graph-search"`

#### File search behavior

Uses Graph Search API.

#### Response notes

- `content[0].text` contains the full human-readable summary with titles, document/event links, and snippets — always present this to the user.
- `structuredContent.results[]` has the full structured data including `source_url` (files), `web_link` (events), attendees, organizer, etc.
- File results include a `source_url` (SharePoint/OneDrive link) — always show this link to the user.
- Event results include a `web_link` (Outlook link) and `teams_join_url` — show these when relevant.

**Example** — meetings on a specific day:

```json
{
  "name": "find",
  "arguments": {
    "query": "meetings",
    "entity_types": ["events"],
    "start_date": "2026-02-23T00:00:00",
    "end_date": "2026-02-24T00:00:00",
    "top": 10
  }
}
```

**Example** — search emails:

```json
{
  "name": "find",
  "arguments": {
    "query": "budget report from finance",
    "entity_types": ["mail"],
    "top": 5
  }
}
```

**Example** — search across everything:

```json
{
  "name": "find",
  "arguments": {
    "query": "quarterly review"
  }
}
```

**Response** (date-range events):

```json
{
  "providers": ["calendar-view"],
  "query": "meetings",
  "entity_types": ["events"],
  "start_date": "2026-02-23T00:00:00",
  "end_date": "2026-02-24T00:00:00",
  "top": 10,
  "elapsed_ms": 320,
  "timezone": "America/New_York",
  "result_count": 3,
  "summary": "[1] Sprint Planning\n   Link: https://outlook.office365.com/owa/?itemid=...\n   Agenda: review sprint backlog...\n[2] 1:1 with Manager\n   Link: https://outlook.office365.com/owa/?itemid=...\n[3] Team Standup",
  "truncated": false,
  "results": [
    {
      "type": "event",
      "id": "AAMk...",
      "subject": "Sprint Planning",
      "start": "2026-02-23T09:00:00.0000000",
      "end": "2026-02-23T10:00:00.0000000",
      "organizer": { "name": "Jane Doe", "address": "jane@contoso.com" },
      "attendee_count": 5,
      "attendees": [
        { "name": "Bob Smith", "email": "bob@contoso.com", "type": "required", "response": "accepted" },
        { "name": "Alice Jones", "email": "alice@contoso.com", "type": "required", "response": "tentativelyAccepted" }
      ],
      "location": "Room 4B",
      "is_online_meeting": true,
      "teams_join_url": "https://teams.microsoft.com/l/meetup-join/...",
      "web_link": "https://outlook.office365.com/owa/?itemid=...",
      "body_preview": "Agenda: review sprint backlog..."
    }
  ]
}
```

**Response** (mail):

```json
{
  "results": [
    {
      "type": "mail",
      "id": "AAMk...",
      "subject": "Q4 Budget Report",
      "from": { "emailAddress": { "name": "Finance Team", "address": "finance@contoso.com" } },
      "received_at": "2026-02-20T14:30:00Z",
      "snippet": "Please find the attached Q4 budget report..."
    }
  ]
}
```

**Response** (files):

```json
{
  "results": [
    {
      "type": "file",
      "id": "01XYZ...",
      "drive_id": "b!abc...",
      "name": "Budget_Q4_2026.xlsx",
      "path": "/drives/b!abc.../root:/Finance/Reports",
      "modified_at": "2026-02-20T14:30:00Z",
      "size": 45321,
      "web_url": "https://contoso.sharepoint.com/...",
      "snippet": "Quarterly budget allocation and variance analysis..."
    }
  ]
}
```

---

### 3. `get_email`

Fetch a specific email by ID. Use after `find` to retrieve full details.

| Parameter      | Type    | Required | Description                                                          |
| -------------- | ------- | -------- | -------------------------------------------------------------------- |
| `message_id`   | string  | yes      | Email ID from `find` results                                         |
| `include_full` | boolean | no       | `true` for expanded fields (body, all recipients). Default: minimal. |

**Example**:

```json
{ "name": "get_email", "arguments": { "message_id": "AAMk...", "include_full": true } }
```

**Response** (minimal):

```json
{
  "id": "AAMk...",
  "subject": "Q4 Budget Report",
  "from": { "address": "finance@contoso.com", "name": "Finance Team" },
  "sent_at": "2026-02-20T14:25:00Z",
  "received_at": "2026-02-20T14:30:00Z",
  "is_read": true,
  "body_preview": "Please find the attached Q4 budget report..."
}
```

**Response** (full — `include_full: true`):

```json
{
  "id": "AAMk...",
  "subject": "Q4 Budget Report",
  "from": { "address": "finance@contoso.com", "name": "Finance Team" },
  "sent_at": "2026-02-20T14:25:00Z",
  "received_at": "2026-02-20T14:30:00Z",
  "is_read": true,
  "body_preview": "Please find the attached Q4 budget report...",
  "to": [{ "emailAddress": { "name": "Jane Doe", "address": "jane@contoso.com" } }],
  "cc": [],
  "conversation_id": "AAQk...",
  "body_text": "Please find the attached Q4 budget report. Key highlights: ...",
  "body_truncated": false,
  "web_link": "https://outlook.office365.com/owa/?itemid=..."
}
```

---

### 4. `get_event`

Fetch a specific calendar event by ID. Use after `find` to retrieve full details.

| Parameter      | Type    | Required | Description                                                                            |
| -------------- | ------- | -------- | -------------------------------------------------------------------------------------- |
| `event_id`     | string  | yes      | Event ID from `find` results                                                           |
| `include_full` | boolean | no       | `true` for full attendee list, body preview, online meeting details. Default: minimal. |

**Example**:

```json
{ "name": "get_event", "arguments": { "event_id": "AAMk...", "include_full": true } }
```

**Response** (full):

```json
{
  "id": "AAMk...",
  "subject": "Sprint Planning",
  "start": "2026-02-23T09:00:00.0000000",
  "end": "2026-02-23T10:00:00.0000000",
  "organizer": { "name": "Jane Doe", "address": "jane@contoso.com" },
  "attendee_count": 5,
  "attendees": [{ "name": "Bob Smith", "email": "bob@contoso.com", "type": "required", "response": "accepted" }],
  "location": "Room 4B",
  "is_online_meeting": true,
  "teams_join_url": "https://teams.microsoft.com/l/meetup-join/...",
  "web_link": "https://outlook.office365.com/owa/?itemid=...",
  "body_preview": "Agenda: review sprint backlog..."
}
```

---

### 5. `get_email_thread`

Fetch all messages in an email conversation thread. Provide either a
`conversation_id` (from `get_email` with `include_full=true`) or a `message_id`
(the tool resolves the `conversationId` automatically). Returns messages sorted
oldest-first.

| Parameter         | Type    | Required         | Description                                                             |
| ----------------- | ------- | ---------------- | ----------------------------------------------------------------------- |
| `conversation_id` | string  | one of the two\* | Conversation ID (from `get_email` response when `include_full=true`)    |
| `message_id`      | string  | one of the two\* | Message ID — the tool fetches the message to resolve its conversationId |
| `top`             | integer | no               | Max messages to return (1-50, default 10)                               |
| `include_full`    | boolean | no               | `true` for expanded fields (body, all recipients). Default: minimal.    |

\*At least one of `conversation_id` or `message_id` must be provided.

**Example** — get thread by conversation ID:

```json
{
  "name": "get_email_thread",
  "arguments": { "conversation_id": "AAQk...", "include_full": true }
}
```

**Example** — get thread by message ID:

```json
{
  "name": "get_email_thread",
  "arguments": { "message_id": "AAMk...", "top": 20 }
}
```

**Response**:

```json
{
  "conversation_id": "AAQk...",
  "message_count": 4,
  "messages": [
    {
      "id": "AAMk...",
      "subject": "Re: Q4 Budget Report",
      "from": { "address": "finance@contoso.com", "name": "Finance Team" },
      "received_at": "2026-02-18T10:00:00Z",
      "is_read": true,
      "web_link": "https://outlook.office365.com/owa/?itemid=..."
    },
    {
      "id": "AAMk...",
      "subject": "Re: Q4 Budget Report",
      "from": { "address": "jane@contoso.com", "name": "Jane Doe" },
      "received_at": "2026-02-19T14:30:00Z",
      "is_read": true,
      "web_link": "https://outlook.office365.com/owa/?itemid=..."
    }
  ]
}
```

> **Implementation note**: messages are sorted client-side by
> `receivedDateTime` ascending (oldest-first). Exchange Online does not support
> combining `$filter` on `conversationId` with `$orderby`, so sorting is
> performed after retrieval.

---

### 6. `get_file_metadata`

Get metadata for a OneDrive/SharePoint file by `drive_id` and `item_id` (both
returned by `find` in file results). Returns file name, path, size, modified
date, web URL, and creator info.

| Parameter      | Type    | Required | Description                                                                                |
| -------------- | ------- | -------- | ------------------------------------------------------------------------------------------ |
| `drive_id`     | string  | yes      | Drive ID from `find` file results (`resource.parentReference.driveId` or `drive_id` field) |
| `item_id`      | string  | yes      | Item ID from `find` file results (`resource.id` or `item_id` field)                        |
| `include_full` | boolean | no       | `true` for expanded fields (parent path, created/modified by). Default: minimal.           |

**Example**:

```json
{
  "name": "get_file_metadata",
  "arguments": { "drive_id": "b!abc...", "item_id": "01XYZ...", "include_full": true }
}
```

**Response** (minimal):

```json
{
  "id": "01XYZ...",
  "drive_id": "b!abc...",
  "name": "Budget_Q4_2026.xlsx",
  "path": "/drives/b!abc.../root:/Finance/Reports",
  "modified_at": "2026-02-20T14:30:00Z",
  "size": 45321,
  "web_url": "https://contoso.sharepoint.com/sites/Finance/Shared Documents/Budget_Q4_2026.xlsx"
}
```

**Response** (full — `include_full: true`):

```json
{
  "id": "01XYZ...",
  "drive_id": "b!abc...",
  "name": "Budget_Q4_2026.xlsx",
  "path": "/drives/b!abc.../root:/Finance/Reports",
  "modified_at": "2026-02-20T14:30:00Z",
  "size": 45321,
  "web_url": "https://contoso.sharepoint.com/sites/Finance/Shared Documents/Budget_Q4_2026.xlsx",
  "file": { "mimeType": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" },
  "created_by": { "user": { "displayName": "Jane Doe" } },
  "modified_by": { "user": { "displayName": "Bob Smith" } },
  "parent_reference": { "driveId": "b!abc...", "path": "/drives/b!abc.../root:/Finance/Reports" }
}
```

---

### 7. `get_file_content`

Download and return the content of a OneDrive/SharePoint file. Text files
(`text/*`, `application/json`, `application/xml`, `application/javascript`) are
returned inline as UTF-8 text with optional truncation. Binary files are returned
as base64-encoded strings. Maximum file size: 10 MB.

| Parameter   | Type    | Required | Description                                                                    |
| ----------- | ------- | -------- | ------------------------------------------------------------------------------ |
| `drive_id`  | string  | yes      | Drive ID from `find` file results                                              |
| `item_id`   | string  | yes      | Item ID from `find` file results                                               |
| `max_chars` | integer | no       | Max chars for text content (1-50000, default from config). Ignored for binary. |

**Example** — read a text file:

```json
{
  "name": "get_file_content",
  "arguments": { "drive_id": "b!abc...", "item_id": "01XYZ...", "max_chars": 10000 }
}
```

**Response** (text):

```json
{
  "name": "meeting-notes.md",
  "mime_type": "text/markdown",
  "size_bytes": 2048,
  "encoding": "text",
  "content": "# Sprint Planning Notes\n\n## Action Items\n- Review backlog...",
  "truncated": false
}
```

**Response** (binary):

```json
{
  "name": "logo.png",
  "mime_type": "image/png",
  "size_bytes": 15360,
  "encoding": "base64",
  "content": "iVBORw0KGgoAAAANSUhEUgAA...",
  "truncated": false
}
```

**Error** — file too large:

```json
{
  "isError": true,
  "content": [{ "type": "text", "text": "VALIDATION_ERROR: file 'database.bak' is 52428800 bytes, exceeds 10485760 byte limit" }]
}
```

---

### 8. `compose_email`

Compose an email: draft, send, reply, or reply-all. Write operations require `confirm=true`.

| Parameter         | Type               | Required            | Description                                                                                              |
| ----------------- | ------------------ | ------------------- | -------------------------------------------------------------------------------------------------------- |
| `mode`            | enum               | yes                 | `"draft"`, `"send"`, `"reply"`, `"reply_all"`                                                            |
| `to`              | string or string[] | for draft/send      | Recipient email(s). Comma-separated string or array.                                                     |
| `subject`         | string             | for draft/send      | Email subject line                                                                                       |
| `body_html`       | string             | yes                 | Email body (HTML). Sanitized server-side.                                                                |
| `message_id`      | string             | for reply/reply_all | ID of the message to reply to                                                                            |
| `attachments`     | object[]           | no                  | Inline attachments: `{ name, content_base64, content_type }`                                             |
| `attachment_refs` | object[]           | no                  | M365 file references: `{ drive_id, item_id, name }`                                                      |
| `confirm`         | boolean            | no                  | `true` to execute send/reply. Without it, `send` returns a preview; `reply`/`reply_all` creates a draft. |

#### Attachment limits

- Maximum **10** attachments per email (inline + refs combined)
- Maximum **5 MB** per individual attachment
- Maximum **10 MB** total across all attachments
- Exceeding any limit returns `VALIDATION_ERROR`

**Example** — send an email:

```json
{
  "name": "compose_email",
  "arguments": {
    "mode": "send",
    "to": ["bob@contoso.com"],
    "subject": "Meeting notes",
    "body_html": "<p>Hi Bob, here are the notes from today's meeting.</p>",
    "confirm": true
  }
}
```

**Example** — reply to an email:

```json
{
  "name": "compose_email",
  "arguments": {
    "mode": "reply",
    "message_id": "AAMk...",
    "body_html": "<p>Thanks, I'll review this today.</p>",
    "confirm": true
  }
}
```

> **Guardrail**: for `draft` and `send` modes, all recipient addresses in `to`
> are checked against the [Domain Allowlist](#domain-allowlist). If any domain
> is not permitted, the tool returns `FORBIDDEN` before creating the draft or
> sending. Reply modes (`reply`, `reply_all`) are **not** domain-checked — they
> reply to the existing conversation's recipients.
>
> **Confirm behavior by mode**:
>
> - `send` without `confirm` — returns a `requires_confirmation` preview
> - `send` with `confirm: true` — sends immediately
> - `reply`/`reply_all` without `confirm` — creates a draft in the user's mailbox
> - `reply`/`reply_all` with `confirm: true` — sends the reply immediately
> - `draft` — always creates a draft (no `confirm` needed)

---

### 9. `schedule_meeting`

Schedule a meeting. Supports explicit start/end times or automatic free-slot
finding. Supports Teams meetings and agendas. Requires `confirm=true`.

| Parameter          | Type     | Required | Description                                                                                                            |
| ------------------ | -------- | -------- | ---------------------------------------------------------------------------------------------------------------------- |
| `subject`          | string   | yes      | Meeting subject                                                                                                        |
| `attendees`        | string[] | no       | Attendee email addresses                                                                                               |
| `start`            | string   | no\*     | Explicit start (ISO 8601 with offset, e.g. `"2026-02-23T09:00:00-05:00"`)                                              |
| `end`              | string   | no\*     | Explicit end (ISO 8601 with offset)                                                                                    |
| `preferred_start`  | string   | no\*     | Window start for auto free-slot finding                                                                                |
| `preferred_end`    | string   | no\*     | Window end for auto free-slot finding                                                                                  |
| `duration_minutes` | integer  | no       | Meeting duration (1-480, default 60). Used with preferred window.                                                      |
| `timezone`         | string   | no       | IANA timezone (e.g. `"America/New_York"`). Default: configured timezone (see [Timezone Handling](#timezone-handling)). |
| `agenda`           | string   | no       | Meeting agenda text                                                                                                    |
| `teams_meeting`    | boolean  | no       | `true` to create a Teams meeting with join link                                                                        |
| `body_html`        | string   | no       | Custom HTML body (overrides agenda)                                                                                    |
| `confirm`          | boolean  | no       | `true` to create. Without it, returns a preview.                                                                       |

\*Provide either `start` + `end` OR `preferred_start` + `preferred_end`.

**Example** — schedule with auto free-slot:

```json
{
  "name": "schedule_meeting",
  "arguments": {
    "subject": "Project Sync",
    "attendees": ["bob@contoso.com", "alice@contoso.com"],
    "preferred_start": "2026-02-23T08:00:00-05:00",
    "preferred_end": "2026-02-23T17:00:00-05:00",
    "duration_minutes": 30,
    "timezone": "America/New_York",
    "teams_meeting": true,
    "agenda": "Discuss project milestones and blockers",
    "confirm": true
  }
}
```

> **Guardrail**: all attendee addresses are checked against the
> [Domain Allowlist](#domain-allowlist). If any domain is not permitted, the
> tool returns `FORBIDDEN` before creating the meeting.

---

### 10. `respond_to_meeting`

Respond to a meeting invitation or cancel a meeting you organized. Requires
`confirm=true` for accept/decline/cancel.

| Parameter   | Type    | Required | Description                                                                     |
| ----------- | ------- | -------- | ------------------------------------------------------------------------------- |
| `event_id`  | string  | yes      | Event ID                                                                        |
| `action`    | enum    | yes      | `"accept"`, `"decline"`, `"tentativelyAccept"`, `"cancel"`, `"reply_all_draft"` |
| `comment`   | string  | no       | Optional comment with response (e.g. "I'll be 5 min late")                      |
| `body_html` | string  | no       | HTML body for `reply_all_draft` mode                                            |
| `confirm`   | boolean | no       | `true` to execute accept/decline/cancel. Not needed for `reply_all_draft`.      |

**Example** — accept a meeting:

```json
{
  "name": "respond_to_meeting",
  "arguments": {
    "event_id": "AAMk...",
    "action": "accept",
    "comment": "Looking forward to it",
    "confirm": true
  }
}
```

**Example** — create a reply-all draft to meeting attendees:

```json
{
  "name": "respond_to_meeting",
  "arguments": {
    "event_id": "AAMk...",
    "action": "reply_all_draft",
    "body_html": "<p>Quick update: I've shared the deck in the Teams channel.</p>"
  }
}
```

---

### 11. `audit_list`

List recent audit log entries. Records all write actions and blocked attempts.

| Parameter | Type    | Required | Description                                       |
| --------- | ------- | -------- | ------------------------------------------------- |
| `limit`   | integer | no       | Number of entries to return (1-1000, default 100) |

**Example**:

```json
{ "name": "audit_list", "arguments": { "limit": 20 } }
```

**Response**:

```json
{
  "count": 3,
  "items": [
    {
      "id": "uuid",
      "timestamp": "2026-02-21T10:30:00.000Z",
      "action": "compose_email_send",
      "user": "jane@contoso.com",
      "details": { "recipientCount": 1, "subject": "Meeting notes" },
      "status": "success"
    }
  ]
}
```

---

## Common Workflows

### "Show me my meetings on Monday"

1. Resolve "Monday" to concrete dates (e.g. today is Sat Feb 21 → Monday = Feb 23)
2. Call `find` with `entity_types: ["events"]`, `start_date`, `end_date`

```json
{
  "name": "find",
  "arguments": {
    "query": "meetings",
    "entity_types": ["events"],
    "start_date": "2026-02-23T00:00:00",
    "end_date": "2026-02-24T00:00:00"
  }
}
```

### "What's on my calendar this week?"

```json
{
  "name": "find",
  "arguments": {
    "query": "meetings",
    "entity_types": ["events"],
    "start_date": "2026-02-21T00:00:00",
    "end_date": "2026-02-28T00:00:00"
  }
}
```

### "Find emails from John about the budget and reply"

1. Search: `find` with `query: "emails from John about budget"`, `entity_types: ["mail"]`
2. Get details: `get_email` with the `id` from step 1, `include_full: true`
3. Read thread: `get_email_thread` with the `conversation_id` from step 2 to see full context
4. Reply: `compose_email` with `mode: "reply"`, `message_id`, `body_html`, `confirm: true`

### "Prepare me for my 2pm meeting"

1. Find the meeting: `find` with `entity_types: ["events"]`, `start_date`/`end_date` around 2pm
2. Get full details: `get_event` with the `event_id` from step 1, `include_full: true`
3. Search for context: `find` with the meeting subject/attendees to locate related emails and files

> **Note**: Briefing composition (combining meeting details, related docs, and
> attendee context into a coherent preparation summary) is handled by the
> consuming LLM layer, not this gateway.

### "Schedule a 30-min Teams call with Bob tomorrow morning"

```json
{
  "name": "schedule_meeting",
  "arguments": {
    "subject": "Sync with Bob",
    "attendees": ["bob@contoso.com"],
    "preferred_start": "2026-02-22T08:00:00-05:00",
    "preferred_end": "2026-02-22T12:00:00-05:00",
    "duration_minutes": 30,
    "teams_meeting": true,
    "confirm": true
  }
}
```

### "Read the contents of a document I found"

1. Search: `find` with `query: "project proposal"`, `entity_types: ["files"]`
2. Get content: `get_file_content` with `drive_id` and `item_id` from the file result

```json
{
  "name": "get_file_content",
  "arguments": { "drive_id": "b!abc...", "item_id": "01XYZ...", "max_chars": 20000 }
}
```

### "Catch me up on an email conversation"

1. Search: `find` with `query: "project kickoff from Alice"`, `entity_types: ["mail"]`
2. Get email: `get_email` with the `id` from step 1, `include_full: true` (to get `conversation_id`)
3. Get thread: `get_email_thread` with the `conversation_id` from step 2

```json
{
  "name": "get_email_thread",
  "arguments": { "conversation_id": "AAQk...", "include_full": true }
}
```

---

## Timezone Handling

All calendar/event operations use a **configured default timezone** (set in
`config.yaml` under `calendar.defaultTimezone`; defaults to `UTC`). This affects:

- **`find`** (date-range mode) — event times in results are returned in the
  configured timezone. The response includes a `timezone` field indicating which
  timezone was used.
- **`get_event`** — event start/end times are returned in the configured timezone.
- **`schedule_meeting`** — when using auto free-slot finding, the `timezone`
  parameter defaults to the configured timezone. When providing explicit `start`
  and `end`, include the UTC offset in the ISO 8601 string (e.g.
  `"2026-02-23T09:00:00-05:00"` for America/New_York).

The default timezone is set in the gateway's `config.yaml` under
`calendar.defaultTimezone` using IANA timezone names (e.g. `America/New_York`,
`Europe/London`, `Asia/Tokyo`). The gateway maps IANA names to the Windows
timezone names required by the Graph API internally. Deployments may override
this value per environment.

**Agent guidance**: When the user says "9am" without specifying a timezone, use
the configured default timezone offset. If the default is `UTC`, use `+00:00`.
If it is `America/New_York`, use `-05:00` (standard) or `-04:00` (DST).

---

## Output Minimization

By default, responses include only high-signal fields (IDs, subject/title,
sender/organizer, timestamps, links, short snippets).

Pass `include_full=true` on `get_email`, `get_event`, `get_email_thread`, and
`get_file_metadata` to expand:

- **Email**: full body text, all recipients (to, cc), conversation ID, web link
- **Event**: full attendee list with response status, body preview, online meeting details
- **Email thread**: full body and recipients for each message in the thread
- **File metadata**: file object (with mimeType), created/modified by (Graph objects), parent reference

---

## Caching

Read-only `get_*` tools use a short-lived in-memory micro-cache to reduce
redundant Graph API calls during multi-step agent workflows.

| Tool                | Cache Key                                      | TTL  |
| ------------------- | ---------------------------------------------- | ---- |
| `get_email`         | `email:{message_id}`                           | 30 s |
| `get_event`         | `event:{event_id}`                             | 30 s |
| `get_email_thread`  | `thread:{conversationId}:{include_full}:{top}` | 30 s |
| `get_file_metadata` | `file:{drive_id}:{item_id}`                    | 30 s |

- `find` results and `get_file_content` downloads are **not** cached.
- Write operations (`compose_email`, `schedule_meeting`, `respond_to_meeting`)
  are never cached.
- Maximum 500 cache entries; oldest evicted when full.
