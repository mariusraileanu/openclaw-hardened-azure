from __future__ import annotations

import base64
import json
import subprocess
import time
from pathlib import Path

from env_loader import load_layered_env
from naming import resolve_and_validate_naming
from runner import run, run_capture


def _build_context(
    repo_root: Path, env_name: str, user: str | None = None
) -> dict[str, str]:
    env_map, _ = load_layered_env(
        repo_root=repo_root,
        env_name=env_name,
        user=user,
        require_user_file=False,
    )
    resolved = resolve_and_validate_naming(repo_root, env_map, env_name)
    env_map.update(resolved)
    env_map["AZURE_ENVIRONMENT"] = env_name
    return env_map


def status(repo_root: Path, env_name: str, user: str | None) -> int:
    context = _build_context(repo_root, env_name, user)
    resource_group = context.get("AZURE_RESOURCE_GROUP")
    if not resource_group:
        raise RuntimeError("AZURE_RESOURCE_GROUP is required for status")

    if user:
        app_name = f"ca-openclaw-{env_name}-{user}"
        print(f"▸ Status for [{env_name}] using config/env/{env_name}.env")
        command = [
            "az",
            "containerapp",
            "show",
            "-n",
            app_name,
            "-g",
            resource_group,
            "--query",
            "{name:name, status:properties.provisioningState, revision:properties.latestRevisionName, fqdn:properties.configuration.ingress.fqdn}",
            "-o",
            "table",
        ]
        return run(command, repo_root, env=context)

    print(f"▸ Status for [{env_name}] using config/env/{env_name}.env")
    command = [
        "az",
        "containerapp",
        "list",
        "-g",
        resource_group,
        "--query",
        "[?starts_with(name,'ca-openclaw-')].{name:name, status:properties.provisioningState, revision:properties.latestRevisionName}",
        "-o",
        "table",
    ]
    return run(command, repo_root, env=context)


def logs(repo_root: Path, env_name: str, user: str) -> int:
    context = _build_context(repo_root, env_name, user)
    resource_group = context.get("AZURE_RESOURCE_GROUP")
    if not resource_group:
        raise RuntimeError("AZURE_RESOURCE_GROUP is required for logs")

    app_name = f"ca-openclaw-{env_name}-{user}"
    print(f"▸ Logs for '{user}' on [{env_name}] using config/env/{env_name}.env")
    command = [
        "az",
        "containerapp",
        "logs",
        "show",
        "--name",
        app_name,
        "--resource-group",
        resource_group,
        "--follow",
        "--tail",
        "100",
    ]
    return run(command, repo_root, env=context)


def _resolve_workspace_customer_id(
    repo_root: Path,
    context: dict[str, str],
    env_name: str,
    workspace_id: str | None,
) -> str:
    if workspace_id:
        return workspace_id

    resource_group = context.get("AZURE_RESOURCE_GROUP")
    if not resource_group:
        raise RuntimeError("AZURE_RESOURCE_GROUP is required for usage")

    workspace_name = f"law-openclaw-{env_name}"
    command = [
        "az",
        "monitor",
        "log-analytics",
        "workspace",
        "show",
        "-n",
        workspace_name,
        "-g",
        resource_group,
        "--query",
        "customerId",
        "-o",
        "tsv",
    ]

    try:
        customer_id = run_capture(command, repo_root, env=context)
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(
            "Unable to resolve Log Analytics workspace customerId. "
            "Pass --workspace-id explicitly."
        ) from exc

    if not customer_id:
        raise RuntimeError(
            "Log Analytics workspace customerId is empty. Pass --workspace-id explicitly."
        )

    return customer_id


def usage(
    repo_root: Path,
    env_name: str,
    user: str | None,
    hours: int,
    workspace_id: str | None,
) -> int:
    if hours <= 0:
        raise RuntimeError("--hours must be greater than 0")

    context = _build_context(repo_root, env_name, user)
    customer_id = _resolve_workspace_customer_id(
        repo_root, context, env_name, workspace_id
    )

    relay_name = f"func-relay-{env_name}"
    user_filter = ""
    if user:
        user_filter = f"| where userSlug == '{user}'"

    query = (
        f"let windowStart = ago({hours}h);"
        f" AzureDiagnostics"
        f" | where TimeGenerated > windowStart"
        f" | where Resource has '{relay_name}' or ResourceId has '/sites/{relay_name}'"
        f" | extend rawLog = coalesce(tostring(column_ifexists('Message', '')), tostring(column_ifexists('msg_s', '')), tostring(column_ifexists('ResultDescription', '')))"
        f" | where rawLog has 'relay_event='"
        f" | extend relayJson = extract(@'relay_event=(\\{{.*\\}})', 1, rawLog)"
        f" | where isnotempty(relayJson)"
        f" | extend evt = parse_json(relayJson)"
        f" | extend userSlug = tostring(evt.userSlug), result = tostring(evt.result), latencyMs = todouble(evt.latencyMs), upstreamStatus = tostring(evt.upstreamStatus)"
        f" | where userSlug != '' and userSlug != 'unknown'"
        f" {user_filter}"
        f" | summarize requests=count(), successes=countif(result == 'upstream_ok'), failures=countif(result in ('upstream_failure','upstream_5xx','store_error','circuit_open')), p95_latency_ms=percentile(latencyMs, 95) by userSlug"
        f" | extend success_rate_pct = round((todouble(successes) / requests) * 100.0, 2)"
        f" | order by requests desc"
    )

    target = f"all users (last {hours}h)" if not user else f"'{user}' (last {hours}h)"
    print(f"▸ Request-level usage for {target} on [{env_name}]")

    command = [
        "az",
        "monitor",
        "log-analytics",
        "query",
        "--workspace",
        customer_id,
        "--analytics-query",
        query,
        "-o",
        "table",
    ]
    return run(command, repo_root, env=context)


