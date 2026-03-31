from __future__ import annotations

from pathlib import Path

from env_loader import load_layered_env, parse_env_file
from naming import resolve_and_validate_naming
from runner import run, run_capture, run_quiet


def _discover_deployer_ips(repo_root: Path) -> str:
    script = (
        "ip1=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || true); "
        "ip2=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || true); "
        'if [ -z "$ip1" ] && [ -z "$ip2" ]; then echo ""; '
        'elif [ "$ip1" = "$ip2" ] || [ -z "$ip2" ]; then echo "$ip1"; '
        'elif [ -z "$ip1" ]; then echo "$ip2"; '
        'else echo "$ip1,$ip2"; fi'
    )
    return run_capture(["bash", "-lc", script], repo_root)


def _prepare_context(repo_root: Path, env_name: str) -> dict[str, str]:
    env_map, _ = load_layered_env(repo_root=repo_root, env_name=env_name)
    resolved = resolve_and_validate_naming(repo_root, env_map, env_name)
    env_map.update(resolved)
    env_map["AZURE_ENVIRONMENT"] = env_name
    env_map.setdefault("AZURE_OWNER_SLUG", "platform")
    env_map.setdefault("CAE_INTERNAL_ONLY", "true")
    env_map.setdefault("MSTEAMS_RELAY_ENABLED", "false")
    env_map.setdefault("MSTEAMS_USER_SLUG_MAP", "{}")
    env_map.setdefault("IMAGE_TAG", "latest")
    env_map.setdefault(
        "SIGNAL_PROXY_IMAGE",
        f"{env_map.get('AZURE_ACR_NAME', f'openclaw{env_name}acr')}.azurecr.io/signal-proxy:{env_map['IMAGE_TAG']}",
    )
    return env_map


def _ensure_provider_auth(repo_root: Path, context: dict[str, str]) -> None:
    rc = run_quiet(
        ["terraform", "-chdir=infra/shared", "providers", "schema", "-json"],
        repo_root,
        env=context,
    )
    if rc != 0:
        raise RuntimeError(
            "Terraform provider auth check failed. Refresh Azure auth (az logout && az login) and retry."
        )


def _has_active_az_session(repo_root: Path, context: dict[str, str]) -> bool:
    return (
        run_quiet(["az", "account", "show", "--output", "none"], repo_root, env=context)
        == 0
    )


def _shared_tf_init_args(context: dict[str, str]) -> list[str]:
    return [
        "terraform",
        "-chdir=infra/shared",
        "init",
        "-backend-config",
        f"resource_group_name={context.get('TF_STATE_RG', '')}",
        "-backend-config",
        f"storage_account_name={context.get('TF_STATE_SA', '')}",
        "-backend-config",
        f"key={context.get('TF_STATE_KEY', '')}",
    ]


def _shared_tf_var_args(context: dict[str, str]) -> list[str]:
    return [
        "-var",
        f"environment={context.get('AZURE_ENVIRONMENT', '')}",
        "-var",
        f"location={context.get('AZURE_LOCATION', '')}",
        "-var",
        f"owner_slug={context.get('AZURE_OWNER_SLUG', 'platform')}",
        "-var",
        f"cae_internal_only={context.get('CAE_INTERNAL_ONLY', 'true')}",
        "-var",
        f"msteams_relay_enabled={context.get('MSTEAMS_RELAY_ENABLED', 'false')}",
        "-var",
        f"msteams_app_id={context.get('MSTEAMS_APP_ID', '')}",
        "-var",
        f"msteams_app_secret_value={context.get('MSTEAMS_APP_SECRET_VALUE', '')}",
        "-var",
        f"msteams_tenant_id={context.get('MSTEAMS_TENANT_ID', '')}",
        "-var",
        f"msteams_user_slug_map={context.get('MSTEAMS_USER_SLUG_MAP', '{}')}",
        "-var",
        f"acr_name={context.get('ACR_NAME', '')}",
        "-var",
        f"sa_name={context.get('SA_NAME', '')}",
        "-var",
        f"func_relay_name={context.get('FUNC_RELAY_NAME', '')}",
    ]


def _resolve_nfs_storage_account(repo_root: Path, context: dict[str, str]) -> str:
    rg = context.get("AZURE_RESOURCE_GROUP", "")
    configured = context.get("NFS_SA_NAME", "")
    if configured:
        rc = run_quiet(
            [
                "az",
                "storage",
                "account",
                "show",
                "--name",
                configured,
                "--resource-group",
                rg,
                "--output",
                "none",
            ],
            repo_root,
            env=context,
        )
        if rc == 0:
            return configured

    try:
        discovered = run_capture(
            [
                "terraform",
                "-chdir=infra/shared",
                "output",
                "-json",
                "nfs_storage_account_name",
            ],
            repo_root,
            env=context,
        ).strip('"')
    except Exception:
        discovered = ""

    if discovered:
        rc = run_quiet(
            [
                "az",
                "storage",
                "account",
                "show",
                "--name",
                discovered,
                "--resource-group",
                rg,
                "--output",
                "none",
            ],
            repo_root,
            env=context,
        )
        if rc == 0:
            return discovered

    raise RuntimeError(
        "Could not resolve accessible NFS storage account. "
        "Set NFS_SA_NAME in config/env/<env>.env or ensure infra/shared output nfs_storage_account_name is available."
    )


