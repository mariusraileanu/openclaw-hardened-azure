from __future__ import annotations

from pathlib import Path


def parse_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def load_layered_env(
    repo_root: Path,
    env_name: str,
    user: str | None = None,
    require_user_file: bool = False,
) -> tuple[dict[str, str], list[Path]]:
    env_path = repo_root / "config" / "env" / f"{env_name}.env"
    local_env_path = repo_root / "config" / "local" / f"{env_name}.env"

    if not env_path.exists():
        raise FileNotFoundError(
            f"Missing {env_path.relative_to(repo_root)} (run: ocp config bootstrap --env {env_name})"
        )

    paths: list[Path] = [env_path]
    if local_env_path.exists():
        paths.append(local_env_path)

    if user:
        user_path = repo_root / "config" / "users" / f"{user}.env"
        local_user_path = repo_root / "config" / "local" / f"{env_name}.{user}.env"
        if require_user_file and not user_path.exists():
            raise FileNotFoundError(
                f"Missing {user_path.relative_to(repo_root)} (run: ocp config bootstrap --env {env_name} --user {user})"
            )
        if user_path.exists():
            paths.append(user_path)
        if local_user_path.exists():
            paths.append(local_user_path)

    merged: dict[str, str] = {}
    for path in paths:
        merged.update(parse_env_file(path))
    return merged, paths
