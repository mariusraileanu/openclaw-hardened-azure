from __future__ import annotations

from pathlib import Path

from env_loader import load_layered_env
from naming import resolve_and_validate_naming
from runner import run


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
