from __future__ import annotations

from pathlib import Path

from common import (
    close_nfs_firewall,
    discover_deployer_ips,
    ensure_terraform_provider_auth,
    has_active_az_session,
    open_nfs_firewall,
    resolve_nfs_storage_account,
    shared_tf_init_args,
    shared_tf_var_args,
)
from env_loader import load_layered_env, parse_env_file
from naming import resolve_and_validate_naming
from runner import run, run_capture


def _prepare_context(repo_root: Path, env_name: str) -> dict[str, str]:
    env_map, _ = load_layered_env(repo_root=repo_root, env_name=env_name)
    resolved = resolve_and_validate_naming(repo_root, env_map, env_name)
    env_map.update(resolved)
    env_map["AZURE_ENVIRONMENT"] = env_name
    env_map.setdefault("AZURE_OWNER_SLUG", "platform")
    env_map.setdefault("CAE_INTERNAL_ONLY", "true")
    env_map.setdefault("MSTEAMS_RELAY_ENABLED", "false")
    env_map.setdefault("IMAGE_TAG", "latest")
    env_map.setdefault(
        "SIGNAL_PROXY_IMAGE",
        f"{env_map.get('AZURE_ACR_NAME', f'openclaw{env_name}acr')}.azurecr.io/signal-proxy:{env_map['IMAGE_TAG']}",
    )
    return env_map


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
    if not has_active_az_session(repo_root, context):
        raise RuntimeError("Azure CLI session is not active. Run 'az login' and retry.")
    ensure_terraform_provider_auth(repo_root, context)

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
    if not has_active_az_session(repo_root, context):
        raise RuntimeError("Azure CLI session is not active. Run 'az login' and retry.")
    ensure_terraform_provider_auth(repo_root, context)

    if not context.get("SIGNAL_BOT_NUMBER"):
        raise RuntimeError("SIGNAL_BOT_NUMBER is required for signal deploy/plan")

    init_rc = run(shared_tf_init_args(context), repo_root, env=context)
    if init_rc != 0:
        return init_rc

    if not plan:
        build_rc = signal_build(repo_root, env_name)
        if build_rc != 0:
            return build_rc

    deployer_ips = discover_deployer_ips(repo_root)
    firewalls_opened = False
    try:
        open_nfs_firewall(repo_root, context)
        firewalls_opened = True
        cmd = ["terraform", "-chdir=infra/shared", "plan" if plan else "apply"]
        if not plan:
            cmd.append("-auto-approve")
        cmd.extend(shared_tf_var_args(context))
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
                close_nfs_firewall(repo_root, context)
            except Exception as exc:
                print(f"WARNING: Could not close NFS firewall cleanly: {exc}")

    if rc != 0:
        return rc

    if not plan:
        signal_update_phones(repo_root, env_name)
    return 0


def signal_status(repo_root: Path, env_name: str) -> int:
    context = _prepare_context(repo_root, env_name)
    if not has_active_az_session(repo_root, context):
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
    if not has_active_az_session(repo_root, context):
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
    if not has_active_az_session(repo_root, context):
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
    if not has_active_az_session(repo_root, context):
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
    if not has_active_az_session(repo_root, context):
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
