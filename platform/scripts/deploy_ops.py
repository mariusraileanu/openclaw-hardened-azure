from __future__ import annotations

from pathlib import Path

from env_loader import load_layered_env
from naming import resolve_and_validate_naming
from runner import run, run_quiet
from user_deploy_ops import deploy_user as deploy_user_direct
from user_deploy_ops import import_user as import_user_direct
from user_deploy_ops import remove_user as remove_user_direct


REQUIRED_SHARED_KEYS = [
    "AZURE_LOCATION",
    "COMPASS_API_KEY",
    "OPENCLAW_GATEWAY_AUTH_TOKEN",
]


def _ensure_shared_requirements(env_map: dict[str, str]) -> None:
    missing = [key for key in REQUIRED_SHARED_KEYS if not env_map.get(key)]
    if missing:
        raise RuntimeError(
            "Missing required shared config keys: "
            + ", ".join(missing)
            + " (set them in config/env/<env>.env or config/local/<env>.env)"
        )


def _prepare_env(
    repo_root: Path, env_name: str, user: str | None = None
) -> dict[str, str]:
    env_map, _ = load_layered_env(
        repo_root=repo_root,
        env_name=env_name,
        user=user,
        require_user_file=bool(user),
    )
    _ensure_shared_requirements(env_map)
    resolved = resolve_and_validate_naming(repo_root, env_map, env_name)
    env_map.update(resolved)
    env_map["AZURE_ENVIRONMENT"] = env_name
    env_map.setdefault("AZURE_OWNER_SLUG", "platform")
    env_map.setdefault("CAE_INTERNAL_ONLY", "true")
    env_map.setdefault("MSTEAMS_RELAY_ENABLED", "false")
    env_map.setdefault("MSTEAMS_USER_SLUG_MAP", "{}")
    return env_map


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


def deploy_shared(repo_root: Path, env_name: str, plan: bool, destroy: bool) -> int:
    context = _prepare_env(repo_root, env_name)
    _ensure_terraform_provider_auth(repo_root, context)
    init_rc = run(_shared_tf_init_args(context), repo_root, env=context)
    if init_rc != 0:
        return init_rc

    import_rc = run(
        [
            "bash",
            "infra/shared/import.sh",
            env_name,
            context.get("AZURE_LOCATION", ""),
            context.get("AZURE_OWNER_SLUG", "platform"),
        ],
        repo_root,
        env=context,
    )
    if import_rc != 0:
        return import_rc

    tf_cmd = ["terraform", "-chdir=infra/shared"]
    if destroy:
        tf_cmd.append("destroy")
    elif plan:
        tf_cmd.append("plan")
    else:
        tf_cmd.append("apply")
    if not (plan or destroy):
        tf_cmd.append("-auto-approve")
    tf_cmd.extend(_shared_tf_var_args(context))
    return run(tf_cmd, repo_root, env=context)


def deploy_user(repo_root: Path, env_name: str, user: str, plan: bool) -> int:
    context = _prepare_env(repo_root, env_name, user)
    _ensure_terraform_provider_auth(repo_root, context)
    return deploy_user_direct(repo_root, env_name, user, plan)


def remove_user(repo_root: Path, env_name: str, user: str) -> int:
    context = _prepare_env(repo_root, env_name, user)
    _ensure_terraform_provider_auth(repo_root, context)
    return remove_user_direct(repo_root, env_name, user)


def import_user(
    repo_root: Path,
    env_name: str,
    user: str,
    resource_address: str,
    azure_resource_id: str,
) -> int:
    context = _prepare_env(repo_root, env_name, user)
    _ensure_terraform_provider_auth(repo_root, context)
    return import_user_direct(
        repo_root,
        env_name,
        user,
        resource_address,
        azure_resource_id,
    )
