from __future__ import annotations

from pathlib import Path

from env_loader import load_layered_env
from naming import resolve_and_validate_naming
from runner import run


def reset(
    repo_root: Path,
    env_name: str,
    force: bool,
    nuke_only: bool,
    rebuild_only: bool,
) -> int:
    env_map, _ = load_layered_env(repo_root, env_name, require_user_file=False)
    resolve_and_validate_naming(repo_root, env_map, env_name)

    command = ["./platform-reset.sh", "-e", env_name]
    if force:
        command.append("-f")
    if nuke_only:
        command.append("--nuke-only")
    if rebuild_only:
        command.append("--rebuild-only")
    return run(command, repo_root)
