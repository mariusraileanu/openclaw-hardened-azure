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

| Code               | Meaning                           |
| ------------------ | --------------------------------- |
| `AUTH_REQUIRED`    | Not logged in — call `auth` first |
| `VALIDATION_ERROR` | Missing or invalid parameters     |
| `FORBIDDEN`        | Recipient domain not in allowlist |
| `NOT_FOUND`        | Resource not found                |
| `UPSTREAM_ERROR`   | Microsoft Graph API error         |
| `INTERNAL_ERROR`   | Unexpected server error           |

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

## Tools Reference (10 tools)

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
| `query`        | string   | yes      | Search query (min 1 char). Supports natural language AND property filters (see [Query Syntax](#query-syntax-for-find) below). |
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
- **Important**: resolve relative dates to concrete ISO 8601 using today's
  actual date in the user's timezone (Asia/Dubai). Examples (assuming today
  is Wednesday 2026-02-25):
  - "today" → `start_date: "2026-02-25T00:00:00"`, `end_date: "2026-02-26T00:00:00"`
  - "tomorrow" → `start_date: "2026-02-26T00:00:00"`, `end_date: "2026-02-27T00:00:00"`
  - "this week" → `start_date` = Monday of this week, `end_date` = following Monday
  - "next Monday" → `start_date` = next Monday 00:00, `end_date` = next Tuesday 00:00
  
  Always compute these from the real current date, not from these examples.

**Text-search mode** (no dates provided):

- Uses Graph Search API — full-text search across all events
- Good for queries like "find the Q4 planning meeting" or "meetings with John"
- Results may span all time periods; no date filtering
- Provider: `"graph-search"`

#### File search behavior

Uses Copilot Retrieval API (semantic search) with automatic fallback to Graph Search API.

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
  "timezone": "Asia/Dubai",
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
      "title": "Budget_Q4_2026.xlsx",
      "source_url": "https://contoso.sharepoint.com/...",
      "author": "Jane Doe",
      "resource_type": "driveItem",
      "snippet": "Quarterly budget allocation and variance analysis..."
    }
  ]
}
```

#### Query Syntax for `find`

The `query` parameter supports both natural language and **property filters**.
Property filters use a `property:value` syntax and are passed through to the
Microsoft Graph Search API (KQL-style).

**Property filters (mail)**:

| Filter              | Example                        | What it does                        |
| ------------------- | ------------------------------ | ----------------------------------- |
| `isRead:false`      | `"isRead:false"`               | Unread emails only                  |
| `isRead:true`       | `"isRead:true"`                | Read emails only                    |
| `from:name`         | `"from:alice"`                 | Emails from a sender (name or email)|
| `subject:keyword`   | `"subject:budget"`             | Emails with keyword in subject      |
| `hasAttachments:true`| `"hasAttachments:true"`       | Emails with attachments             |
| Combined            | `"from:john isRead:false"`     | Unread emails from John             |
| Mixed               | `"isRead:false budget report"` | Unread emails mentioning "budget report" |

**Natural language (mail/files/events)**:

| Query                              | What it does                               |
| ---------------------------------- | ------------------------------------------ |
| `"emails from John about Q4"`     | Search mail for John + Q4 context          |
| `"budget spreadsheets"`           | Search files for budget-related docs       |
| `"meetings"`                      | Search events (use with date range)        |
| `"quarterly review"`             | Search across all entity types             |

**Important**: For unread emails, you MUST use the property filter `isRead:false`.
Do NOT use natural language like `"unread emails"` — it will return no results
because "unread" is not indexed as text content.

**Combining filters with date ranges**: Property filters in `query` apply to
mail/file text search. For calendar events, use the `start_date`/`end_date`
parameters instead of date keywords in the query string.

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
  "received_at": "2026-02-20T14:30:00Z",
  "is_read": true,
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

### 5. `compose_email`

Compose an email: draft, send, reply, or reply-all. Write operations require `confirm=true`.

| Parameter         | Type               | Required            | Description                                                                   |
| ----------------- | ------------------ | ------------------- | ----------------------------------------------------------------------------- |
| `mode`            | enum               | yes                 | `"draft"`, `"send"`, `"reply"`, `"reply_all"`                                 |
| `to`              | string or string[] | for draft/send      | Recipient email(s). Comma-separated string or array.                          |
| `subject`         | string             | for draft/send      | Email subject line                                                            |
| `body_html`       | string             | yes                 | Email body (HTML). Sanitized server-side.                                     |
| `message_id`      | string             | for reply/reply_all | ID of the message to reply to                                                 |
| `attachments`     | object[]           | no                  | Inline attachments: `{ name, content_base64, content_type }`                  |
| `attachment_refs` | object[]           | no                  | M365 file references: `{ drive_id, item_id, name }`                           |
| `confirm`         | boolean            | no                  | `true` to execute send/reply. Without it, creates a draft or returns preview. |

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

---

### 6. `schedule_meeting`

Schedule a meeting. Supports explicit start/end times or automatic free-slot
finding. Supports Teams meetings and agendas. Requires `confirm=true`.

| Parameter          | Type     | Required | Description                                                                                                      |
| ------------------ | -------- | -------- | ---------------------------------------------------------------------------------------------------------------- |
| `subject`          | string   | yes      | Meeting subject                                                                                                  |
| `attendees`        | string[] | no       | Attendee email addresses                                                                                         |
| `start`            | string   | no\*     | Explicit start (ISO 8601 with offset, e.g. `"2026-02-23T09:00:00+04:00"`)                                        |
| `end`              | string   | no\*     | Explicit end (ISO 8601 with offset)                                                                              |
| `preferred_start`  | string   | no\*     | Window start for auto free-slot finding                                                                          |
| `preferred_end`    | string   | no\*     | Window end for auto free-slot finding                                                                            |
| `duration_minutes` | integer  | no       | Meeting duration (1-480, default 60). Used with preferred window.                                                |
| `timezone`         | string   | no       | IANA timezone (e.g. `"Asia/Dubai"`). Default: configured timezone (see [Timezone Handling](#timezone-handling)). |
| `agenda`           | string   | no       | Meeting agenda text                                                                                              |
| `teams_meeting`    | boolean  | no       | `true` to create a Teams meeting with join link                                                                  |
| `body_html`        | string   | no       | Custom HTML body (overrides agenda)                                                                              |
| `confirm`          | boolean  | no       | `true` to create. Without it, returns a preview.                                                                 |

\*Provide either `start` + `end` OR `preferred_start` + `preferred_end`.

**Example** — schedule with auto free-slot:

```json
{
  "name": "schedule_meeting",
  "arguments": {
    "subject": "Project Sync",
    "attendees": ["bob@contoso.com", "alice@contoso.com"],
    "preferred_start": "2026-02-23T08:00:00+04:00",
    "preferred_end": "2026-02-23T17:00:00+04:00",
    "duration_minutes": 30,
    "timezone": "Asia/Dubai",
    "teams_meeting": true,
    "agenda": "Discuss project milestones and blockers",
    "confirm": true
  }
}
```

---

### 7. `respond_to_meeting`

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

### 8. `summarize`

AI-powered summarization of a document, email thread, or any M365 entity.

| Parameter   | Type    | Required | Description                                                           |
| ----------- | ------- | -------- | --------------------------------------------------------------------- |
| `query`     | string  | no\*     | Search query to find content to summarize                             |
| `drive_id`  | string  | no\*     | OneDrive/SharePoint drive ID for direct file reference                |
| `item_id`   | string  | no\*     | File item ID (used with `drive_id`)                                   |
| `focus`     | string  | no       | Focus area for the summary (e.g. "action items", "financial figures") |
| `max_chars` | integer | no       | Max output chars (1-50000)                                            |

\*Provide either `query` OR both `drive_id` + `item_id`.

**Example** — summarize a document by search:

```json
{
  "name": "summarize",
  "arguments": {
    "query": "Q4 budget report",
    "focus": "key variances and action items"
  }
}
```

**Example** — summarize a specific file:

```json
{
  "name": "summarize",
  "arguments": {
    "drive_id": "b!abc123...",
    "item_id": "01ABC...",
    "focus": "executive summary"
  }
}
```

---

### 9. `prepare_meeting`

Gather context for an upcoming meeting: related emails, files, past meetings,
and attendee context. Returns a briefing package.

| Parameter   | Type    | Required | Description                                                         |
| ----------- | ------- | -------- | ------------------------------------------------------------------- |
| `event_id`  | string  | no\*     | Event ID to prepare for (fetches subject + attendees automatically) |
| `subject`   | string  | no\*     | Meeting subject (if you don't have the event ID)                    |
| `max_chars` | integer | no       | Max output chars (1-50000)                                          |

\*Provide either `event_id` or `subject`.

**Example**:

```json
{
  "name": "prepare_meeting",
  "arguments": { "event_id": "AAMk..." }
}
```

**Response**:

```json
{
  "provider": "copilot-retrieval",
  "meeting_subject": "Sprint Planning",
  "meeting": { "id": "AAMk...", "subject": "Sprint Planning", "start": "...", "...": "..." },
  "attendees": ["Jane Doe", "Bob Smith"],
  "briefing": "Meeting Briefing: \"Sprint Planning\"\n\nRelated Documents:\n...",
  "truncated": false,
  "citations": [{ "title": "Sprint Board", "url": "https://..." }]
}
```

---

### 10. `audit_list`

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

1. Resolve "Monday" to concrete dates using today's real date
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
    "start_date": "2026-02-23T00:00:00",
    "end_date": "2026-03-02T00:00:00"
  }
}
```

