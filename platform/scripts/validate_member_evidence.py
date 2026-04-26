#!/usr/bin/env python3
from __future__ import annotations

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
        fatal(f"Missing member evidence file: {path}")
    except json.JSONDecodeError as exc:
        fatal(f"Invalid JSON in {path}: {exc.msg}")
    if not isinstance(payload, dict):
        fatal(f"Member evidence file must contain a JSON object: {path}")
    return payload


def validate_member_evidence(repo_root: Path) -> None:
    members_dir = repo_root / "config" / "boards" / "members"
    if not members_dir.exists():
        print("No board members directory found; skipping member evidence validation")
        return

    errors: list[str] = []
    for path in sorted(members_dir.glob("*/evidence.json")):
        payload = read_json(path)
        label = str(path.relative_to(repo_root))
        member_id = payload.get("memberId", "")
        if not isinstance(member_id, str) or not member_id.strip():
            errors.append(f"[{label}] memberId must be a non-empty string")
        if path.parent.name != member_id:
            errors.append(f"[{label}] directory name must match memberId")

        summary = payload.get("summary", {})
        if not isinstance(summary, dict):
            errors.append(f"[{label}] summary must be an object")

        sources = payload.get("sources", [])
        if not isinstance(sources, list) or not sources:
            errors.append(f"[{label}] sources must be a non-empty array")
            continue

        seen_ids: set[str] = set()
        for index, source in enumerate(sources):
            source_label = f"{label} source[{index}]"
            if not isinstance(source, dict):
                errors.append(f"[{source_label}] source must be an object")
                continue
            source_id = source.get("id", "")
            if not isinstance(source_id, str) or not source_id.strip():
                errors.append(f"[{source_label}] id must be a non-empty string")
            elif source_id in seen_ids:
                errors.append(f"[{source_label}] duplicate source id: {source_id}")
            else:
                seen_ids.add(source_id)

            source_path_value = source.get("path", "")
            if not isinstance(source_path_value, str) or not source_path_value.strip():
                errors.append(f"[{source_label}] path must be a non-empty string")
                continue
            source_path = repo_root / source_path_value
            if not source_path.exists():
                errors.append(
                    f"[{source_label}] missing source file: {source_path_value}"
                )

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)

    print("Member evidence validation passed")


def main() -> None:
    repo_root = Path(".").resolve()
    validate_member_evidence(repo_root)


if __name__ == "__main__":
    main()
