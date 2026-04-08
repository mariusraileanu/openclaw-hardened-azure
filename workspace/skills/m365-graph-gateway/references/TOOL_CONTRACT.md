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

### Identity Binding

The gateway enforces **strict identity pinning** to ensure the cached Microsoft
identity matches the expected user for a given deployment. This prevents
cross-user token reuse when multiple containers share NFS-backed storage.

**`EXPECTED_AAD_OBJECT_ID` is required** — the gateway refuses to operate without
it. Login, token acquisition, and identity verification all fail with
`CONFIG_ERROR` if this value is not set.

**OID-based account matching**:

- On every `resolveAccount()` call, the gateway scans all cached MSAL accounts
  and selects the one whose `idTokenClaims.oid` or `localAccountId` matches
  `EXPECTED_AAD_OBJECT_ID`. It never picks the "first" account.
- If no account matches: returns null (auth required)
- If exactly one matches: uses that account
- If multiple match (corrupted cache): quarantines the cache and throws
  `TOKEN_CACHE_CORRUPTED`
- If a single account exists but its OID doesn't match: quarantines the cache
  and throws `AUTH_MISMATCH`

**Startup verification** (`verifyIdentityBinding()`):

- Runs at container startup before accepting requests
- Uses the same OID-based matching logic
- Writes a `token-cache.meta.json` sidecar file on success (records OID,
  timestamp, and user principal name)
- On mismatch or corruption: quarantines the cache by renaming it

**The `auth` tool's `status` action reports**:

- `expected_object_id` — from `EXPECTED_AAD_OBJECT_ID` (null if not configured)
- `actual_object_id` — from cached account (null if no account)
- `identity_match` — boolean comparison (null if OID not configured)
- `identity_binding_status` — one of:
  - `'valid'` — OID is configured and matches the cached account
  - `'invalid'` — OID is configured but does not match (or cache corrupted)
  - `'missing'` — `EXPECTED_AAD_OBJECT_ID` is not set (gateway non-functional)

**`USER_SLUG` is required** — controls per-user storage path isolation. Without
it, the gateway refuses to resolve any storage path (token cache, audit log).
Format: lowercase alphanumeric + hyphens, 2–31 chars, starting with a letter
(e.g. `jdoe`, `dev-local`). Set it in `.env` for local development.

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

| Code                         | Meaning                                                                    |
| ---------------------------- | -------------------------------------------------------------------------- |
| `AUTH_REQUIRED`              | Not logged in — call `auth` first                                          |
| `AUTH_EXPIRED`               | Token expired — re-authenticate via `auth`                                 |
| `AUTH_MISMATCH`              | Cached identity OID does not match `EXPECTED_AAD_OBJECT_ID`                |
| `CONFIG_ERROR`               | Required config missing (e.g. `EXPECTED_AAD_OBJECT_ID` not set)            |
| `TOKEN_CACHE_CORRUPTED`      | Token cache in invalid state (e.g. multiple OID matches)                   |
| `MULTIPLE_ACCOUNTS_IN_CACHE` | Token cache contains >1 account — logout and re-login                      |
| `CACHE_DECRYPTION_FAILED`    | Token cache exists but cannot be decrypted (wrong key/corrupt)             |
| `TOKEN_IDENTITY_MISMATCH`    | Cached identity does not match expected Entra object ID                    |
| `FILE_TOO_LARGE`             | File exceeds 10 MB inline limit — use `download_url` instead               |
| `VALIDATION_ERROR`           | Missing or invalid parameters                                              |
| `FORBIDDEN`                  | Recipient domain not in allowlist                                          |
| `NOT_FOUND`                  | Resource not found                                                         |
| `UPSTREAM_ERROR`             | Microsoft Graph API error                                                  |
| `INTERNAL_ERROR`             | Unexpected server error                                                    |
| `MEETING_NOT_RESOLVABLE`     | joinWebUrl filter returned 0 meetings — expired or no calendar association |
| `MISSING_JOIN_WEB_URL`       | Chat has no onlineMeetingInfo.joinWebUrl                                   |
| `TRANSCRIPT_NOT_AVAILABLE`   | Transcription not enabled, not ready, meeting expired, or no permission    |
| `UNSUPPORTED_FILE_TYPE`      | File extension not supported for parsed mode extraction                    |
| `PARSE_ERROR`                | File parsing failed (corrupt or unreadable file)                           |
| `INVALID_KQL_FIELD`          | KQL filter uses an unsupported field name                                  |
| `INVALID_KQL_FILTER`         | KQL filter_expression has invalid syntax (unbalanced quotes/parens)        |

### Auth Recovery Workflow

When any tool call returns `AUTH_EXPIRED` or `AUTH_REQUIRED`, the client must
initiate device code re-authentication before retrying. Azure AD Conditional
Access enforces a 7-day sign-in frequency, so every user will hit token expiry
on a rolling basis — this is expected, not a bug.

#### 1. Detect the error

Check **both** flags on every `tools/call` response:

```json
{
  "result": {
    "isError": true,
    "structuredContent": {
      "error_code": "AUTH_EXPIRED",
      "message": "AUTH_EXPIRED: refresh token expired — re-authenticate with login_device"
    }
  }
}
```

Trigger recovery when `result.isError === true` **and**
`result.structuredContent.error_code` is `"AUTH_EXPIRED"` or `"AUTH_REQUIRED"`.

#### 2. Initiate device code login

```json
{ "name": "auth", "arguments": { "action": "login_device" } }
```

Response (immediate, non-blocking):

```json
{
  "success": true,
  "mode": "device",
  "pending": true,
  "verification_uri": "https://microsoft.com/devicelogin",
  "user_code": "ABCD1234",
  "expires_in": 900,
  "message": "To sign in, use a web browser to open https://microsoft.com/devicelogin and enter the code ABCD1234 to authenticate."
}
```

