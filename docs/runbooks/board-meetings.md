# Board Meetings

Run local multi-agent board meetings against the generated board agents.

## Prerequisites

- Local Docker stack running via `make docker-up`
- Boards enabled either through the active feature manifest or through local fallback `OPENCLAW_BOARDS`

For local fallback mode, set the board list explicitly before `make docker-up`, for example:

```bash
export OPENCLAW_BOARDS="fertility,strategic-health"
```

## Sample Fertility Meeting

Create a temporary agenda file:

```bash
cat >/tmp/fertility-agenda.json <<'JSON'
{
  "meetingId": "fertility-local-test-001",
  "boardId": "fertility",
  "agendaTopic": "National fertility pathway redesign with AI-supported triage and value-based reimbursement",
  "agendaSummary": "Evaluate whether the health system should pilot a redesigned fertility pathway that combines AI-assisted intake triage, standardized clinical protocols across providers, and value-based reimbursement tied to outcomes and patient experience.",
  "context": [
    "The proposed pilot would launch across a limited set of providers before wider scale-up.",
    "The reform aims to reduce time-to-treatment, improve patient navigation, and increase consistency of care quality.",
    "AI support would be used for intake, pathway routing, and patient communications, but not autonomous diagnosis.",
    "Payment reform would shift part of reimbursement toward outcomes, continuity, and patient experience metrics.",
    "The chairman should choose only the members most relevant to this topic."
  ],
  "decisionRequest": "Should the board recommend approval, rejection, deferment, or request_more_analysis for this pilot? If approval is recommended, specify guardrails and next actions."
}
JSON
```

Then run the board meeting:

```bash
node platform/scripts/run_board_meeting.mjs \
  --board fertility \
  --agenda /tmp/fertility-agenda.json
```

This runs a real board-meeting flow using the installed OpenClaw runtime:

- the chairman selects attendees from the board roster
- selected member agents produce independent first-pass views
- the chairman synthesizes a rebuttal summary
- selected member agents cast final votes
- the chairman issues the final decision packet

By default the runner writes generated artifacts to:

- `/tmp/openclaw-board-meetings/fertility-local-test-001.result.md`
- `/tmp/openclaw-board-meetings/fertility-local-test-001.trace.json`

You can override the output path:

```bash
node platform/scripts/run_board_meeting.mjs \
  --board fertility \
  --agenda /tmp/fertility-agenda.json \
  --output /tmp/fertility-decision-packet.md \
  --trace-output /tmp/fertility-decision-trace.json
```

For a faster local validation run, constrain the meeting size and per-call timeouts:

```bash
node platform/scripts/run_board_meeting.mjs \
  --board fertility \
  --agenda /tmp/fertility-agenda.json \
  --output /tmp/fertility-decision-packet.md \
  --trace-output /tmp/fertility-decision-trace.json \
  --packet-mode brief \
  --min-attendees 3 \
  --max-attendees 3 \
  --selection-timeout 180 \
  --member-timeout 120 \
  --chairman-timeout 180
```

## Agenda File Shape

```json
{
  "meetingId": "fertility-local-test-001",
  "boardId": "fertility",
  "agendaTopic": "...",
  "agendaSummary": "...",
  "context": ["..."],
  "decisionRequest": "..."
}
```

## Behavior

- The chairman chooses relevant attendees from the board roster.
- Only selected attendees participate in deliberation and voting.
- The runner orchestrates a first-pass round, chairman rebuttal summary, final-vote round, and final decision packet.
- The runner executes through the installed `agentCommand` runtime inside the container rather than the device-authenticated Gateway WS client path.
- Each agent call is executed in its own timed container process so one slow member does not block the whole meeting.
- The runner can emit a trace JSON with run id, selected attendee agent ids, and session keys for session-lineage verification.
- For grounded members with curated public evidence, the runner injects public-source excerpts into member prompts and records source lineage in the trace JSON.

## Control UI

Formal board-meeting requests sent to a board chairman session in Control UI now use the same deterministic board runner instead of free-form chairman simulation.

The base default workspace remains the normal user entry point. If the user asks for a formal board decision there without naming a board, the assistant should ask: `Which board?`

Use prompts that clearly ask for a formal board decision, for example:

```text
Dr Noura, convene the Fertility Advisory Board on this question:
Should we approve a national pilot for an AI-assisted fertility intake and triage pathway, with standardized clinical protocols across providers and value-based reimbursement tied to outcomes and patient experience?

Select the most relevant board members, run a formal board deliberation, and return a decision packet with:
- selected attendees
- decision outcome
- vote tally
- key risks
- dissenting views
- open questions
- next actions
```

Expected behavior:

- the chairman uses only named members from the fertility roster
- the request is routed through the board runner
- if runner execution fails, the chairman reports the real error and does not invent votes or attendee views

Informal chairman chat is still allowed for non-formal requests. The deterministic path is intended for prompts that explicitly ask to convene the board and return a decision packet.

## Current Limitations

- Local runs are resource-sensitive. The current local Docker setup was validated with `8` CPUs and `16g` memory allocated to the `openclaw` service.
- Boot-time QMD initialization across all board agents is still slow and may log timeout/backoff messages during local startup.
- The runner preserves isolated per-run state under `/tmp/openclaw-board-state-<runId>` inside the container for debugging failed or partial meetings.
- Control UI may still show old internal meeting/member sessions from prior runs; those are historical artifacts, not additional user-facing agents.

## Member Evidence Grounding

The first grounded member corpus is file-based and curated, not live-web searched.

- Member metadata lives under `config/member-evidence/<member-id>.json`
- Curated public summaries live under `kb/board-members/<member-id>/`
- Retrieval is chunk-based, so larger public summaries can yield smaller, more relevant evidence excerpts.
- Current grounded members in the active advisory-board roster:
  - `eric-topol`
  - `mark-mcclellan`
  - `antonio-pellicer`
  - `ong-ye-kung`
  - `gianrico-farrugia`
  - `cass-sunstein`
  - `jennifer-doudna`
  - `jan-de-maeseneer`
  - `tom-inglesby`
  - `vas-narasimhan`
  - `horst-schulze`
  - `huang-luqi`

The intent is public-source-grounded simulation, not a claim that the system is the real person or knows their private current views.
