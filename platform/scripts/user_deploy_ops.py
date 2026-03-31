from __future__ import annotations

from pathlib import Path

from env_loader import load_layered_env
from naming import resolve_and_validate_naming
from runner import run, run_capture, run_quiet
from signal_ops import signal_update_phones


REQUIRED_SHARED_KEYS = [
    "AZURE_LOCATION",
    "COMPASS_API_KEY",
    "OPENCLAW_GATEWAY_AUTH_TOKEN",
]


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


def _ensure_terraform_provider_auth(repo_root: Path, context: dict[str, str]) -> None:
    rc = run_quiet(
        [
            "terraform",
            "-chdir=infra/shared",
            "providers",
            "schema",
            "-json",
        ],
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


def _discover_graph_mcp_url(
    repo_root: Path, env_name: str, user: str, context: dict[str, str]
) -> str:
    rg = context.get("AZURE_RESOURCE_GROUP", "")
    app_name = f"ca-graph-mcp-gw-{env_name}-{user}"
    try:
        fqdn = run_capture(
            [
                "az",
                "containerapp",
                "show",
                "-n",
                app_name,
                "-g",
                rg,
                "--query",
                "properties.configuration.ingress.fqdn",
                "-o",
                "tsv",
            ],
            repo_root,
            env=context,
        )
    except Exception:
        fqdn = ""

    if fqdn:
        return f"http://{fqdn}"
    print(f"WARNING: MCP gateway {app_name} not found. Using placeholder.")
    return "placeholder"


def _ensure_shared_requirements(env_map: dict[str, str]) -> None:
    missing = [key for key in REQUIRED_SHARED_KEYS if not env_map.get(key)]
    if missing:
        raise RuntimeError(
            "Missing required shared config keys: "
            + ", ".join(missing)
            + " (set them in config/env/<env>.env or config/local/<env>.env)"
        )


def _prepare_context(repo_root: Path, env_name: str, user: str) -> dict[str, str]:
    env_map, _ = load_layered_env(
        repo_root=repo_root,
        env_name=env_name,
        user=user,
        require_user_file=False,
    )
    if not env_map.get("AZURE_LOCATION"):
        raise RuntimeError("AZURE_LOCATION is required (set in config/env/<env>.env)")
    resolved = resolve_and_validate_naming(repo_root, env_map, env_name)
    env_map.update(resolved)
    env_map["AZURE_ENVIRONMENT"] = env_name
    env_map["USER_SLUG"] = user
    env_map.setdefault("IMAGE_TAG", "latest")
    env_map.setdefault(
        "IMAGE_REF",
        f"{env_map.get('AZURE_ACR_NAME', f'openclaw{env_name}acr')}.azurecr.io/openclaw-golden:{env_map['IMAGE_TAG']}",
    )
    return env_map


def _terraform_user_vars(
    context: dict[str, str], user: str, graph_mcp_url: str
) -> list[str]:
    args = [
        "-var",
        f"user_slug={user}",
        "-var",
        f"environment={context.get('AZURE_ENVIRONMENT', '')}",
        "-var",
        f"location={context.get('AZURE_LOCATION', '')}",
        "-var",
        f"image_ref={context.get('IMAGE_REF', '')}",
        "-var",
        f"graph_mcp_url={graph_mcp_url}",
        "-var",
        f"resource_group_name={context.get('AZURE_RESOURCE_GROUP', '')}",
        "-var",
        f"key_vault_name={context.get('AZURE_KEY_VAULT_NAME', '')}",
        "-var",
        f"acr_name={context.get('AZURE_ACR_NAME', '')}",
        "-var",
        f"cae_name={context.get('AZURE_CONTAINERAPPS_ENV', '')}",
        "-var",
        f"cae_nfs_storage_name={context.get('CAE_NFS_STORAGE_NAME', '')}",
    ]
    signal_cli_url = context.get("SIGNAL_CLI_URL", "")
    signal_bot = context.get("SIGNAL_BOT_NUMBER", "")
    signal_user = context.get("SIGNAL_USER_PHONE", "")
    if signal_cli_url and signal_bot and signal_user:
        args.extend(["-var", f"signal_bot_number={signal_bot}"])
        print(f"Signal enabled: bot={signal_bot} user={signal_user}")
    else:
        print("Signal: skipped (missing vars or proxy not deployed)")
    return args


def _open_firewalls(
    repo_root: Path, context: dict[str, str], deployer_ips: str
) -> None:
    rg = context.get("AZURE_RESOURCE_GROUP", "")
    nfs_sa = _resolve_nfs_storage_account(repo_root, context)
    kv = context.get("AZURE_KEY_VAULT_NAME", "")
    print("--- Opening firewalls for Terraform ---")
    print(f"Detected deployer IPs: {deployer_ips}")
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
    run(["sleep", "15"], repo_root, env=context)


def _close_firewalls(
    repo_root: Path, context: dict[str, str], deployer_ips: str
) -> None:
    rg = context.get("AZURE_RESOURCE_GROUP", "")
    nfs_sa = _resolve_nfs_storage_account(repo_root, context)
    kv = context.get("AZURE_KEY_VAULT_NAME", "")
    print("--- Closing firewalls ---")
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


def _open_firewalls_safe(
    repo_root: Path, context: dict[str, str], deployer_ips: str
) -> bool:
    try:
        _open_firewalls(repo_root, context, deployer_ips)
        return True
    except Exception as exc:
        print(f"WARNING: Firewall open step failed: {exc}")
        return False


def _close_firewalls_safe(
    repo_root: Path, context: dict[str, str], deployer_ips: str
) -> None:
    try:
        _close_firewalls(repo_root, context, deployer_ips)
    except Exception as exc:
        print(f"WARNING: Firewall close step failed: {exc}")


def _tf_user_env(
    context: dict[str, str], signal_proxy_auth_token_tf: str, signal_cli_url_tf: str
) -> dict[str, str]:
    extra = {
        "TF_VAR_compass_base_url": context.get("COMPASS_BASE_URL", ""),
        "TF_VAR_compass_api_key": context.get("COMPASS_API_KEY", ""),
        "TF_VAR_openclaw_gateway_auth_token": context.get(
            "OPENCLAW_GATEWAY_AUTH_TOKEN", ""
        ),
        "TF_VAR_tavily_api_key": context.get("TAVILY_API_KEY", ""),
        "TF_VAR_signal_user_phone": context.get("SIGNAL_USER_PHONE", ""),
        "TF_VAR_signal_cli_url": signal_cli_url_tf,
        "TF_VAR_signal_proxy_auth_token": signal_proxy_auth_token_tf,
        "TF_VAR_msteams_enabled": context.get("MSTEAMS_ENABLED", ""),
        "TF_VAR_msteams_tenant_id": context.get("MSTEAMS_TENANT_ID", ""),
        "TF_VAR_msteams_app_id": context.get("MSTEAMS_APP_ID", ""),
    }
    return extra


def deploy_user(repo_root: Path, env_name: str, user: str, plan: bool) -> int:
    context = _prepare_context(repo_root, env_name, user)
    _ensure_shared_requirements(context)

    if not _has_active_az_session(repo_root, context):
        raise RuntimeError("Azure CLI session is not active. Run 'az login' and retry.")
    _ensure_terraform_provider_auth(repo_root, context)

    run(["terraform", "-chdir=infra/user-app", "init"], repo_root, env=context)
    run(
        [
            "terraform",
            "-chdir=infra/user-app",
            "workspace",
            "select",
            "-or-create",
            user,
        ],
        repo_root,
        env=context,
    )

    signal_cli_url_tf = context.get("SIGNAL_CLI_URL", "")
    if not signal_cli_url_tf:
        try:
            signal_cli_url_tf = run_capture(
                [
                    "terraform",
                    "-chdir=infra/shared",
                    "output",
                    "-json",
                    "signal_cli_url",
                ],
                repo_root,
                env=context,
            ).strip('"')
        except Exception:
            signal_cli_url_tf = ""

    signal_proxy_auth_token_tf = context.get("SIGNAL_PROXY_AUTH_TOKEN", "")
    if not signal_proxy_auth_token_tf:
        try:
            signal_proxy_auth_token_tf = run_capture(
                [
                    "terraform",
                    "-chdir=infra/shared",
                    "output",
                    "-json",
                    "signal_proxy_auth_token",
                ],
                repo_root,
                env=context,
            ).strip('"')
        except Exception:
            signal_proxy_auth_token_tf = ""

    msteams_app_password_secret_id_tf = ""
    try:
        msteams_app_password_secret_id_tf = run_capture(
            [
                "terraform",
                "-chdir=infra/shared",
                "output",
                "-json",
                "msteams_app_password_secret_id",
            ],
            repo_root,
            env=context,
        ).strip('"')
    except Exception:
        msteams_app_password_secret_id_tf = ""

    graph_mcp_url = _discover_graph_mcp_url(repo_root, env_name, user, context)
    deployer_ips = _discover_deployer_ips(repo_root)

    tf_env = _tf_user_env(context, signal_proxy_auth_token_tf, signal_cli_url_tf)
    tf_env["TF_VAR_msteams_app_password_secret_id"] = msteams_app_password_secret_id_tf

    terraform_args = _terraform_user_vars(context, user, graph_mcp_url)

    firewalls_opened = _open_firewalls_safe(repo_root, context, deployer_ips)
    rc = 0
    try:
        cmd = ["terraform", "-chdir=infra/user-app", "plan" if plan else "apply"]
        if not plan:
            cmd.append("-auto-approve")
        cmd.extend(terraform_args)
        rc = run(cmd, repo_root, env={**context, **tf_env})
    finally:
        if firewalls_opened:
            _close_firewalls_safe(repo_root, context, deployer_ips)

    if rc != 0:
        return rc

    if not plan:
        signal_rc = signal_update_phones(repo_root, env_name)
        if signal_rc != 0:
            return signal_rc
    return 0


def remove_user(repo_root: Path, env_name: str, user: str) -> int:
    context = _prepare_context(repo_root, env_name, user)

    if not _has_active_az_session(repo_root, context):
        raise RuntimeError("Azure CLI session is not active. Run 'az login' and retry.")
    _ensure_terraform_provider_auth(repo_root, context)

    run(["terraform", "-chdir=infra/user-app", "init"], repo_root, env=context)
    run(
        [
            "terraform",
            "-chdir=infra/user-app",
            "workspace",
            "select",
            "-or-create",
            user,
        ],
        repo_root,
        env=context,
    )

    deployer_ips = _discover_deployer_ips(repo_root)

    print("=============================================")
    print(f" Destroying user app: ca-openclaw-{env_name}-{user}")
    print(f" Environment: {env_name}")
    print("=============================================")

    firewalls_opened = _open_firewalls_safe(repo_root, context, deployer_ips)
    rc = 0
    try:
        cmd = [
            "terraform",
            "-chdir=infra/user-app",
            "destroy",
            "-var",
            f"user_slug={user}",
            "-var",
            f"environment={env_name}",
            "-var",
            f"location={context.get('AZURE_LOCATION', '')}",
            "-var",
            "image_ref=placeholder",
            "-var",
            "graph_mcp_url=placeholder",
            "-var",
            f"resource_group_name={context.get('AZURE_RESOURCE_GROUP', '')}",
            "-var",
            f"key_vault_name={context.get('AZURE_KEY_VAULT_NAME', '')}",
            "-var",
            f"acr_name={context.get('AZURE_ACR_NAME', '')}",
            "-var",
            f"cae_name={context.get('AZURE_CONTAINERAPPS_ENV', '')}",
            "-var",
            f"cae_nfs_storage_name={context.get('CAE_NFS_STORAGE_NAME', '')}",
        ]
        tf_destroy_env = {
            "TF_VAR_compass_api_key": "placeholder",
            "TF_VAR_openclaw_gateway_auth_token": "placeholder",
        }
        rc = run(cmd, repo_root, env={**context, **tf_destroy_env})
    finally:
        if firewalls_opened:
            _close_firewalls_safe(repo_root, context, deployer_ips)

    if rc != 0:
        return rc

    print("=============================================")
    print(f" User app destroyed: ca-openclaw-{env_name}-{user}")
    print("=============================================")
    print(f"Note: NFS data at /data/{user}/ is preserved.")

    signal_rc = signal_update_phones(repo_root, env_name)
    if signal_rc != 0:
        return signal_rc
    return 0


def import_user(
    repo_root: Path,
    env_name: str,
    user: str,
    resource_address: str,
    azure_resource_id: str,
) -> int:
    context = _prepare_context(repo_root, env_name, user)
    _ensure_shared_requirements(context)

    if not _has_active_az_session(repo_root, context):
        raise RuntimeError("Azure CLI session is not active. Run 'az login' and retry.")
    _ensure_terraform_provider_auth(repo_root, context)

    run(["terraform", "-chdir=infra/user-app", "init"], repo_root, env=context)
    run(
        [
            "terraform",
            "-chdir=infra/user-app",
            "workspace",
            "select",
            "-or-create",
            user,
        ],
        repo_root,
        env=context,
    )

    signal_cli_url_tf = context.get("SIGNAL_CLI_URL", "")
    if not signal_cli_url_tf:
        try:
            signal_cli_url_tf = run_capture(
                [
                    "terraform",
                    "-chdir=infra/shared",
                    "output",
                    "-json",
                    "signal_cli_url",
                ],
                repo_root,
                env=context,
            ).strip('"')
        except Exception:
            signal_cli_url_tf = ""

    signal_proxy_auth_token_tf = context.get("SIGNAL_PROXY_AUTH_TOKEN", "")
    if not signal_proxy_auth_token_tf:
        try:
            signal_proxy_auth_token_tf = run_capture(
                [
                    "terraform",
                    "-chdir=infra/shared",
                    "output",
                    "-json",
                    "signal_proxy_auth_token",
                ],
                repo_root,
                env=context,
            ).strip('"')
        except Exception:
            signal_proxy_auth_token_tf = ""

    msteams_app_password_secret_id_tf = ""
    try:
        msteams_app_password_secret_id_tf = run_capture(
            [
                "terraform",
                "-chdir=infra/shared",
                "output",
                "-json",
                "msteams_app_password_secret_id",
            ],
            repo_root,
            env=context,
        ).strip('"')
    except Exception:
        msteams_app_password_secret_id_tf = ""

    graph_mcp_url = _discover_graph_mcp_url(repo_root, env_name, user, context)
    deployer_ips = _discover_deployer_ips(repo_root)

    tf_env = _tf_user_env(context, signal_proxy_auth_token_tf, signal_cli_url_tf)
    tf_env["TF_VAR_msteams_app_password_secret_id"] = msteams_app_password_secret_id_tf

    terraform_args = _terraform_user_vars(context, user, graph_mcp_url)

    print(f"▸ Importing resource into TF state for user '{user}' on [{env_name}]")
    print(f"  Resource: {resource_address}")
    print(f"  ID:       {azure_resource_id}")

    firewalls_opened = _open_firewalls_safe(repo_root, context, deployer_ips)
    rc = 0
    try:
        cmd = ["terraform", "-chdir=infra/user-app", "import"]
        cmd.extend(terraform_args)
        cmd.extend([resource_address, azure_resource_id])
        rc = run(cmd, repo_root, env={**context, **tf_env})
    finally:
        if firewalls_opened:
            _close_firewalls_safe(repo_root, context, deployer_ips)

    if rc != 0:
        return rc

    print("=============================================")
    print(f" Imported {resource_address} into {user} workspace")
    print("=============================================")
    return 0