#### 3. Present the device code to the user

Display `verification_uri` and `user_code` prominently. The user must open the
URL in a browser and enter the code to complete authentication. The code expires
after `expires_in` seconds (typically 15 minutes).

#### 4. Poll for completion

```json
{ "name": "auth", "arguments": { "action": "status" } }
```

Poll every **5 seconds** until the response shows:

```json
{
  "logged_in": true,
  "graph_reachable": true,
  "device_code_pending": false
}
```

Stop polling and report failure if:

- `expires_in` seconds have elapsed since step 2, or
- `device_code_pending` becomes `false` while `logged_in` is still `false`
  (user cancelled or code expired)

#### 5. Retry the original tool call

Once `logged_in: true` and `graph_reachable: true`, re-issue the exact tool call
that originally returned `AUTH_EXPIRED` / `AUTH_REQUIRED`.

#### Error code reference

| Code            | Meaning                                              | Recovery        |
| --------------- | ---------------------------------------------------- | --------------- |
| `AUTH_EXPIRED`  | Had a session but the refresh token expired          | Steps 2–5 above |
| `AUTH_REQUIRED` | No cached account at all (first run or after logout) | Steps 2–5 above |

---

## Write Safety

These operations require `confirm=true` in the arguments. Without it, they
return a preview payload with `requires_confirmation: true` so the agent can
show the user what will happen before committing.

- `compose_email` with `mode: "send"`, `"reply"`, or `"reply_all"`
- `schedule_meeting`
- `respond_to_meeting` (accept, decline, tentativelyAccept, cancel)
- `send_chat_message`

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

## Tools Reference (22 tools)

### 1. `auth`

Authenticate with Microsoft Graph. Includes a `status` action for diagnostics.

| Parameter | Type | Required | Description                                                                                                                        |
| --------- | ---- | -------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `action`  | enum | yes      | `"login"` (interactive browser), `"login_device"` (device code for headless/SSH), `"logout"`, `"whoami"`, `"status"` (diagnostics) |

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

**Example** — device code login (two-phase, non-blocking):

```json
{ "name": "auth", "arguments": { "action": "login_device" } }
```

**Response** (`login_device`):

```json
{
  "success": true,
  "mode": "device",
  "pending": true,
  "verification_uri": "https://microsoft.com/devicelogin",
  "user_code": "ABCD1234",
  "expires_in": 900,
  "message": "To sign in, use a web browser to open https://microsoft.com/devicelogin and enter the code ABCD1234 to authenticate."
}
```

The `login_device` action returns **immediately** with the verification URI and
user code. The actual token acquisition continues in the background. Present the
`verification_uri` and `user_code` to the user so they can complete
authentication. Then poll with `{ "action": "status" }` until `logged_in`
becomes `true`.

In stdio transport mode, the server also emits an MCP `notifications/message`
notification at level `notice` with the same device code info, so clients that
display MCP logging notifications will surface it in real time.

**Example** — auth diagnostics:

```json
{ "name": "auth", "arguments": { "action": "status" } }
```

**Response** (`status`):

```json
{
  "logged_in": true,
  "user": "jane@contoso.com",
  "cache_file_exists": true,
  "cache_encrypted": true,
  "cache_decryptable": true,
  "encryption_key_configured": true,
  "account_count": 1,
  "graph_reachable": true,
  "device_code_pending": false,
  "expected_object_id": "11111111-1111-4111-8111-111111111111",
  "actual_object_id": "11111111-1111-4111-8111-111111111111",
  "identity_match": true,
  "identity_binding_status": "valid"
}
```

Returns structured diagnostics for troubleshooting auth issues. Fields:

| Field                          | Type    | Description                                                                                  |
| ------------------------------ | ------- | -------------------------------------------------------------------------------------------- |
| `logged_in`                    | boolean | Whether a valid account is resolved from the cache                                           |
| `user`                         | string  | User principal name of the logged-in user (null if not logged in)                            |
| `cache_file_exists`            | boolean | Whether the token cache file exists on disk                                                  |
| `cache_encrypted`              | boolean | Whether the cache file uses AES-256-GCM encryption                                           |
| `cache_decryptable`            | boolean | Whether the cache can be successfully decrypted/parsed                                       |
| `encryption_key_configured`    | boolean | Whether `GRAPH_TOKEN_CACHE_ENCRYPTION_KEY` env var is set                                    |
| `account_count`                | number  | Number of accounts in the cache (should be 0 or 1)                                           |
| `graph_reachable`              | boolean | Whether a test call to Microsoft Graph `/me` succeeds                                        |
| `device_code_pending`          | boolean | Whether a device code login flow is currently in progress                                    |
| `expected_object_id`           | string  | Expected Entra object ID from `EXPECTED_AAD_OBJECT_ID` (null if not configured)              |
| `actual_object_id`             | string  | Entra object ID from the cached account (null if no cached account)                          |
| `identity_match`               | boolean | Whether the Entra object ID matches (null if not configured)                                 |
| `identity_binding_status`      | string  | Overall binding state: `"valid"`, `"invalid"`, or `"missing"` (see Identity Binding section) |
| `device_code_verification_uri` | string  | Verification URI (only present when `device_code_pending` is true)                           |
| `device_code_user_code`        | string  | User code to enter (only present when `device_code_pending` is true)                         |
| `error`                        | string  | Error message if any check failed (only present on errors)                                   |

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
      "item_id": "01XYZ...",
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