def _open_nfs_firewall(repo_root: Path, context: dict[str, str]) -> None:
    rg = context.get("AZURE_RESOURCE_GROUP", "")
    nfs_sa = _resolve_nfs_storage_account(repo_root, context)
    run(
        [
            "az",
            "storage",
            "account",
            "update",
            "--name",
            nfs_sa,
            "--resource-group",
            rg,
            "--default-action",
            "Allow",
            "--output",
            "none",
        ],
        repo_root,
        env=context,
    )
    run(["sleep", "15"], repo_root, env=context)


def _close_nfs_firewall(repo_root: Path, context: dict[str, str]) -> None:
    rg = context.get("AZURE_RESOURCE_GROUP", "")
    nfs_sa = _resolve_nfs_storage_account(repo_root, context)
    run(
        [
            "az",
            "storage",
            "account",
            "update",
            "--name",
            nfs_sa,
            "--resource-group",
            rg,
            "--default-action",
            "Deny",
            "--output",
            "none",
        ],
        repo_root,
        env=context,
    )


def _collect_known_phones(
    repo_root: Path, env_name: str, context: dict[str, str]
) -> str:
    bot_phone = context.get("SIGNAL_BOT_NUMBER", "").strip()
    if not bot_phone:
        return ""

    phones: list[str] = [bot_phone]
    users_dir = repo_root / "config" / "users"
    if not users_dir.exists():
        return ",".join(phones)

    for file in sorted(users_dir.glob("*.env")):
        if file.name == "user.example.env":
            continue
        slug = file.stem
        base = parse_env_file(file)
        local_file = repo_root / "config" / "local" / f"{env_name}.{slug}.env"
        local = parse_env_file(local_file) if local_file.exists() else {}
        value = local.get("SIGNAL_USER_PHONE") or base.get("SIGNAL_USER_PHONE")
        if value:
            phones.append(value)

    deduped = []
    seen = set()
    for phone in phones:
        if phone not in seen:
            seen.add(phone)
            deduped.append(phone)
    return ",".join(deduped)


def signal_build(repo_root: Path, env_name: str) -> int:
    context = _prepare_context(repo_root, env_name)
    if not _has_active_az_session(repo_root, context):
        raise RuntimeError("Azure CLI session is not active. Run 'az login' and retry.")
    _ensure_provider_auth(repo_root, context)

    acr = context.get("AZURE_ACR_NAME", "")
    image_tag = context.get("IMAGE_TAG", "latest")

    print(f"▸ Building signal-proxy image for [{env_name}]")
    run(
        [
            "az",
            "acr",
            "update",
            "-n",
            acr,
            "--default-action",
            "Allow",
            "--output",
            "none",
        ],
        repo_root,
        env=context,
    )
    rc = run(
        [
            "az",
            "acr",
            "build",
            "--registry",
            acr,
            "--image",
            f"signal-proxy:{image_tag}",
            "--file",
            "signal-proxy/Dockerfile",
            "signal-proxy/",
        ],
        repo_root,
        env=context,
    )
    run(
        [
            "az",
            "acr",
            "update",
            "-n",
            acr,
            "--default-action",
            "Deny",
            "--output",
            "none",
        ],
        repo_root,
        env=context,
    )
    return rc


def signal_deploy(repo_root: Path, env_name: str, plan: bool) -> int:
    context = _prepare_context(repo_root, env_name)
    if not _has_active_az_session(repo_root, context):
        raise RuntimeError("Azure CLI session is not active. Run 'az login' and retry.")
    _ensure_provider_auth(repo_root, context)

    if not context.get("SIGNAL_BOT_NUMBER"):
        raise RuntimeError("SIGNAL_BOT_NUMBER is required for signal deploy/plan")

    init_rc = run(_shared_tf_init_args(context), repo_root, env=context)
    if init_rc != 0:
        return init_rc

    if not plan:
        build_rc = signal_build(repo_root, env_name)
        if build_rc != 0:
            return build_rc

    deployer_ips = _discover_deployer_ips(repo_root)
    firewalls_opened = False
    try:
        _open_nfs_firewall(repo_root, context)
        firewalls_opened = True
        cmd = ["terraform", "-chdir=infra/shared", "plan" if plan else "apply"]
        if not plan:
            cmd.append("-auto-approve")
        cmd.extend(_shared_tf_var_args(context))
        cmd.extend(
            [
                "-var",
                f"deployer_ips={deployer_ips}",
                "-var",
                "signal_cli_enabled=true",
                "-var",
                f"signal_proxy_image={context.get('SIGNAL_PROXY_IMAGE', '')}",
                "-var",
                f"signal_bot_number={context.get('SIGNAL_BOT_NUMBER', '')}",
                "-var",
                f"signal_proxy_auth_token={context.get('SIGNAL_PROXY_AUTH_TOKEN', '')}",
            ]
        )
        rc = run(cmd, repo_root, env=context)
    finally:
        if firewalls_opened:
            try:
                _close_nfs_firewall(repo_root, context)
            except Exception as exc:
                print(f"WARNING: Could not close NFS firewall cleanly: {exc}")

    if rc != 0:
        return rc

    if not plan:
        signal_update_phones(repo_root, env_name)
    return 0


