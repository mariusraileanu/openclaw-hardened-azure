# Tool Contract - m365-graph-mcp-gateway

This document is the canonical reference for agents consuming the MCP gateway.
Pass it as system-prompt context or reference documentation so the LLM knows
every tool name, parameter, response shape, and best-practice calling pattern.

---

## Transport

| Endpoint       | Method | Description               |
| -------------- | ------ | ------------------------- |
| `/mcp`         | POST   | MCP JSON-RPC (HTTP mode)  |
| `stdin/stdout` | -      | MCP JSON-RPC (stdio mode) |

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
| Key not set or empty | Open access - no `Authorization` header required            |
| Key set              | Requires `Authorization: Bearer <key>` on every `/mcp` call |

- `/health` and `/auth/status` are **never** gated by the API key.
- Uses **constant-time comparison** (`crypto.timingSafeEqual`) to prevent timing attacks.
- Returns HTTP **401** with `{"error": "Unauthorized: invalid or missing API key"}` on failure.

### Identity Binding

The gateway enforces **strict identity pinning** to ensure the cached Microsoft
identity matches the expected user for a given deployment. This prevents
cross-user token reuse when multiple containers share NFS-backed storage.

**`EXPECTED_AAD_OBJECT_ID` is required** - the gateway refuses to operate without
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

- `expected_object_id` - from `EXPECTED_AAD_OBJECT_ID` (null if not configured)
- `actual_object_id` - from cached account (null if no account)
- `identity_match` - boolean comparison (null if OID not configured)
- `identity_binding_status` - one of:
  - `'valid'` - OID is configured and matches the cached account
  - `'invalid'` - OID is configured but does not match (or cache corrupted)
  - `'missing'` - `EXPECTED_AAD_OBJECT_ID` is not set (gateway non-functional)

**`USER_SLUG` is required** - controls per-user storage path isolation. Without
it, the gateway refuses to resolve any storage path (token cache, audit log).
Format: lowercase alphanumeric + hyphens, 2-31 chars, starting with a letter
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

If the client sends an unsupported `protocolVersion`, the server returns a
`-32602` error with the list of supported versions.

After receiving the `initialize` response, the client should send a
`notifications/initialized` notification to complete the handshake.

### `ping`

Health check at the protocol level. Returns an empty result.

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
- Array bodies (batch requests) are rejected with `-32600` - batch mode is not supported.

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

- `content[0].text` - human-readable summary with titles, links, and snippets (same as `structuredContent.summary`)
- `structuredContent` - full structured data for programmatic use
- `isError` - only present (and `true`) on failures

### Error Responses

Errors use a `CODE: message` pattern:

| Code                         | Meaning                                                                    |
| ---------------------------- | -------------------------------------------------------------------------- |
| `AUTH_REQUIRED`              | Not logged in - call `auth` first                                          |
| `AUTH_EXPIRED`               | Token expired - re-authenticate via `auth`                                 |
| `AUTH_MISMATCH`              | Cached identity OID does not match `EXPECTED_AAD_OBJECT_ID`                |
| `CONFIG_ERROR`               | Required config missing (e.g. `EXPECTED_AAD_OBJECT_ID` not set)            |
| `TOKEN_CACHE_CORRUPTED`      | Token cache in invalid state (e.g. multiple OID matches)                   |
| `MULTIPLE_ACCOUNTS_IN_CACHE` | Token cache contains >1 account - logout and re-login                      |
| `CACHE_DECRYPTION_FAILED`    | Token cache exists but cannot be decrypted (wrong key/corrupt)             |
| `TOKEN_IDENTITY_MISMATCH`    | Cached identity does not match expected Entra object ID                    |
| `FILE_TOO_LARGE`             | File exceeds 10 MB inline limit - use `download_url` instead               |
| `VALIDATION_ERROR`           | Missing or invalid parameters                                              |
| `FORBIDDEN`                  | Recipient domain not in allowlist                                          |
| `NOT_FOUND`                  | Resource not found                                                         |
| `UPSTREAM_ERROR`             | Microsoft Graph API error                                                  |
| `INTERNAL_ERROR`             | Unexpected server error                                                    |
| `MEETING_NOT_RESOLVABLE`     | joinWebUrl filter returned 0 meetings - expired or no calendar association |
| `MISSING_JOIN_WEB_URL`       | Chat has no onlineMeetingInfo.joinWebUrl                                   |
| `TRANSCRIPT_NOT_AVAILABLE`   | Transcription not enabled, not ready, meeting expired, or no permission    |
| `UNSUPPORTED_FILE_TYPE`      | File extension not supported for parsed mode extraction                    |
| `PARSE_ERROR`                | File parsing failed (corrupt or unreadable file)                           |
| `INVALID_KQL_FIELD`          | KQL filter uses an unsupported field name                                  |
| `INVALID_KQL_FILTER`         | KQL filter_expression has invalid syntax (unbalanced quotes/parens)        |

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

