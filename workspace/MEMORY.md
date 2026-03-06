# MEMORY.md - Core Lessons & Preferences

Synthesized preferences and learned patterns. Only loaded in private/direct chats, never in group contexts.

## Personal Contact Info (DM-only)

- **Personal email:** <fill-when-ready>

(Keep personal contact details here instead of USER.md so they never load in group contexts.)

## User Preferences

- **Primary audience:** <e.g. Senior Leadership, Engineering Team, Cross-functional>
- **Writing style:** Executive-brief by default.
  - 3-5 bullets, one clear recommendation/ask, one key risk.
  - Plain, operator language; avoid hype and buzzwords.
- **Depth:** High-level first, offer deeper technical detail on request.
- **Tone in DMs:** Direct and calm. Friendly but not casual; no filler flattery.
- **Time:** All times in user's timezone (see USER.md) unless explicitly asked otherwise.
- **Content format:**
  - For schedule: bullet list of meetings with time, title, and 1-line purpose.
  - For briefs: short headline + bullets; avoid long paragraphs.

## Project History (Distilled)

- **m365 gateway:** Configured and authenticated; used for calendar, mail, and files.
- **Tavily search:** Enabled for live web/news queries.
- **Prototypes:**
  - <project-1 — e.g. "Performance Dashboard (Next.js) in `projects/dashboard`">
  - <project-2 — add as projects are created>
- **KB:** Local RAG knowledge base scaffolded in `kb/` with Python + SQLite.

## Content Preferences

- Avoid AI-sounding phrasing and generic praise.
- Focus on:
  - What matters.
  - Why it matters.
  - What to do next.
- For public/external narratives: emphasize the organization's strategic positioning and differentiators.

## Knowledge Base Patterns

- Use the local KB for:
  - Technical articles, strategy pieces, and external content that will be reused.
- Ingest via explicit commands; do not auto-ingest every link.

## Task Management Rules

- When updating existing items (docs, dashboards), summarize changes in one short paragraph if impactful.
- When creating new items, note location and how to access (path or URL).

## Strategic Notes

- Priorities:
  - <priority-1 — e.g. "System performance and reliability">
  - <priority-2 — e.g. "Data and AI strategy">
  - <priority-3 — e.g. "Platform infrastructure and automation">

## Security & Privacy Infrastructure

- PII redaction and data classification rules are defined in AGENTS.md and must be respected.
- Never surface sensitive internal details in group or external contexts without explicit direction.

## Operational Lessons

- Duplicate delivery prevention: if content is already posted or visible in context, avoid re-sending; focus on answering follow-ups.
- Lock files (e.g., KB ingestion): check for stale locks if ingestion hangs; remove only if the owning PID is dead.

---

*Specific daily events and work logs live in `memory/YYYY-MM-DD.md` to keep this file concise.*
