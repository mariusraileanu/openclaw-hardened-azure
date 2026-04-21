#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from copy import deepcopy
from pathlib import Path


FEATURE_ENV_VAR = "OPENCLAW_FEATURES_JSON"
LIST_MERGE_KEYS = {
    ("profiles",),
    ("boards", "enabled"),
    ("skills", "baseWorkspace", "allow"),
    ("skills", "chairman", "allow"),
    ("skills", "members", "allow"),
    ("plugins", "enable"),
    ("plugins", "disable"),
}


def _merge_dict(base: dict, overlay: dict, path: tuple[str, ...] = ()) -> dict:
    merged = deepcopy(base)
    for key, value in overlay.items():
        child_path = path + (key,)
        if isinstance(value, list) and child_path in LIST_MERGE_KEYS:
            existing = merged.get(key, [])
            if not isinstance(existing, list):
                existing = []
            merged[key] = existing + deepcopy(value)
        elif isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = _merge_dict(merged[key], value, child_path)
        else:
            merged[key] = deepcopy(value)
    return merged


def _read_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def _default_feature_config() -> dict:
    return {
        "version": 1,
        "profiles": [],
        "boards": {"enabled": []},
        "skills": {
            "baseWorkspace": {"allow": []},
            "chairman": {"allow": []},
            "members": {"allow": []},
        },
        "plugins": {"enable": [], "disable": []},
    }


def _normalize_list(items: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for item in items:
        if not isinstance(item, str):
            continue
        trimmed = item.strip()
        if not trimmed or trimmed in seen:
            continue
        seen.add(trimmed)
        result.append(trimmed)
    return result


def normalize_feature_config(raw: dict) -> dict:
    merged = _merge_dict(_default_feature_config(), raw)

    boards = merged["boards"]
    boards["enabled"] = _normalize_list(boards.get("enabled", []))

    skills = merged["skills"]
    for role in ["baseWorkspace", "chairman", "members"]:
        allow = skills.get(role, {}).get("allow", [])
        skills[role] = {"allow": _normalize_list(allow)}

    plugins = merged["plugins"]
    plugins["enable"] = _normalize_list(plugins.get("enable", []))
    plugins["disable"] = _normalize_list(plugins.get("disable", []))

    return merged


def _load_overlay(path: Path) -> dict:
    payload = _read_json(path)
    if not isinstance(payload, dict):
        raise ValueError(f"Feature overlay must be a JSON object: {path}")
    return payload


def _record_explicit_keys(explicit: dict, payload: dict) -> None:
    if "boards" in payload:
        explicit["boards"] = True
    if "plugins" in payload:
        explicit["plugins"] = True
    skills = payload.get("skills")
    if isinstance(skills, dict):
        explicit.setdefault("skills", {})
        for role in ["baseWorkspace", "chairman", "members"]:
            if role in skills:
                explicit["skills"][role] = True


def _load_profiles(repo_root: Path, profiles: list[str]) -> list[dict]:
    overlays: list[dict] = []
    for profile in profiles:
        profile_path = (
            repo_root / "config" / "features" / "profiles" / f"{profile}.json"
        )
        if not profile_path.exists():
            raise FileNotFoundError(f"Feature profile not found: {profile_path}")
        overlays.append(_load_overlay(profile_path))
    return overlays


def load_feature_config(
    repo_root: Path, env_name: str, user: str | None = None
) -> dict:
    merged = _default_feature_config()
    explicit: dict = {"boards": False, "plugins": False, "skills": {}}
    overlays: list[dict] = []

    default_path = repo_root / "config" / "features" / "default.json"
    if default_path.exists():
        overlays.append(_load_overlay(default_path))

    if user:
        user_path = repo_root / "config" / "users" / f"{user}.features.json"
        if user_path.exists():
            overlays.append(_load_overlay(user_path))

        local_user_path = (
            repo_root / "config" / "local" / f"{env_name}.{user}.features.json"
        )
        if local_user_path.exists():
            overlays.append(_load_overlay(local_user_path))

    raw_env_payload = os.environ.get(FEATURE_ENV_VAR, "").strip()
    if raw_env_payload:
        env_overlay = json.loads(raw_env_payload)
        if not isinstance(env_overlay, dict):
            raise ValueError(f"{FEATURE_ENV_VAR} must be a JSON object")
        overlays.append(env_overlay)

    profiles: list[str] = []
    for overlay in overlays:
        profiles.extend(
            item for item in overlay.get("profiles", []) if isinstance(item, str)
        )
    profiles = _normalize_list(profiles)

    for profile_overlay in _load_profiles(repo_root, profiles):
        _record_explicit_keys(explicit, profile_overlay)
        merged = _merge_dict(merged, profile_overlay)

    for overlay in overlays:
        _record_explicit_keys(explicit, overlay)
        merged = _merge_dict(merged, overlay)

    merged["profiles"] = profiles
    merged["_explicit"] = explicit

    return normalize_feature_config(merged)


def feature_boards_or_env(feature_config: dict, fallback_csv: callable) -> list[str]:
    if feature_config.get("_explicit", {}).get("boards"):
        return feature_config.get("boards", {}).get("enabled", [])
    boards = feature_config.get("boards", {}).get("enabled", [])
    return boards if boards else fallback_csv("OPENCLAW_BOARDS")


def skill_allowlist(feature_config: dict, role: str) -> list[str] | None:
    if not feature_config.get("_explicit", {}).get("skills", {}).get(role):
        return None
    return feature_config.get("skills", {}).get(role, {}).get("allow", [])


def plugins_explicitly_configured(feature_config: dict) -> bool:
    return bool(feature_config.get("_explicit", {}).get("plugins"))
