#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def fatal(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_json(path: Path) -> dict:
    try:
        with path.open("r", encoding="utf-8") as f:
            payload = json.load(f)
    except FileNotFoundError:
        fatal(f"Missing feature file: {path}")
    except json.JSONDecodeError as exc:
        fatal(f"Invalid JSON in {path}: {exc.msg}")
    if not isinstance(payload, dict):
        fatal(f"Feature file must contain a JSON object: {path}")
    return payload


def list_board_ids(repo_root: Path) -> set[str]:
    board_dir = repo_root / "config" / "boards"
    return {path.stem for path in board_dir.glob("*.json")}


def list_skill_ids(repo_root: Path) -> set[str]:
    skills_dir = repo_root / "workspace" / "skills"
    return (
        {path.name for path in skills_dir.iterdir() if path.is_dir()}
        if skills_dir.exists()
        else set()
    )


def list_plugin_ids(repo_root: Path) -> set[str]:
    template_path = repo_root / "config" / "openclaw.json.template"
    if not template_path.exists():
        return set()
    payload = read_json(template_path)
    entries = payload.get("plugins", {}).get("entries", {})
    known = set(entries.keys())
    known.add("tavily")
    return known


def list_profile_ids(repo_root: Path) -> set[str]:
    profile_dir = repo_root / "config" / "features" / "profiles"
    if not profile_dir.exists():
        return set()
    return {path.stem for path in profile_dir.glob("*.json")}


def merge_dict(base: dict, overlay: dict) -> dict:
    merged = dict(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = merge_dict(merged[key], value)
        else:
            merged[key] = value
    return merged


def load_profiles(repo_root: Path, profiles: list[str]) -> list[tuple[str, dict]]:
    loaded: list[tuple[str, dict]] = []
    for profile in profiles:
        path = repo_root / "config" / "features" / "profiles" / f"{profile}.json"
        loaded.append((str(path.relative_to(repo_root)), read_json(path)))
    return loaded


def validate_feature_payload(
    payload: dict,
    *,
    board_ids: set[str],
    skill_ids: set[str],
    plugin_ids: set[str],
    profile_ids: set[str],
    label: str,
) -> list[str]:
    errors: list[str] = []

    if payload.get("version") != 1:
        errors.append(f"[{label}] version must be 1")

    profiles = payload.get("profiles", [])
    if not isinstance(profiles, list):
        errors.append(f"[{label}] profiles must be an array")
        profiles = []
    for profile in profiles:
        if profile not in profile_ids:
            errors.append(f"[{label}] unknown profile: {profile}")

    boards = payload.get("boards", {})
    enabled_boards = boards.get("enabled", [])
    if not isinstance(enabled_boards, list):
        errors.append(f"[{label}] boards.enabled must be an array")
        enabled_boards = []
    for board in enabled_boards:
        if board not in board_ids:
            errors.append(f"[{label}] unknown board: {board}")

    skills = payload.get("skills", {})
    for role in ["baseWorkspace", "chairman", "members"]:
        allow = skills.get(role, {}).get("allow", [])
        if not isinstance(allow, list):
            errors.append(f"[{label}] skills.{role}.allow must be an array")
            continue
        for skill in allow:
            if skill not in skill_ids and skill not in {
                "board-deliberation",
                "board-meeting-execution",
            }:
                errors.append(
                    f"[{label}] unknown skill in skills.{role}.allow: {skill}"
                )

    plugins = payload.get("plugins", {})
    enable = plugins.get("enable", [])
    disable = plugins.get("disable", [])
    if not isinstance(enable, list):
        errors.append(f"[{label}] plugins.enable must be an array")
        enable = []
    if not isinstance(disable, list):
        errors.append(f"[{label}] plugins.disable must be an array")
        disable = []
    overlap = set(enable) & set(disable)
    if overlap:
        errors.append(
            f"[{label}] plugins.enable/disable overlap: {', '.join(sorted(overlap))}"
        )
    for plugin in set(enable) | set(disable):
        if plugin not in plugin_ids:
            errors.append(f"[{label}] unknown plugin: {plugin}")

    return errors


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate OpenClaw feature manifests")
    parser.add_argument("--env", default="dev")
    parser.add_argument("--user")
    parser.add_argument("--repo-root", default=".")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    board_ids = list_board_ids(repo_root)
    skill_ids = list_skill_ids(repo_root)
    plugin_ids = list_plugin_ids(repo_root)
    profile_ids = list_profile_ids(repo_root)

    default_path = repo_root / "config" / "features" / "default.json"
    merged = read_json(default_path) if default_path.exists() else {}
    errors: list[str] = []

    if default_path.exists():
        errors.extend(
            validate_feature_payload(
                merged,
                board_ids=board_ids,
                skill_ids=skill_ids,
                plugin_ids=plugin_ids,
                profile_ids=profile_ids,
                label=str(default_path.relative_to(repo_root)),
            )
        )

    if args.user:
        user_paths = [
            repo_root / "config" / "users" / f"{args.user}.features.json",
            repo_root / "config" / "local" / f"{args.env}.{args.user}.features.json",
        ]
        found_user_file = False
        for path in user_paths:
            if not path.exists():
                continue
            found_user_file = True
            payload = read_json(path)
            errors.extend(
                validate_feature_payload(
                    payload,
                    board_ids=board_ids,
                    skill_ids=skill_ids,
                    plugin_ids=plugin_ids,
                    profile_ids=profile_ids,
                    label=str(path.relative_to(repo_root)),
                )
            )
            merged = merge_dict(merged, payload)
        if not found_user_file:
            fatal(
                "User feature files not found. Expected one of: "
                + ", ".join(str(path.relative_to(repo_root)) for path in user_paths)
            )

    merged_profiles = merged.get("profiles", [])
    for profile_label, payload in load_profiles(repo_root, merged_profiles):
        errors.extend(
            validate_feature_payload(
                payload,
                board_ids=board_ids,
                skill_ids=skill_ids,
                plugin_ids=plugin_ids,
                profile_ids=profile_ids,
                label=profile_label,
            )
        )

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)

    if args.user:
        print(f"Feature validation passed for env={args.env} user={args.user}")
    else:
        print(f"Feature validation passed for env={args.env}")


if __name__ == "__main__":
    main()