### "Show my unread emails" / "What are my top unread emails?"

Use the `isRead:false` property filter — NOT natural language.

```json
{
  "name": "find",
  "arguments": {
    "query": "isRead:false",
    "entity_types": ["mail"],
    "top": 10
  }
}
```

### "Show unread emails from Alice"

Combine property filters:

```json
{
  "name": "find",
  "arguments": {
    "query": "from:alice isRead:false",
    "entity_types": ["mail"],
    "top": 10
  }
}
```

### "Read that email in full" / "Show me the full email"

After `find` returns mail results, use `get_email` with the result's `id`:

```json
{
  "name": "get_email",
  "arguments": {
    "message_id": "AAMk...",
    "include_full": true
  }
}
```

### "Find emails from John about the budget and reply"

1. Search: `find` with `query: "emails from John about budget"`, `entity_types: ["mail"]`
2. Get details: `get_email` with the `id` from step 1, `include_full: true`
3. Reply: `compose_email` with `mode: "reply"`, `message_id`, `body_html`, `confirm: true`

### "Prepare me for my 2pm meeting"

1. Find the meeting: `find` with `entity_types: ["events"]`, `start_date`/`end_date` around 2pm
2. Prepare: `prepare_meeting` with the `event_id` from step 1

### "Schedule a 30-min Teams call with Bob tomorrow morning"

