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
from env_loader import load_layered_env
from naming import resolve_and_validate_naming
from runner import run, run_capture


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


def teams_relay_build(repo_root: Path, env_name: str) -> int:
    _ = _prepare_context(repo_root, env_name)
    print("▸ Building Teams relay Function App")
    install_rc = run(["npm", "--prefix", "teams-relay", "install"], repo_root)
    if install_rc != 0:
        return install_rc
    return run(["npm", "--prefix", "teams-relay", "run", "build"], repo_root)


def teams_relay_deploy(repo_root: Path, env_name: str) -> int:
    context = _prepare_context(repo_root, env_name)
    if not has_active_az_session(repo_root, context):
        raise RuntimeError("Azure CLI session is not active. Run 'az login' and retry.")
    ensure_terraform_provider_auth(repo_root, context)

    build_rc = teams_relay_build(repo_root, env_name)
    if build_rc != 0:
        return build_rc

    init_rc = run(shared_tf_init_args(context), repo_root, env=context)
    if init_rc != 0:
        return init_rc

    deployer_ips = discover_deployer_ips(repo_root)
    context["DEPLOYER_IPS"] = deployer_ips
    should_manage_kv_firewall = bool(
        context.get("AZURE_KEY_VAULT_NAME", "")
        and context.get("MSTEAMS_APP_SECRET_VALUE", "")
    )

    target_args = [
        "-target=azurerm_subnet.func",
        "-target=azapi_resource.func_storage",
        "-target=azapi_resource.func_deploy_container",
        "-target=azurerm_role_assignment.func_storage_blob",
        "-target=azurerm_service_plan.relay",
        "-target=azurerm_linux_function_app.relay",
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
        cmd.extend(shared_tf_var_args(context, deployer_ips=deployer_ips))
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
