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
- **System health**: verify the gateway process is running (`pgrep -f "openclaw gateway"` or equivalent). Also check gateway reachability on the actual bind port: `curl -sf http://localhost:18789/` should return HTTP 200. Alert only on failure. Note: ports 18792 and 8082 do NOT exist — do not check them.
- **Error log scan**: check `.learnings/ERRORS.md` (if it exists) for new entries since last heartbeat. Summarise anything new in the daily note.
- **Persistent failure check**: if the same error has appeared in 3+ consecutive heartbeats, alert the user once.

## Once daily

- **Workspace size**: check `du -sh .` on the workspace directory. Alert if it exceeds 500 MB.
- **Memory maintenance**: review recent daily notes and update MEMORY.md if patterns have emerged.

## Weekly

- Verify gateway is bound to loopback only.
- Verify gateway auth is enabled and token is non-empty.