| Parameter | Type | Required | Description |
| --------- | ---- | -------- | ----------- |
| `action`  | enum | yes      | `"login"`, `"login_device"`, `"logout"`, `"whoami"`, `"status"` |

### 2. `find`

Search across Microsoft 365 - mail, files, and calendar events.

| Parameter      | Type     | Required | Description |
| -------------- | -------- | -------- | ----------- |
| `query`        | string   | yes      | Search query |
| `kql`          | string   | no       | Raw KQL query override |
| `entity_types` | string[] | no       | `"mail"`, `"files"`, `"events"` |
| `start_date`   | string   | no       | ISO 8601 datetime |
| `end_date`     | string   | no       | ISO 8601 datetime |
| `top`          | integer  | no       | Max results (1-50, default 10) |
| `max_chars`    | integer  | no       | Max output chars (1-50000) |

### 3. `get_email`

Fetch a specific email by ID.

| Parameter      | Type    | Required | Description |
| -------------- | ------- | -------- | ----------- |
| `message_id`   | string  | yes      | Email ID from `find` |
| `include_full` | boolean | no       | Expanded fields |

### 4. `get_event`

Fetch a specific calendar event by ID.

| Parameter      | Type    | Required | Description |
| -------------- | ------- | -------- | ----------- |
| `event_id`     | string  | yes      | Event ID from `find` |
| `include_full` | boolean | no       | Expanded fields |

### 5. `get_email_thread`

Fetch all messages in an email conversation thread.

| Parameter         | Type    | Required         | Description |
| ----------------- | ------- | ---------------- | ----------- |
| `conversation_id` | string  | one of the two*  | Conversation ID |
| `message_id`      | string  | one of the two*  | Message ID fallback |
| `top`             | integer | no               | Max messages (1-50) |
| `include_full`    | boolean | no               | Expanded fields |

*At least one of `conversation_id` or `message_id` must be provided.

### 6. `get_file_metadata`

Get metadata for a OneDrive/SharePoint file.

| Parameter      | Type    | Required | Description |
| -------------- | ------- | -------- | ----------- |
| `drive_id`     | string  | yes      | Drive ID |
| `item_id`      | string  | yes      | Item ID |
| `include_full` | boolean | no       | Expanded fields |

### 7. `get_file_content`

Access file content from OneDrive/SharePoint.

| Parameter   | Type    | Required | Description |
| ----------- | ------- | -------- | ----------- |
| `drive_id`  | string  | yes      | Drive ID |
| `item_id`   | string  | yes      | Item ID |
| `mode`      | enum    | no       | `"metadata"` (default), `"inline"`, `"binary"`, `"parsed"` |
| `max_chars` | integer | no       | Max chars for `inline` and `parsed` modes |

### 8. `compose_email`

Compose an email: draft, send, reply, or reply-all.

| Parameter         | Type               | Required            | Description |
| ----------------- | ------------------ | ------------------- | ----------- |
| `mode`            | enum               | yes                 | `"draft"`, `"send"`, `"reply"`, `"reply_all"` |
| `to`              | string or string[] | for draft/send      | Recipient email(s) |
| `subject`         | string             | for draft/send      | Subject |
| `body_html`       | string             | yes                 | HTML body |
| `message_id`      | string             | for reply/reply_all | Message ID |
| `attachments`     | object[]           | no                  | Inline attachments |
| `attachment_refs` | object[]           | no                  | M365 file refs |
| `confirm`         | boolean            | no                  | Required for send/reply/reply_all execution |