def signal_status(repo_root: Path, env_name: str) -> int:
    context = _prepare_context(repo_root, env_name)
    if not _has_active_az_session(repo_root, context):
        raise RuntimeError("Azure CLI session is not active. Run 'az login' and retry.")
    rg = context.get("AZURE_RESOURCE_GROUP", "")
    print(f"▸ Signal status for [{env_name}]")
    run(
        [
            "az",
            "containerapp",
            "show",
            "-n",
            f"ca-signal-cli-{env_name}",
            "-g",
            rg,
            "--query",
            "{name:name, status:properties.provisioningState, revision:properties.latestRevisionName, fqdn:properties.configuration.ingress.fqdn}",
            "-o",
            "table",
        ],
        repo_root,
        env=context,
    )
    return run(
        [
            "az",
            "containerapp",
            "show",
            "-n",
            f"ca-signal-proxy-{env_name}",
            "-g",
            rg,
            "--query",
            "{name:name, status:properties.provisioningState, revision:properties.latestRevisionName, fqdn:properties.configuration.ingress.fqdn}",
            "-o",
            "table",
        ],
        repo_root,
        env=context,
    )


def signal_logs_cli(repo_root: Path, env_name: str) -> int:
    context = _prepare_context(repo_root, env_name)
    if not _has_active_az_session(repo_root, context):
        raise RuntimeError("Azure CLI session is not active. Run 'az login' and retry.")
    rg = context.get("AZURE_RESOURCE_GROUP", "")
    return run(
        [
            "az",
            "containerapp",
            "logs",
            "show",
            "--name",
            f"ca-signal-cli-{env_name}",
            "--resource-group",
            rg,
            "--follow",
            "--tail",
            "100",
        ],
        repo_root,
        env=context,
    )


def signal_logs_proxy(repo_root: Path, env_name: str) -> int:
    context = _prepare_context(repo_root, env_name)
    if not _has_active_az_session(repo_root, context):
        raise RuntimeError("Azure CLI session is not active. Run 'az login' and retry.")
    rg = context.get("AZURE_RESOURCE_GROUP", "")
    return run(
        [
            "az",
            "containerapp",
            "logs",
            "show",
            "--name",
            f"ca-signal-proxy-{env_name}",
            "--resource-group",
            rg,
            "--follow",
            "--tail",
            "100",
        ],
        repo_root,
        env=context,
    )


def signal_register(repo_root: Path, env_name: str) -> int:
    context = _prepare_context(repo_root, env_name)
    if not _has_active_az_session(repo_root, context):
        raise RuntimeError("Azure CLI session is not active. Run 'az login' and retry.")
    rg = context.get("AZURE_RESOURCE_GROUP", "")
    print("Opening shell in signal-cli container...")
    print("Run: signal-cli -a +YOURNUMBER register")
    print("Then: signal-cli -a +YOURNUMBER verify CODE")
    return run(
        [
            "az",
            "containerapp",
            "exec",
            "--name",
            f"ca-signal-cli-{env_name}",
            "--resource-group",
            rg,
            "--command",
            "sh",
        ],
        repo_root,
        env=context,
    )


def signal_update_phones(repo_root: Path, env_name: str) -> int:
    context = _prepare_context(repo_root, env_name)
    if not _has_active_az_session(repo_root, context):
        raise RuntimeError("Azure CLI session is not active. Run 'az login' and retry.")
    rg = context.get("AZURE_RESOURCE_GROUP", "")
    phones = _collect_known_phones(repo_root, env_name, context)
    if not phones:
        print("SIGNAL_BOT_NUMBER not set — skipping signal-update-phones")
        return 0

    print(f"▸ Updating SIGNAL_KNOWN_PHONES on ca-signal-proxy-{env_name}")
    print(f"  Phones: {phones}")
    return run(
        [
            "az",
            "containerapp",
            "update",
            "--name",
            f"ca-signal-proxy-{env_name}",
            "--resource-group",
            rg,
            "--set-env-vars",
            f"SIGNAL_KNOWN_PHONES={phones}",
            "--output",
            "none",
        ],
        repo_root,
        env=context,
    )