def _run_capture_retry(
    command: list[str],
    repo_root: Path,
    context: dict[str, str],
    *,
    retries: int = 12,
    base_delay_seconds: int = 5,
) -> str:
    for attempt in range(1, retries + 1):
        try:
            return run_capture(command, repo_root, env=context)
        except subprocess.CalledProcessError as exc:
            if attempt >= retries:
                raise
            time.sleep(base_delay_seconds * attempt)

    raise RuntimeError("exhausted retry attempts")


def _resolve_probe_app(
    repo_root: Path,
    context: dict[str, str],
    env_name: str,
    probe_user: str | None,
) -> str:
    resource_group = context.get("AZURE_RESOURCE_GROUP")
    if not resource_group:
        raise RuntimeError("AZURE_RESOURCE_GROUP is required for usage-sessions")

    query = f"[?starts_with(name, 'ca-openclaw-{env_name}-')].name"
    names_raw = run_capture(
        [
            "az",
            "containerapp",
            "list",
            "-g",
            resource_group,
            "--query",
            query,
            "-o",
            "tsv",
        ],
        repo_root,
        env=context,
    )
    names = sorted([line.strip() for line in names_raw.splitlines() if line.strip()])
    if not names:
        raise RuntimeError(
            f"No user container apps found for env '{env_name}' in resource group '{resource_group}'"
        )

    if probe_user:
        candidate = f"ca-openclaw-{env_name}-{probe_user}"
        if candidate not in names:
            raise RuntimeError(
                f"Probe container app '{candidate}' not found. Available: {', '.join(names[:10])}"
            )
        return candidate

    return names[0]