> **Note**: File results include both `id` and `item_id` (same value) for
> clarity. Use `drive_id` + `item_id` when calling `get_file_metadata`,
> `get_file_content`, or other file tools.

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
| `conversation_id` | string  | one of the two*  | Conversation ID (from `get_email` response when `include_full=true`)    |
| `message_id`      | string  | one of the two*  | Message ID — the tool fetches the message to resolve its conversationId |
| `top`             | integer | no               | Max messages to return (1-50, default 10)                               |
| `include_full`    | boolean | no               | `true` for expanded fields (body, all recipients). Default: minimal.    |

*At least one of `conversation_id` or `message_id` must be provided.

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

Access file content from OneDrive/SharePoint. Supports four modes to avoid
unnecessary large downloads.

| Parameter   | Type    | Required | Description                                                                              |
| ----------- | ------- | -------- | ---------------------------------------------------------------------------------------- |
| `drive_id`  | string  | yes      | Drive ID from `find` file results                                                        |
| `item_id`   | string  | yes      | Item ID from `find` file results                                                         |
| `mode`      | enum    | no       | `"metadata"` (default), `"inline"`, `"binary"`, `"parsed"` — see below                   |
| `max_chars` | integer | no       | Max chars for text content in `inline` and `parsed` modes (1-50000, default from config) |

#### Modes

| Mode       | Behavior                                                                                                                                                                                 |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `metadata` | Returns file info + pre-authenticated `download_url` (valid ~1 hour). **No download.**                                                                                                   |
| `inline`   | Downloads and returns text content as UTF-8. Text MIME types only, ≤10 MB.                                                                                                               |
| `binary`   | Downloads and returns base64-encoded content. Any MIME type, ≤10 MB.                                                                                                                     |
| `parsed`   | Downloads and extracts readable text from Office/PDF files, ≤50 MB. Supports: `.pptx`, `.docx`, `.pdf`, `.xlsx`, `.odt`, `.odp`, `.ods`, `.rtf`. Returns plain text + document metadata. |

**Default is `metadata`** — always prefer this mode and let the client fetch via
`download_url` to avoid buffering large files through the gateway.

**Example** — get download URL (metadata mode, default):

```json
{
  "name": "get_file_content",
  "arguments": { "drive_id": "b!abc...", "item_id": "01XYZ..." }
}
```

**Response** (metadata):

```json
{
  "name": "Budget_Q4_2026.xlsx",
  "mime_type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "size_bytes": 45321,
  "download_url": "https://contoso.sharepoint.com/_layouts/15/download.aspx?UniqueId=...",
  "web_url": "https://contoso.sharepoint.com/sites/Finance/Shared Documents/Budget_Q4_2026.xlsx"
}
```

**Example** — read text file inline:

```json
{
  "name": "get_file_content",
  "arguments": { "drive_id": "b!abc...", "item_id": "01XYZ...", "mode": "inline", "max_chars": 10000 }
}
```

**Response** (inline):

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

**Example** — download binary file:

```json
{
  "name": "get_file_content",
  "arguments": { "drive_id": "b!abc...", "item_id": "01XYZ...", "mode": "binary" }
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

**Example** — extract text from a PowerPoint presentation:

```json
{
  "name": "get_file_content",
  "arguments": { "drive_id": "b!abc...", "item_id": "01XYZ...", "mode": "parsed", "max_chars": 30000 }
}
```

**Response** (parsed):

```json
{
  "name": "Q4_Review.pptx",
  "document_type": "pptx",
  "size_bytes": 2457600,
  "content": "Slide 1: Q4 Business Review\n\nKey Highlights\n- Revenue up 15% YoY\n- 3 new product launches...",
  "truncated": false,
  "char_count": 8450,
  "metadata": {
    "title": "Q4 Business Review",
    "creator": "Jane Doe",
    "slides": 24
  }
}
```

**Error** — unsupported file type in parsed mode:

```json
{
  "isError": true,
  "content": [
    {
      "type": "text",
      "text": "UNSUPPORTED_FILE_TYPE: File 'image.png' cannot be parsed. Supported: .pptx, .docx, .pdf, .xlsx, .odt, .odp, .ods, .rtf"
    }
  ],
  "structuredContent": {
    "name": "image.png",
    "mime_type": "image/png",
    "download_url": "https://contoso.sharepoint.com/_layouts/15/download.aspx?UniqueId=...",
    "web_url": "https://contoso.sharepoint.com/sites/..."
  }
}
```

**Error** — file too large (inline or binary mode, >10 MB):

```json
{
  "isError": true,
  "content": [
    { "type": "text", "text": "FILE_TOO_LARGE: File 'database.bak' is 52428800 bytes (limit: 10485760). Use the download_url instead." }
  ],
  "structuredContent": {
    "name": "database.bak",
    "size_bytes": 52428800,
    "limit_bytes": 10485760,
    "download_url": "https://contoso.sharepoint.com/_layouts/15/download.aspx?UniqueId=...",
    "web_url": "https://contoso.sharepoint.com/sites/..."
  }
}
```

**Error** — non-text MIME in inline mode:

```json
{
  "isError": true,
  "content": [
    {
      "type": "text",
      "text": "FILE_TOO_LARGE: File 'report.pdf' has non-text MIME type 'application/pdf'. Use binary mode or the download_url."
    }
  ],
  "structuredContent": {
    "name": "report.pdf",
    "mime_type": "application/pdf",
    "size_bytes": 1048576,
    "download_url": "https://contoso.sharepoint.com/_layouts/15/download.aspx?UniqueId=...",
    "web_url": "https://contoso.sharepoint.com/sites/..."
  }
}
```

> **Note**: Files over 10 MB are never buffered in-memory in inline/binary
> modes. The `parsed` mode allows up to 50 MB for Office/PDF files since
> text extraction is much smaller than the raw file. The `metadata` mode
> works for files of any size since it only fetches Graph metadata. The
> `download_url` is a pre-authenticated SharePoint URL valid for approximately
> 1 hour — clients can fetch it directly without going through the gateway.

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
| `start`            | string   | no*      | Explicit start (ISO 8601 with offset, e.g. `"2026-02-23T09:00:00-05:00"`)                                              |
| `end`              | string   | no*      | Explicit end (ISO 8601 with offset)                                                                                    |
| `preferred_start`  | string   | no*      | Window start for auto free-slot finding                                                                                |
| `preferred_end`    | string   | no*      | Window end for auto free-slot finding                                                                                  |
| `duration_minutes` | integer  | no       | Meeting duration (1-480, default 60). Used with preferred window.                                                      |
| `timezone`         | string   | no       | IANA timezone (e.g. `"America/New_York"`). Default: configured timezone (see [Timezone Handling](#timezone-handling)). |
| `agenda`           | string   | no       | Meeting agenda text                                                                                                    |
| `teams_meeting`    | boolean  | no       | `true` to create a Teams meeting with join link                                                                        |
| `body_html`        | string   | no       | Custom HTML body (overrides agenda)                                                                                    |
| `confirm`          | boolean  | no       | `true` to create. Without it, returns a preview.                                                                       |

*Provide either `start` + `end` OR `preferred_start` + `preferred_end`.

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

### 12. `list_chats`

List Teams chats for the current user. Returns oneOnOne, group, and meeting
chats. Meeting chats include `joinWebUrl` for transcript workflows.

| Parameter        | Type    | Required | Description                                                                |
| ---------------- | ------- | -------- | -------------------------------------------------------------------------- |
| `top`            | integer | no       | Max results (1-50, default 10)                                             |
| `chat_type`      | enum    | no       | Filter: `"oneOnOne"`, `"group"`, `"meeting"`                               |
| `expand_members` | boolean | no       | `true` to include member list                                              |
| `include_full`   | boolean | no       | `true` for expanded fields (tenant, web URL, online meeting info, members) |

**Required scopes**: `Chat.Read` (delegated)

**Example** — list meeting chats:

```json
{
  "name": "list_chats",
  "arguments": { "chat_type": "meeting", "top": 20 }
}
```

**Response** (minimal):

```json
{
  "count": 2,
  "chats": [
    {
      "id": "19:meeting_abc@thread.v2",
      "topic": "Sprint Review",
      "chat_type": "meeting",
      "created_at": "2026-01-15T09:00:00Z",
      "last_updated_at": "2026-01-15T10:30:00Z",
      "join_web_url": "https://teams.microsoft.com/l/meetup-join/abc",
      "last_message_preview": "Thanks everyone",
      "last_message_at": "2026-01-15T10:25:00Z"
    },
    {
      "id": "19:meeting_xyz@thread.v2",
      "topic": "1:1 with Manager",
      "chat_type": "meeting",
      "created_at": "2026-01-14T14:00:00Z",
      "last_updated_at": "2026-01-14T15:00:00Z",
      "join_web_url": "https://teams.microsoft.com/l/meetup-join/xyz"
    }
  ]
}
```

---

### 13. `get_chat`

Get a specific Teams chat by ID. Returns full chat details including members.
For meeting chats, includes `onlineMeetingInfo` with `joinWebUrl` needed for
`resolve_meeting`.

| Parameter      | Type    | Required | Description                                                         |
| -------------- | ------- | -------- | ------------------------------------------------------------------- |
| `chat_id`      | string  | yes      | Chat ID                                                             |
| `include_full` | boolean | no       | `true` for expanded fields (tenant, web URL, meeting info, members) |

**Required scopes**: `Chat.Read` (delegated)

**Example**:

```json
{ "name": "get_chat", "arguments": { "chat_id": "19:meeting_abc@thread.v2", "include_full": true } }
```

**Response** (full):

```json
{
  "id": "19:meeting_abc@thread.v2",
  "topic": "Sprint Review",
  "chat_type": "meeting",
  "created_at": "2026-01-15T09:00:00Z",
  "last_updated_at": "2026-01-15T10:30:00Z",
  "join_web_url": "https://teams.microsoft.com/l/meetup-join/abc",
  "tenant_id": "92e3f433-...",
  "web_url": "https://teams.microsoft.com/l/chat/...",
  "online_meeting_info": {
    "joinWebUrl": "https://teams.microsoft.com/l/meetup-join/abc",
    "calendarEventId": "AAMk..."
  },
  "members": [
    { "displayName": "Jane Doe", "userId": "user-uuid-1" },
    { "displayName": "Bob Smith", "userId": "user-uuid-2" }
  ]
}
```

---

### 14. `list_chat_messages`

List messages in a Teams chat. Returns messages with sender, timestamp, and body
text. HTML bodies are stripped to plain text and truncated.

| Parameter      | Type    | Required | Description                                                   |
| -------------- | ------- | -------- | ------------------------------------------------------------- |
| `chat_id`      | string  | yes      | Chat ID                                                       |
| `top`          | integer | no       | Max results (1-50, default 10)                                |
| `include_full` | boolean | no       | `true` for expanded fields (importance, web URL, attachments) |

**Required scopes**: `Chat.Read` (delegated)

**Example**:

```json
{ "name": "list_chat_messages", "arguments": { "chat_id": "19:meeting_abc@thread.v2", "top": 20 } }
```

**Response** (minimal):

```json
{
  "count": 3,
  "messages": [
    {
      "id": "1234567890",
      "message_type": "message",
      "from_name": "Jane Doe",
      "from_id": "user-uuid-1",
      "created_at": "2026-01-15T09:05:00Z",
      "body_text": "Let's start with the backlog review.",
      "body_truncated": false
    },
    {
      "id": "1234567891",
      "message_type": "message",
      "from_name": "Bob Smith",
      "from_id": "user-uuid-2",
      "created_at": "2026-01-15T09:10:00Z",
      "body_text": "I've updated the sprint board.",
      "body_truncated": false
    }
  ]
}
```

---

### 15. `get_chat_message`

Get a specific message from a Teams chat by chat ID and message ID.

| Parameter      | Type    | Required | Description                                                   |
| -------------- | ------- | -------- | ------------------------------------------------------------- |
| `chat_id`      | string  | yes      | Chat ID                                                       |
| `message_id`   | string  | yes      | Message ID                                                    |
| `include_full` | boolean | no       | `true` for expanded fields (importance, web URL, attachments) |

**Required scopes**: `Chat.Read` (delegated)

**Example**:

```json
{ "name": "get_chat_message", "arguments": { "chat_id": "19:abc@thread.v2", "message_id": "1234567890" } }
```

**Response** (minimal):

```json
{
  "id": "1234567890",
  "message_type": "message",
  "from_name": "Jane Doe",
  "from_id": "user-uuid-1",
  "created_at": "2026-01-15T09:05:00Z",
  "body_text": "Let's start with the backlog review.",
  "body_truncated": false
}
```

---

### 16. `send_chat_message`

Send a message to an existing Teams chat. Write operation — requires
`confirm=true`. Cannot create new chats.

| Parameter | Type           | Required | Description                                    |
| --------- | -------------- | -------- | ---------------------------------------------- |
| `chat_id` | string         | yes      | Chat ID (existing chat only)                   |
| `content` | string         | yes      | Message content (plain text)                   |
| `confirm` | literal `true` | no       | `true` to send. Without it, returns a preview. |

**Required scopes**: `ChatMessage.Send` (delegated)

**Example** — preview:

```json
{ "name": "send_chat_message", "arguments": { "chat_id": "19:abc@thread.v2", "content": "Meeting notes attached." } }
```

**Response** (preview):

```json
{
  "requires_confirmation": true,
  "action": "send_chat_message",
  "preview": {
    "chat_id": "19:abc@thread.v2",
    "content_preview": "Meeting notes attached.",
    "content_length": 24
  }
}
```

**Example** — send:

```json
{
  "name": "send_chat_message",
  "arguments": { "chat_id": "19:abc@thread.v2", "content": "Meeting notes attached.", "confirm": true }
}
```

**Response** (sent):

```json
{
  "success": true,
  "message_id": "1234567892",
  "chat_id": "19:abc@thread.v2"
}
```

---

### 17. `resolve_meeting`

Resolve a Teams meeting `joinWebUrl` to a meeting ID. Best-effort — may fail if
the meeting was not created with a calendar association or has expired. Use the
`joinWebUrl` from `get_chat` on a meeting chat (`chatType=meeting`).

| Parameter      | Type   | Required | Description                                  |
| -------------- | ------ | -------- | -------------------------------------------- |
| `join_web_url` | string | yes      | Teams meeting join URL (must be a valid URL) |

**Required scopes**: `OnlineMeetings.Read` (delegated)

**Example**:

```json
{ "name": "resolve_meeting", "arguments": { "join_web_url": "https://teams.microsoft.com/l/meetup-join/abc" } }
```

**Response** (success):

```json
{
  "meeting_id": "MSoxOjFfYWJj...",
  "subject": "Sprint Review",
  "start_at": "2026-01-15T09:00:00Z",
  "end_at": "2026-01-15T10:00:00Z",
  "join_web_url": "https://teams.microsoft.com/l/meetup-join/abc",
  "chat_info": { "threadId": "19:meeting_abc@thread.v2" }
}
```

**Response** (not found):

```json
{
  "isError": true,
  "structuredContent": {
    "error_code": "MEETING_NOT_RESOLVABLE",
    "message": "No meeting found for the provided joinWebUrl. The meeting may have expired or was created without calendar association.",
    "join_web_url": "https://teams.microsoft.com/l/meetup-join/expired"
  }
}
```

---

### 18. `list_meeting_transcripts`

List transcripts for a Teams meeting. Returns transcript metadata (not content).
If transcription was not enabled or the meeting expired, returns
`available=false` with a reason instead of throwing an error.

| Parameter    | Type   | Required | Description                                |
| ------------ | ------ | -------- | ------------------------------------------ |
| `meeting_id` | string | yes      | Meeting ID (from `resolve_meeting` result) |

**Required scopes**: `OnlineMeetingTranscript.Read.All` (delegated)

**Example**:

```json
{ "name": "list_meeting_transcripts", "arguments": { "meeting_id": "MSoxOjFfYWJj..." } }
```

**Response** (available):

```json
{
  "available": true,
  "count": 1,
  "meeting_id": "MSoxOjFfYWJj...",
  "transcripts": [
    {
      "id": "MSMjMCMj...",
      "meeting_id": "MSoxOjFfYWJj...",
      "created_at": "2026-01-15T10:00:00Z",
      "end_at": "2026-01-15T10:30:00Z",
      "content_correlation_id": "corr-123",
      "organizer_name": "Jane Doe",
      "organizer_id": "user-uuid-1"
    }
  ]
}
```

**Response** (not available):

```json
{
  "available": false,
  "reason": "transcription_not_enabled",
  "meeting_id": "MSoxOjFfYWJj..."
}
```

Possible `reason` values:

| Reason                      | Meaning                                          |
| --------------------------- | ------------------------------------------------ |
| `transcription_not_enabled` | Meeting did not have transcription turned on     |
| `no_permission`             | User lacks permission to access this transcript  |
| `meeting_expired`           | Meeting data has been purged (retention expired) |

---

### 19. `get_meeting_transcript`

Get metadata for a specific meeting transcript. Returns transcript details
without content. Use `get_transcript_content` to retrieve the actual WebVTT.

| Parameter       | Type   | Required | Description   |
| --------------- | ------ | -------- | ------------- |
| `meeting_id`    | string | yes      | Meeting ID    |
| `transcript_id` | string | yes      | Transcript ID |

**Required scopes**: `OnlineMeetingTranscript.Read.All` (delegated)

**Example**:

```json
{ "name": "get_meeting_transcript", "arguments": { "meeting_id": "MSoxOjFfYWJj...", "transcript_id": "MSMjMCMj..." } }
```

**Response**:

```json
{
  "id": "MSMjMCMj...",
  "meeting_id": "MSoxOjFfYWJj...",
  "created_at": "2026-01-15T10:00:00Z",
  "end_at": "2026-01-15T10:30:00Z",
  "content_correlation_id": "corr-123",
  "organizer_name": "Jane Doe",
  "organizer_id": "user-uuid-1"
}
```

---

### 20. `get_transcript_content`

Get the WebVTT content of a meeting transcript. Returns plain text with
timestamps and speaker tags (`<v Speaker>`). If the transcript is not available,
returns `available=false` with a reason instead of throwing.

| Parameter       | Type    | Required | Description                                          |
| --------------- | ------- | -------- | ---------------------------------------------------- |
| `meeting_id`    | string  | yes      | Meeting ID                                           |
| `transcript_id` | string  | yes      | Transcript ID                                        |
| `max_chars`     | integer | no       | Max chars for content (1-50000, default from config) |

**Required scopes**: `OnlineMeetingTranscript.Read.All` (delegated)

**Example**:

```json
{ "name": "get_transcript_content", "arguments": { "meeting_id": "MSoxOjFfYWJj...", "transcript_id": "MSMjMCMj..." } }
```

**Response** (available):

```json
{
  "available": true,
  "meeting_id": "MSoxOjFfYWJj...",
  "transcript_id": "MSMjMCMj...",
  "format": "text/vtt",
  "content": "WEBVTT\n\n00:00:00.000 --> 00:00:05.000\n<v Jane Doe>Welcome everyone to the sprint review.\n\n00:00:05.500 --> 00:00:12.000\n<v Bob Smith>Thanks Jane. Let me share the demo.",
  "truncated": false,
  "content_length": 198
}
```

**Response** (not available):

```json
{
  "available": false,
  "reason": "no_permission",
  "meeting_id": "MSoxOjFfYWJj...",
  "transcript_id": "MSMjMCMj..."
}
```

---

### 21. `retrieve_context`

Semantic search across Microsoft 365 content using the Copilot Retrieval API.
Returns relevant text extracts with relevance scores from SharePoint, OneDrive
for Business, or external items. Use for grounding — finding contextually
relevant content across the user's M365 tenant.

| Parameter               | Type   | Required | Description                                                                        |
| ----------------------- | ------ | -------- | ---------------------------------------------------------------------------------- |
| `query`                 | string | yes      | Natural language query (max 1500 chars, single sentence)                           |
| `data_source`           | enum   | no       | `"sharePoint"` (default), `"oneDriveBusiness"`, `"externalItem"`. One per request. |
| `max_results`           | int    | no       | Max results (1-25, default 10)                                                     |
| `filter_expression`     | string | no       | Raw KQL filter expression. Overrides structured `filter_*` params.                 |
| `filter_author`         | string | no       | Filter by author name                                                              |
| `filter_file_extension` | string | no       | Filter by file extension (e.g. `"docx"`, `"pdf"`)                                  |
| `filter_filename`       | string | no       | Filter by filename (partial match)                                                 |
| `filter_path`           | string | no       | Filter by SharePoint/OneDrive path                                                 |
| `filter_site_id`        | string | no       | Filter by SharePoint Site ID                                                       |
| `filter_title`          | string | no       | Filter by document title                                                           |
| `filter_modified_after` | string | no       | Filter to files modified after this ISO date                                       |
| `filter_join`           | enum   | no       | Join structured filters: `"AND"` (default) or `"OR"`                               |

**Supported KQL fields**: `Author`, `FileExtension`, `Filename`, `FileType`,
`InformationProtectionLabelId`, `LastModifiedTime`, `ModifiedBy`, `Path`,
`SiteID`, `Title`.

**Rate limit**: 200 requests per user per hour.

**Required scopes**: `Files.Read.All` + `Sites.Read.All` (delegated)

**Example** — basic semantic search:

```json
{
  "name": "retrieve_context",
  "arguments": {
    "query": "Q4 revenue projections and forecast assumptions",
    "data_source": "sharePoint",
    "max_results": 10
  }
}
```

**Example** — with structured filters:

```json
{
  "name": "retrieve_context",
  "arguments": {
    "query": "project timeline and milestones",
    "filter_author": "Jane Doe",
    "filter_file_extension": "pptx",
    "filter_modified_after": "2026-01-01T00:00:00Z"
  }
}
```

**Example** — with raw KQL filter:

```json
{
  "name": "retrieve_context",
  "arguments": {
    "query": "security compliance checklist",
    "filter_expression": "Author:\"Jane Doe\" AND FileExtension:docx AND Path:\"https://contoso.sharepoint.com/sites/Compliance\""
  }
}
```

**Response**:

```json
{
  "query": "Q4 revenue projections and forecast assumptions",
  "data_source": "sharePoint",
  "hit_count": 3,
  "max_results": 10,
  "hits": [
    {
      "web_url": "https://contoso.sharepoint.com/sites/Finance/Q4_Forecast.xlsx",
      "resource_type": "driveItem",
      "sensitivity_label": null,
      "extracts": [
        {
          "text": "Q4 revenue is projected at $12.5M based on current pipeline and seasonal trends...",
          "relevance_score": 0.92
        }
      ],
      "resource_metadata": {
        "title": "Q4 Revenue Forecast",
        "lastModifiedDateTime": "2026-03-15T14:30:00Z"
      }
    }
  ]
}
```

> **Note**: Results are unordered — optimized for context recall, not ranked
> search. Extracts include `relevance_score` but results may arrive in any
> order. If `filter_expression` has invalid KQL syntax, the Retrieval API
> silently ignores it and executes unscoped. The gateway validates balanced
> quotes/parentheses client-side to catch common mistakes.

---

### 22. `retrieve_context_multi`

Batched semantic search — send up to 20 queries in a single Graph `$batch`
call. All queries share the same `data_source` and optional filter. Returns an
array of results, one per query. Use when you need to ground an agent on
multiple topics simultaneously.

| Parameter               | Type     | Required | Description                                                      |
| ----------------------- | -------- | -------- | ---------------------------------------------------------------- |
| `queries`               | string[] | yes      | Array of natural language queries (1-20, each max 1500 chars)    |
| `data_source`           | enum     | no       | `"sharePoint"` (default), `"oneDriveBusiness"`, `"externalItem"` |
| `max_results`           | int      | no       | Max results per query (1-25, default 10)                         |
| `filter_expression`     | string   | no       | Raw KQL filter expression. Shared across all queries.            |
| `filter_author`         | string   | no       | Filter by author name                                            |
| `filter_file_extension` | string   | no       | Filter by file extension                                         |
| `filter_filename`       | string   | no       | Filter by filename                                               |
| `filter_path`           | string   | no       | Filter by SharePoint/OneDrive path                               |
| `filter_site_id`        | string   | no       | Filter by SharePoint Site ID                                     |
| `filter_title`          | string   | no       | Filter by document title                                         |
| `filter_modified_after` | string   | no       | Filter to files modified after this ISO date                     |
| `filter_join`           | enum     | no       | Join structured filters: `"AND"` (default) or `"OR"`             |

**Rate limit**: Each query in the batch counts toward the 200 requests/user/hour limit.

**Required scopes**: `Files.Read.All` + `Sites.Read.All` (delegated)

**Example** — meeting preparation batch:

```json
{
  "name": "retrieve_context_multi",
  "arguments": {
    "queries": ["Q4 revenue projections", "product roadmap updates", "customer feedback summary"],
    "data_source": "sharePoint",
    "max_results": 5
  }
}
```

**Response**:

```json
{
  "query_count": 3,
  "total_hits": 8,
  "data_source": "sharePoint",
  "max_results": 5,
  "results": [
    {
      "query": "Q4 revenue projections",
      "data_source": "sharePoint",
      "hit_count": 3,
      "hits": [
        {
          "web_url": "https://contoso.sharepoint.com/sites/Finance/Q4_Forecast.xlsx",
          "resource_type": "driveItem",
          "sensitivity_label": null,
          "extracts": [{ "text": "Revenue target: $12.5M...", "relevance_score": 0.91 }],
          "resource_metadata": {}
        }
      ]
    },
    {
      "query": "product roadmap updates",
      "data_source": "sharePoint",
      "hit_count": 3,
      "hits": []
    },
    {
      "query": "customer feedback summary",
      "data_source": "sharePoint",
      "hit_count": 2,
      "hits": []
    }
  ]
}
```

---

## Required OAuth Scopes (Delegated)

All scopes are **delegated user auth** — not application-only.

| Scope                              | Tools                                                                                                 |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `Mail.Read`                        | `find` (mail), `get_email`, `get_email_thread`                                                        |
| `Mail.ReadWrite`                   | `compose_email` (draft)                                                                               |
| `Mail.Send`                        | `compose_email` (send, reply, reply_all)                                                              |
| `Calendars.Read`                   | `find` (events), `get_event`                                                                          |
| `Calendars.Read.Shared`            | `find` (events from shared calendars)                                                                 |
| `Calendars.ReadWrite`              | `schedule_meeting`, `respond_to_meeting`                                                              |
| `User.Read`                        | `auth` (whoami, status)                                                                               |
| `Files.Read.All`                   | `find` (files), `get_file_metadata`, `get_file_content`, `retrieve_context`, `retrieve_context_multi` |
| `Sites.Read.All`                   | `find` (files on SharePoint), `retrieve_context`, `retrieve_context_multi`                            |
| `Chat.Read`                        | `list_chats`, `get_chat`, `list_chat_messages`, `get_chat_message`                                    |
| `ChatMessage.Send`                 | `send_chat_message`                                                                                   |
| `OnlineMeetings.Read`              | `resolve_meeting`                                                                                     |
| `OnlineMeetingTranscript.Read.All` | `list_meeting_transcripts`, `get_meeting_transcript`, `get_transcript_content`                        |

---

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
2. Get download URL: `get_file_content` with `drive_id` and `item_id` (defaults to `metadata` mode)
3. If the client can fetch URLs directly, use the `download_url` from step 2
4. Otherwise, re-call with `mode: "inline"` (text) or `mode: "binary"` (non-text, ≤10 MB)

```json
{
  "name": "get_file_content",
  "arguments": { "drive_id": "b!abc...", "item_id": "01XYZ..." }
}
```

To read text content inline:

```json
{
  "name": "get_file_content",
  "arguments": { "drive_id": "b!abc...", "item_id": "01XYZ...", "mode": "inline", "max_chars": 20000 }
}
```

To extract text from an Office document or PDF:

```json
{
  "name": "get_file_content",
  "arguments": { "drive_id": "b!abc...", "item_id": "01XYZ...", "mode": "parsed", "max_chars": 30000 }
}
```

> **Tip**: Use `parsed` mode for `.pptx`, `.docx`, `.pdf`, `.xlsx`, `.odt`,
> `.odp`, `.ods`, `.rtf` files. It extracts readable text + document metadata
> (title, author, page/slide count). Use `inline` for plain text files (`.md`,
> `.txt`, `.json`, `.csv`). Use `metadata` when you just need the download URL.

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

### "Get the transcript from my last meeting"

This is a multi-step workflow because there is no direct "list my meeting
transcripts" endpoint. Discovery goes through chat → meeting → transcripts.

1. List meeting chats: `list_chats` with `chat_type: "meeting"`
2. Get chat details: `get_chat` with the chat ID (to get `joinWebUrl`)
3. Resolve meeting: `resolve_meeting` with the `join_web_url`
4. List transcripts: `list_meeting_transcripts` with the `meeting_id`
5. Get content: `get_transcript_content` with `meeting_id` and `transcript_id`

```json
{ "name": "list_chats", "arguments": { "chat_type": "meeting", "top": 5 } }
```

```json
{ "name": "get_chat", "arguments": { "chat_id": "19:meeting_abc@thread.v2", "include_full": true } }
```

```json
{ "name": "resolve_meeting", "arguments": { "join_web_url": "https://teams.microsoft.com/l/meetup-join/abc" } }
```

```json
{ "name": "list_meeting_transcripts", "arguments": { "meeting_id": "MSoxOjFfYWJj..." } }
```

```json
{ "name": "get_transcript_content", "arguments": { "meeting_id": "MSoxOjFfYWJj...", "transcript_id": "MSMjMCMj..." } }
```

> **Note**: `resolve_meeting` is best-effort. If it returns
> `MEETING_NOT_RESOLVABLE`, the meeting may have expired or was created without
> a calendar association. The agent should inform the user rather than retrying.

> **Note**: `list_meeting_transcripts` and `get_transcript_content` return
> `available: false` with a `reason` rather than throwing errors when
> transcripts are unavailable. The agent should handle this gracefully.

### "What was discussed in the Teams chat?"

1. List chats: `list_chats` (optionally filter by `chat_type`)
2. List messages: `list_chat_messages` with the chat ID
3. Optionally get specific message: `get_chat_message` for details

```json
{ "name": "list_chat_messages", "arguments": { "chat_id": "19:abc@thread.v2", "top": 30, "include_full": true } }
```

### "Send a message to the project chat"

1. List chats: `list_chats` to find the right chat
2. Send message: `send_chat_message` with `confirm: true`

```json
{ "name": "send_chat_message", "arguments": { "chat_id": "19:abc@thread.v2", "content": "Updated the design doc.", "confirm": true } }
```

### "Find relevant context about a topic across SharePoint"

Use `retrieve_context` for semantic grounding — it returns relevant text
extracts from across the user's M365 content, ranked by relevance.

```json
{
  "name": "retrieve_context",
  "arguments": {
    "query": "What is our approach to data privacy compliance?",
    "data_source": "sharePoint",
    "max_results": 10
  }
}
```

To search with filters (e.g. only recent PowerPoint files by a specific author):

```json
{
  "name": "retrieve_context",
  "arguments": {
    "query": "Q4 strategy and priorities",
    "filter_author": "Jane Doe",
    "filter_file_extension": "pptx",
    "filter_modified_after": "2026-01-01T00:00:00Z"
  }
}
```

### "Ground me on multiple topics for a meeting"

Use `retrieve_context_multi` to search for multiple topics in a single batch
call. All queries share the same data source and optional filter.

```json
{
  "name": "retrieve_context_multi",
  "arguments": {
    "queries": ["Q4 revenue forecast and targets", "product launch timeline", "customer satisfaction metrics"],
    "data_source": "sharePoint",
    "max_results": 5
  }
}
```

> **Note**: `retrieve_context` and `retrieve_context_multi` use the Copilot
> Retrieval API, which is different from `find`. `find` returns structured
> search hits (mail, files, events) from the Graph Search API. `retrieve_context`
> returns semantic text extracts optimized for LLM grounding — short passages
> with relevance scores, ideal for providing context to an agent.

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

| Tool                       | Cache Key                                      | TTL  |
| -------------------------- | ---------------------------------------------- | ---- |
| `get_email`                | `email:{message_id}`                           | 30 s |
| `get_event`                | `event:{event_id}`                             | 30 s |
| `get_email_thread`         | `thread:{conversationId}:{include_full}:{top}` | 30 s |
| `get_file_metadata`        | `file:{drive_id}:{item_id}`                    | 30 s |
| `list_chats`               | `chats:{chatType}:{expandMembers}:{top}`       | 30 s |
| `get_chat`                 | `chat:{chatId}`                                | 30 s |
| `list_chat_messages`       | `chatmsgs:{chatId}:{top}`                      | 30 s |
| `get_chat_message`         | `chatmsg:{chatId}:{messageId}`                 | 30 s |
| `resolve_meeting`          | `meeting:{joinWebUrl}`                         | 30 s |
| `list_meeting_transcripts` | `transcripts:{meetingId}`                      | 30 s |
| `get_meeting_transcript`   | `transcript:{meetingId}:{transcriptId}`        | 30 s |

- `find` results and `get_file_content` calls (all modes) are **not** cached.
- `retrieve_context` and `retrieve_context_multi` are **not** cached (results depend on semantic relevance).
- `get_transcript_content` is **not** cached (content may be large).
- Write operations (`compose_email`, `schedule_meeting`, `respond_to_meeting`,
  `send_chat_message`) are never cached.
- Maximum 500 cache entries; oldest evicted when full.