### 9. `schedule_meeting`

Schedule a meeting with explicit time or preferred window.

| Parameter          | Type     | Required | Description |
| ------------------ | -------- | -------- | ----------- |
| `subject`          | string   | yes      | Meeting subject |
| `attendees`        | string[] | no       | Attendee emails |
| `start`            | string   | no*      | Explicit start |
| `end`              | string   | no*      | Explicit end |
| `preferred_start`  | string   | no*      | Window start |
| `preferred_end`    | string   | no*      | Window end |
| `duration_minutes` | integer  | no       | Duration |
| `timezone`         | string   | no       | IANA timezone |
| `agenda`           | string   | no       | Agenda text |
| `teams_meeting`    | boolean  | no       | Teams meeting toggle |
| `body_html`        | string   | no       | Custom body |
| `confirm`          | boolean  | no       | Required to execute |

*Provide either `start` + `end` OR `preferred_start` + `preferred_end`.

### 10. `respond_to_meeting`

Respond to a meeting invitation or cancel an organized meeting.

| Parameter   | Type    | Required | Description |
| ----------- | ------- | -------- | ----------- |
| `event_id`  | string  | yes      | Event ID |
| `action`    | enum    | yes      | `"accept"`, `"decline"`, `"tentativelyAccept"`, `"cancel"`, `"reply_all_draft"` |
| `comment`   | string  | no       | Optional comment |
| `body_html` | string  | no       | Reply-all HTML |
| `confirm`   | boolean | no       | Required for accept/decline/cancel |

### 11. `audit_list`

List recent audit log entries.

| Parameter | Type    | Required | Description |
| --------- | ------- | -------- | ----------- |
| `limit`   | integer | no       | Number of entries (1-1000, default 100) |

### 12. `list_chats`

List Teams chats for the current user.

| Parameter        | Type    | Required | Description |
| ---------------- | ------- | -------- | ----------- |
| `top`            | integer | no       | Max results (1-50, default 10) |
| `chat_type`      | enum    | no       | `"oneOnOne"`, `"group"`, `"meeting"` |
| `expand_members` | boolean | no       | Include member list |
| `include_full`   | boolean | no       | Expanded fields |

### 13. `get_chat`

Get a specific Teams chat by ID.

| Parameter      | Type    | Required | Description |
| -------------- | ------- | -------- | ----------- |
| `chat_id`      | string  | yes      | Chat ID |
| `include_full` | boolean | no       | Expanded fields |

### 14. `list_chat_messages`

List messages in a Teams chat.

| Parameter      | Type    | Required | Description |
| -------------- | ------- | -------- | ----------- |
| `chat_id`      | string  | yes      | Chat ID |
| `top`          | integer | no       | Max results (1-50, default 10) |
| `include_full` | boolean | no       | Expanded fields |

### 15. `get_chat_message`

Get a specific message from a Teams chat.

| Parameter      | Type    | Required | Description |
| -------------- | ------- | -------- | ----------- |
| `chat_id`      | string  | yes      | Chat ID |
| `message_id`   | string  | yes      | Message ID |
| `include_full` | boolean | no       | Expanded fields |

### 16. `send_chat_message`

Send a message to an existing Teams chat.

| Parameter | Type           | Required | Description |
| --------- | -------------- | -------- | ----------- |
| `chat_id` | string         | yes      | Chat ID |
| `content` | string         | yes      | Message content |
| `confirm` | literal `true` | no       | Required to execute send |

### 17. `resolve_meeting`

Resolve a Teams meeting `joinWebUrl` to a meeting ID.

| Parameter      | Type   | Required | Description |
| -------------- | ------ | -------- | ----------- |
| `join_web_url` | string | yes      | Teams meeting join URL |

### 18. `list_meeting_transcripts`

