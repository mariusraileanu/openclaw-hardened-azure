from __future__ import annotations

from pathlib import Path

from env_loader import load_layered_env
from naming import resolve_and_validate_naming
from runner import run, run_capture, run_quiet


def teams_manifest(repo_root: Path, env_name: str) -> int:
    print(f"▸ Rendering Teams manifest for ENV={env_name}")
    rc = run(
        ["node", "teams-app/render-manifest.mjs"], repo_root, env={"ENV": env_name}
    )
    if rc != 0:
        return rc
    run(["mkdir", "-p", f"teams-app/dist/{env_name}"], repo_root)
    if env_name == "dev":
        return run(
            ["cp", "teams-app/dist/dev/manifest.json", "teams-app/manifest.json"],
            repo_root,
        )
    return 0


def teams_manifest_all(repo_root: Path) -> int:
    for env_name in ["dev", "stage", "prod"]:
        rc = teams_manifest(repo_root, env_name)
        if rc != 0:
            return rc
    return 0


def teams_validate(repo_root: Path, env_name: str) -> int:
    rc = teams_manifest(repo_root, env_name)
    if rc != 0:
        return rc
    return run(
        ["node", "teams-app/check-manifest.mjs"], repo_root, env={"ENV": env_name}
    )


def teams_package(repo_root: Path, env_name: str) -> int:
    print(f"▸ Packaging Teams app for ENV={env_name}")
    return run(["teams-app/package-teams-app.sh"], repo_root, env={"ENV": env_name})


def teams_release_check(repo_root: Path) -> int:
    rc = teams_manifest_all(repo_root)
    if rc != 0:
        return rc
    for env_name in ["dev", "stage", "prod"]:
        rc = teams_validate(repo_root, env_name)
        if rc != 0:
            return rc
    for env_name in ["dev", "stage", "prod"]:
        rc = teams_package(repo_root, env_name)
        if rc != 0:
            return rc
    print("▸ Teams release check passed")
    return 0


def _prepare_context(repo_root: Path, env_name: str) -> dict[str, str]:
    env_map, _ = load_layered_env(repo_root=repo_root, env_name=env_name)
    resolved = resolve_and_validate_naming(repo_root, env_map, env_name)
    env_map.update(resolved)
    env_map["AZURE_ENVIRONMENT"] = env_name
    env_map.setdefault("AZURE_OWNER_SLUG", "platform")
    env_map.setdefault("CAE_INTERNAL_ONLY", "true")
    env_map.setdefault("MSTEAMS_RELAY_ENABLED", "false")
    env_map.setdefault("MSTEAMS_USER_SLUG_MAP", "{}")
    return env_map


def _has_active_az_session(repo_root: Path, context: dict[str, str]) -> bool:
    return (
        run_quiet(["az", "account", "show", "--output", "none"], repo_root, env=context)
        == 0
    )


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
        "-var",
        f"deployer_ips={context.get('DEPLOYER_IPS', '')}",
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


def _open_key_vault_firewall(
    repo_root: Path, context: dict[str, str], deployer_ips: str
) -> None:
    rg = context.get("AZURE_RESOURCE_GROUP", "")
    kv = context.get("AZURE_KEY_VAULT_NAME", "")
    if not kv:
        return
    for ip in [p for p in deployer_ips.split(",") if p.strip()]:
        run(
            [
                "az",
                "keyvault",
                "network-rule",
                "add",
                "--name",
                kv,
                "--resource-group",
                rg,
                "--ip-address",
                f"{ip}/32",
                "--output",
                "none",
            ],
            repo_root,
            env=context,
        )


def _close_key_vault_firewall(
    repo_root: Path, context: dict[str, str], deployer_ips: str
) -> None:
    rg = context.get("AZURE_RESOURCE_GROUP", "")
    kv = context.get("AZURE_KEY_VAULT_NAME", "")
    if not kv:
        return
    for ip in [p for p in deployer_ips.split(",") if p.strip()]:
        run(
            [
                "az",
                "keyvault",
                "network-rule",
                "remove",
                "--name",
                kv,
                "--resource-group",
                rg,
                "--ip-address",
                f"{ip}/32",
                "--output",
                "none",
            ],
            repo_root,
            env=context,
        )


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


def teams_relay_build(repo_root: Path, env_name: str) -> int:
    _ = _prepare_context(repo_root, env_name)
    print("▸ Building Teams relay Function App")
    install_rc = run(["npm", "--prefix", "teams-relay", "install"], repo_root)
    if install_rc != 0:
        return install_rc
    return run(["npm", "--prefix", "teams-relay", "run", "build"], repo_root)


def teams_relay_deploy(repo_root: Path, env_name: str) -> int:
    context = _prepare_context(repo_root, env_name)
    if not _has_active_az_session(repo_root, context):
        raise RuntimeError("Azure CLI session is not active. Run 'az login' and retry.")
    _ensure_provider_auth(repo_root, context)

    build_rc = teams_relay_build(repo_root, env_name)
    if build_rc != 0:
        return build_rc

    init_rc = run(_shared_tf_init_args(context), repo_root, env=context)
    if init_rc != 0:
        return init_rc

    deployer_ips = _discover_deployer_ips(repo_root)
    context["DEPLOYER_IPS"] = deployer_ips
    should_manage_kv_firewall = bool(
        context.get("AZURE_KEY_VAULT_NAME", "")
        and context.get("MSTEAMS_APP_SECRET_VALUE", "")
    )

    target_args = [
        "-target=azurerm_subnet.func",
        "-target=azurerm_storage_account.func",
        "-target=azurerm_storage_container.func_deploy",
        "-target=azurerm_service_plan.relay",
        "-target=azurerm_function_app_flex_consumption.relay",
        "-target=azurerm_bot_service_azure_bot.shared",
        "-target=azurerm_bot_channel_ms_teams.shared",
        "-target=azurerm_key_vault_secret.msteams_app_password",
    ]

    firewalls_opened = False
    try:
        if should_manage_kv_firewall and deployer_ips:
            _open_key_vault_firewall(repo_root, context, deployer_ips)
            firewalls_opened = True

        cmd = [
            "terraform",
            "-chdir=infra/shared",
            "apply",
            "-auto-approve",
        ]
        cmd.extend(target_args)
        cmd.extend(_shared_tf_var_args(context))
        cmd.extend(["-var", "msteams_relay_enabled=true"])
        rc = run(cmd, repo_root, env=context)
    finally:
        if firewalls_opened:
            try:
                _close_key_vault_firewall(repo_root, context, deployer_ips)
            except Exception as exc:
                print(f"WARNING: Could not close Key Vault firewall cleanly: {exc}")

    if rc != 0:
        return rc

    relay_hostname = ""
    try:
        relay_hostname = run_capture(
            [
                "terraform",
                "-chdir=infra/shared",
                "output",
                "-raw",
                "teams_relay_hostname",
            ],
            repo_root,
            env=context,
        )
    except Exception:
        relay_hostname = ""

    print("=============================================")
    print(" Teams relay deployed!")
    print("=============================================")
    if relay_hostname:
        print(f"Relay hostname: {relay_hostname}")
    print("Now deploy the relay code:")
    func_name = context.get("FUNC_RELAY_NAME", f"func-relay-{env_name}")
    print(f"  func azure functionapp publish {func_name} --prefix teams-relay")
    return 0
