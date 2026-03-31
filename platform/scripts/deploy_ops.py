from __future__ import annotations

from pathlib import Path

from common import (
    ensure_shared_requirements,
    ensure_terraform_provider_auth,
    shared_tf_init_args,
    shared_tf_var_args,
)
from env_loader import load_layered_env
from naming import resolve_and_validate_naming
from runner import run
from user_deploy_ops import deploy_user as deploy_user_direct
from user_deploy_ops import import_user as import_user_direct
from user_deploy_ops import remove_user as remove_user_direct


def _prepare_env(
    repo_root: Path, env_name: str, user: str | None = None
) -> dict[str, str]:
    env_map, _ = load_layered_env(
        repo_root=repo_root,
        env_name=env_name,
        user=user,
        require_user_file=bool(user),
    )
    ensure_shared_requirements(env_map)
    resolved = resolve_and_validate_naming(repo_root, env_map, env_name)
    env_map.update(resolved)
    env_map["AZURE_ENVIRONMENT"] = env_name
    env_map.setdefault("AZURE_OWNER_SLUG", "platform")
    env_map.setdefault("CAE_INTERNAL_ONLY", "true")
    env_map.setdefault("MSTEAMS_RELAY_ENABLED", "false")
    env_map.setdefault("MSTEAMS_USER_SLUG_MAP", "{}")
    return env_map


def deploy_shared(repo_root: Path, env_name: str, plan: bool, destroy: bool) -> int:
    context = _prepare_env(repo_root, env_name)
    ensure_terraform_provider_auth(repo_root, context)
    init_rc = run(shared_tf_init_args(context), repo_root, env=context)
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
    tf_cmd.extend(shared_tf_var_args(context))
    return run(tf_cmd, repo_root, env=context)


def deploy_user(repo_root: Path, env_name: str, user: str, plan: bool) -> int:
    context = _prepare_env(repo_root, env_name, user)
    ensure_terraform_provider_auth(repo_root, context)
    return deploy_user_direct(repo_root, env_name, user, plan)


def remove_user(repo_root: Path, env_name: str, user: str) -> int:
    context = _prepare_env(repo_root, env_name, user)
    ensure_terraform_provider_auth(repo_root, context)
    return remove_user_direct(repo_root, env_name, user)


def import_user(
    repo_root: Path,
    env_name: str,
    user: str,
    resource_address: str,
    azure_resource_id: str,
) -> int:
    context = _prepare_env(repo_root, env_name, user)
    ensure_terraform_provider_auth(repo_root, context)
    return import_user_direct(
        repo_root,
        env_name,
        user,
        resource_address,
        azure_resource_id,
    )
