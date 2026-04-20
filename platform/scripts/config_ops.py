from __future__ import annotations

from pathlib import Path


def bootstrap_config(repo_root: Path, env_name: str, user: str | None) -> int:
    env_dir = repo_root / "config" / "env"
    users_dir = repo_root / "config" / "users"
    local_dir = repo_root / "config" / "local"

    env_dir.mkdir(parents=True, exist_ok=True)
    users_dir.mkdir(parents=True, exist_ok=True)
    local_dir.mkdir(parents=True, exist_ok=True)

    env_file = env_dir / f"{env_name}.env"
    env_template = env_dir / f"{env_name}.example.env"
    if not env_file.exists() and env_template.exists():
        env_file.write_text(env_template.read_text(encoding="utf-8"), encoding="utf-8")
        print(f"Created {env_file.relative_to(repo_root)} from template")

    local_file = local_dir / f"{env_name}.env"
    local_template = local_dir / f"{env_name}.example.env"
    if not local_file.exists() and local_template.exists():
        local_file.write_text(
            local_template.read_text(encoding="utf-8"), encoding="utf-8"
        )
        print(f"Created {local_file.relative_to(repo_root)} from template")

    if user:
        user_file = users_dir / f"{user}.env"
        user_template = users_dir / "user.example.env"
        if not user_file.exists() and user_template.exists():
            user_file.write_text(
                user_template.read_text(encoding="utf-8"), encoding="utf-8"
            )
            print(f"Created {user_file.relative_to(repo_root)} from template")

        user_features_file = users_dir / f"{user}.features.json"
        user_features_template = users_dir / "user.features.example.json"
        if not user_features_file.exists() and user_features_template.exists():
            user_features_file.write_text(
                user_features_template.read_text(encoding="utf-8"), encoding="utf-8"
            )
            print(f"Created {user_features_file.relative_to(repo_root)} from template")

        local_user_features_file = local_dir / f"{env_name}.{user}.features.json"
        local_user_features_template = (
            local_dir / f"{env_name}.user.features.example.json"
        )
        if (
            not local_user_features_file.exists()
            and local_user_features_template.exists()
        ):
            local_user_features_file.write_text(
                local_user_features_template.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            print(
                f"Created {local_user_features_file.relative_to(repo_root)} from template"
            )

    return 0