List transcripts for a Teams meeting.

| Parameter    | Type   | Required | Description |
| ------------ | ------ | -------- | ----------- |
| `meeting_id` | string | yes      | Meeting ID |

### 19. `get_meeting_transcript`

Get metadata for a specific meeting transcript.

| Parameter       | Type   | Required | Description |
| --------------- | ------ | -------- | ----------- |
| `meeting_id`    | string | yes      | Meeting ID |
| `transcript_id` | string | yes      | Transcript ID |

### 20. `get_transcript_content`

Get WebVTT content of a meeting transcript.

| Parameter       | Type    | Required | Description |
| --------------- | ------- | -------- | ----------- |
| `meeting_id`    | string  | yes      | Meeting ID |
| `transcript_id` | string  | yes      | Transcript ID |
| `max_chars`     | integer | no       | Max chars for content |

### 21. `retrieve_context`

Semantic retrieval across M365 content for grounding context.

| Parameter               | Type   | Required | Description |
| ----------------------- | ------ | -------- | ----------- |
| `query`                 | string | yes      | Natural language query (max 1500 chars) |
| `data_source`           | enum   | no       | `"sharePoint"` (default), `"oneDriveBusiness"`, `"externalItem"` |
| `max_results`           | int    | no       | Max results (1-25, default 10) |
| `filter_expression`     | string | no       | Raw KQL filter expression |
| `filter_author`         | string | no       | Filter by author |
| `filter_file_extension` | string | no       | Filter by extension |
| `filter_filename`       | string | no       | Filter by filename |
| `filter_path`           | string | no       | Filter by path |
| `filter_site_id`        | string | no       | Filter by site ID |
| `filter_title`          | string | no       | Filter by title |
| `filter_modified_after` | string | no       | ISO timestamp lower bound |
| `filter_join`           | enum   | no       | `"AND"` (default) or `"OR"` |

### 22. `retrieve_context_multi`

Batched semantic retrieval for up to 20 queries in one request.

| Parameter               | Type     | Required | Description |
| ----------------------- | -------- | -------- | ----------- |
| `queries`               | string[] | yes      | Array of queries (1-20, max 1500 chars each) |
| `data_source`           | enum     | no       | `"sharePoint"` (default), `"oneDriveBusiness"`, `"externalItem"` |
| `max_results`           | int      | no       | Max results per query (1-25, default 10) |
| `filter_expression`     | string   | no       | Raw KQL filter expression |
| `filter_author`         | string   | no       | Filter by author |
| `filter_file_extension` | string   | no       | Filter by extension |
| `filter_filename`       | string   | no       | Filter by filename |
| `filter_path`           | string   | no       | Filter by path |
| `filter_site_id`        | string   | no       | Filter by site ID |
| `filter_title`          | string   | no       | Filter by title |
| `filter_modified_after` | string   | no       | ISO timestamp lower bound |
| `filter_join`           | enum     | no       | `"AND"` (default) or `"OR"` |

---

## Required OAuth Scopes (Delegated)

All scopes are **delegated user auth** - not application-only.

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

## Timezone Handling

All calendar/event operations use a **configured default timezone** (set in
`config.yaml` under `calendar.defaultTimezone`; defaults to `UTC`).

The default timezone is set in the gateway's `config.yaml` under
`calendar.defaultTimezone` using IANA timezone names (e.g. `America/New_York`,
`Europe/London`, `Asia/Tokyo`). The gateway maps IANA names to the Windows
timezone names required by the Graph API internally. Deployments may override
this value per environment.

---

## Output Minimization

By default, responses include only high-signal fields (IDs, subject/title,
sender/organizer, timestamps, links, short snippets).

Pass `include_full=true` on `get_email`, `get_event`, `get_email_thread`, and
`get_file_metadata` to expand details.

---

## Caching

Read-only `get_*` tools use a short-lived in-memory micro-cache.

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
- `retrieve_context` and `retrieve_context_multi` are **not** cached.
- `get_transcript_content` is **not** cached (content may be large).
- Write operations are never cached.
- Maximum 500 cache entries; oldest evicted when full.
