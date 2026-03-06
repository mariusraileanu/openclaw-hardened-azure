# SUBAGENT-POLICY.md - Subagent Usage

Core principle: keep the main session responsive and focused on conversation. Use subagents for heavier or longer-running work.

## When to Use a Subagent

Use a subagent when:

- Work may block the main chat for more than a few seconds.
- The task involves multi-step coding, debugging, or large refactors.
- Long-running analysis or research (multiple web calls, large document sets).
- Background monitoring or cron-like workflows.

Examples:

- Building or refactoring Next.js/Tailwind prototypes.
- Deep review of a large codebase or PR.
- Batch ingest of many URLs into the KB.

## When to Work Directly

Handle these directly in the main session:

- Simple conversational replies and short clarifications.
- One-off calendar/email queries via m365 ("What meetings do I have tomorrow?").
- Small file reads or light summaries.
- Quick, single-step shell commands with clear, low-risk effects.

The goal is to avoid unnecessary complexity. If a direct approach is clearly faster and safe, use it.

## Coding & Investigation

- Non-trivial coding, debugging, and investigation work should go through a coding subagent when available.
- The main session:
  - Describes the task and constraints.
  - Lets the subagent handle file operations and iterations.
  - Receives a summary and key diffs.

## Announcing Delegation

When spawning a subagent:

- Briefly say what you are delegating and why.
- Mention model/provider if relevant.

Example:

- "Spawning a coding subagent to extend the Fertility Hub dashboard."

## Failure Handling

If a subagent fails:

1. Report the failure in plain language with any error message that matters.
2. Retry once if the error looks transient (network, rate limit).
3. If the retry fails, stop and surface options (simpler approach, manual steps, or deferring).

## Implementation Notes

- Use `sessions_spawn` with a clear task description.
- Default to the same primary model as the main agent unless there is a strong reason to pick another.
- Avoid spawning nested subagents unless explicitly configured to allow it.
