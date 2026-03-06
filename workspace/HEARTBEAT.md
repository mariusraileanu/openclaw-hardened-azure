# HEARTBEAT.md

## Reporting

Heartbeat turns should usually end with NO_REPLY.

Only send a direct heartbeat message when something requires user intervention (e.g., gateway down, state file corrupted, persistent errors).

If `memory/heartbeat-state.json` is missing or corrupted, recreate it with:

```json
{"lastChecks": {"errorLog": null, "securityAudit": null, "lastDailyChecks": null}}
```

Then alert the user.

## Every heartbeat

- Update `memory/heartbeat-state.json` timestamps for checks performed.
- **System health**: verify the gateway process is running (`pgrep -f "openclaw gateway"` or equivalent). Also check internal health port: `curl -sf http://localhost:18792/` should return `OK` (HTTP 200). Alert only on failure. Note: port 8082 does NOT exist — do not check it.
- **Error log scan**: check `.learnings/ERRORS.md` (if it exists) for new entries since last heartbeat. Summarise anything new in the daily note.
- **Persistent failure check**: if the same error has appeared in 3+ consecutive heartbeats, alert the user once.

## Once daily

- **Workspace size**: check `du -sh .` on the workspace directory. Alert if it exceeds 500 MB.
- **Memory maintenance**: review recent daily notes and update MEMORY.md if patterns have emerged.

## Weekly

- Verify gateway is bound to loopback only.
- Verify gateway auth is enabled and token is non-empty.