Resolve "tomorrow morning" to concrete ISO 8601 with timezone offset.

```json
{
  "name": "schedule_meeting",
  "arguments": {
    "subject": "Sync with Bob",
    "attendees": ["bob@contoso.com"],
    "preferred_start": "2026-02-22T08:00:00+04:00",
    "preferred_end": "2026-02-22T12:00:00+04:00",
    "duration_minutes": 30,
    "teams_meeting": true,
    "confirm": true
  }
}
```

---

## Timezone Handling

All calendar/event operations use a **configured default timezone** (currently
`Asia/Dubai` / UTC+4). This affects:

- **`find`** (date-range mode) — event times in results are returned in the
  configured timezone. The response includes a `timezone` field indicating which
  timezone was used.
- **`get_event`** — event start/end times are returned in the configured timezone.
- **`prepare_meeting`** — event details fetched for briefings use the configured
  timezone.
- **`schedule_meeting`** — when using auto free-slot finding, the `timezone`
  parameter defaults to the configured timezone. When providing explicit `start`
  and `end`, include the UTC offset in the ISO 8601 string (e.g.
  `"2026-02-23T09:00:00+04:00"` for Asia/Dubai).

The default timezone is set in the gateway's `config.yaml` under
`calendar.defaultTimezone` using IANA timezone names (e.g. `Asia/Dubai`,
`America/New_York`, `Europe/London`). The gateway maps IANA names to the Windows
timezone names required by the Graph API internally.

**Agent guidance**: When the user says "9am" without specifying a timezone, use
the default timezone offset. For Asia/Dubai, that means `+04:00`.

---

## Output Minimization

By default, responses include only high-signal fields (IDs, subject/title,
sender/organizer, timestamps, links, short snippets).

Pass `include_full=true` on `get_email` and `get_event` to expand:

- **Email**: full body HTML, all recipients (to, cc), conversation ID
- **Event**: full attendee list with response status, body preview, online meeting details