def usage_sessions(
    repo_root: Path,
    env_name: str,
    user: str | None,
    probe_user: str | None,
) -> int:
    context = _build_context(repo_root, env_name)
    resource_group = context.get("AZURE_RESOURCE_GROUP")
    if not resource_group:
        raise RuntimeError("AZURE_RESOURCE_GROUP is required for usage-sessions")

    app_name = _resolve_probe_app(repo_root, context, env_name, probe_user)

    def fetch_window(hours: int) -> dict[str, int]:
        remote_script = "\n".join(
            [
                "import glob,os,json,datetime as d",
                f"cut=d.datetime.now(d.timezone.utc)-d.timedelta(hours={hours})",
                "print('__USAGE_START__')",
                "for p in sorted(glob.glob('/app/data/*')):",
                " if not os.path.isdir(p): continue",
                " u=os.path.basename(p);seen=set();c=0",
                " for f in glob.glob(p+'/.openclaw/agents/*/sessions/*.jsonl*'):",
                "  try:h=open(f,'r',encoding='utf-8',errors='ignore')",
                "  except: continue",
                "  for l in h:",
                "   l=l.strip()",
                "   if not l: continue",
                "   try:o=json.loads(l)",
                "   except: continue",
                "   m=o.get('message') or {}",
                "   if o.get('type')!='message' or m.get('role')!='user': continue",
                "   ts=str(o.get('timestamp',''))",
                "   try:od=d.datetime.fromisoformat(ts.replace('Z','+00:00'))",
                "   except: od=None",
                "   if od is None or od<cut: continue",
                "   txt='\\n'.join(i.get('text','') for i in (m.get('content') or []) if isinstance(i,dict) and i.get('type')=='text')",
                "   if 'Teams DM from' not in txt: continue",
                "   for part in txt.split('System: ['):",
                "    part=part.strip()",
                "    if not part: continue",
                "    part='System: ['+part;first=part.split('\\n',1)[0]",
                "    if 'Teams DM from' not in first: continue",
                "    k=ts+'|'+first",
                "    if k in seen: continue",
                "    seen.add(k);c+=1",
                "  h.close()",
                " print(u+'\\t'+str(c))",
                "print('__USAGE_END__')",
            ]
        )

        payload = base64.b64encode(remote_script.encode("utf-8")).decode("ascii")
        exec_command = (
            "python3 -c \"import base64;exec(base64.b64decode('"
            + payload
            + "').decode())\""
        )

        output = _run_capture_retry(
            [
                "script",
                "-q",
                "/dev/null",
                "az",
                "containerapp",
                "exec",
                "-n",
                app_name,
                "-g",
                resource_group,
                "--command",
                exec_command,
            ],
            repo_root,
            context,
        )

        start = output.find("__USAGE_START__")
        end = output.find("__USAGE_END__")
        if start == -1 or end == -1 or end <= start:
            raise RuntimeError(f"Failed to parse usage window output for {hours}h")

        body = output[start + len("__USAGE_START__") : end]
        counts: dict[str, int] = {}
        for line in body.splitlines():
            line = line.strip()
            if not line or "\t" not in line:
                continue
            raw_user, count = line.split("\t", 1)
            raw_user = raw_user.strip()
            if not raw_user:
                continue
            counts[raw_user] = int(count)
        return counts

    counts_48h = fetch_window(48)
    counts_7d = fetch_window(7 * 24)
    counts_14d = fetch_window(14 * 24)
    counts_30d = fetch_window(30 * 24)

    raw_users = set(counts_48h) | set(counts_7d) | set(counts_14d) | set(counts_30d)
    by_user: dict[str, dict[str, int]] = {}
    aliases: dict[str, set[str]] = {}
    for raw_user in raw_users:
        user_key = raw_user.strip() or raw_user
        if user_key not in by_user:
            by_user[user_key] = {
                "messages_48h": 0,
                "messages_7d": 0,
                "messages_14d": 0,
                "messages_30d": 0,
            }
            aliases[user_key] = set()

        aliases[user_key].add(raw_user)
        by_user[user_key]["messages_48h"] += counts_48h.get(raw_user, 0)
        by_user[user_key]["messages_7d"] += counts_7d.get(raw_user, 0)
        by_user[user_key]["messages_14d"] += counts_14d.get(raw_user, 0)
        by_user[user_key]["messages_30d"] += counts_30d.get(raw_user, 0)

    rows: list[dict[str, object]] = []
    for user_key, counts in by_user.items():
        rows.append(
            {
                "user": user_key,
                "messages_48h": counts["messages_48h"],
                "messages_7d": counts["messages_7d"],
                "messages_14d": counts["messages_14d"],
                "messages_30d": counts["messages_30d"],
                "aliases": sorted(aliases[user_key]),
            }
        )

    rows.sort(
        key=lambda item: (
            -int(item["messages_30d"]),
            -int(item["messages_14d"]),
            -int(item["messages_7d"]),
            -int(item["messages_48h"]),
            str(item["user"]),
        )
    )

    if user:
        rows = [row for row in rows if str(row.get("user", "")) == user]

    print(f"▸ Session message usage on [{env_name}] (48h/7d/14d/30d)")
    if not rows:
        if user:
            print(f"No rows found for user '{user}'.")
        else:
            print("No usage rows found.")
        return 0

    headers = ["user", "48h", "7d", "14d", "30d", "aliases"]
    table_rows: list[list[str]] = []
    for row in rows:
        table_rows.append(
            [
                str(row.get("user", "")),
                str(row.get("messages_48h", 0)),
                str(row.get("messages_7d", 0)),
                str(row.get("messages_14d", 0)),
                str(row.get("messages_30d", 0)),
                ",".join(row.get("aliases", [])),
            ]
        )

    widths = [len(h) for h in headers]
    for row in table_rows:
        for idx, cell in enumerate(row):
            widths[idx] = max(widths[idx], len(cell))

    print("  ".join(headers[idx].ljust(widths[idx]) for idx in range(len(headers))))
    print("  ".join("-" * widths[idx] for idx in range(len(headers))))
    for row in table_rows:
        print("  ".join(row[idx].ljust(widths[idx]) for idx in range(len(headers))))

    totals = {
        "messages_48h": sum(int(row.get("messages_48h", 0)) for row in rows),
        "messages_7d": sum(int(row.get("messages_7d", 0)) for row in rows),
        "messages_14d": sum(int(row.get("messages_14d", 0)) for row in rows),
        "messages_30d": sum(int(row.get("messages_30d", 0)) for row in rows),
    }
    print(
        "TOTAL"
        f"  48h={totals['messages_48h']}"
        f"  7d={totals['messages_7d']}"
        f"  14d={totals['messages_14d']}"
        f"  30d={totals['messages_30d']}"
    )

    return 0
