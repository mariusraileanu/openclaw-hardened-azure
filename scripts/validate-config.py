#!/usr/bin/env python3
import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse


BOOL_TRUE = {"1", "true", "yes", "on"}
BOOL_FALSE = {"0", "false", "no", "off"}
E164_RE = re.compile(r"^\+[1-9][0-9]{7,14}$")


def fatal(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line_no, raw in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        if "=" not in line:
            fatal(f"{path}:{line_no}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            fatal(f"{path}:{line_no}: empty key")
        values[key] = value
    return values


def is_non_empty(values: dict[str, str], key: str) -> bool:
    value = values.get(key)
    return value is not None and value.strip() != ""


def validate_value(
    name: str, value: str, var_type: str, allowed: list[str] | None
) -> str | None:
    trimmed = value.strip()
    if var_type in {"string", "secret"}:
        return None

    if var_type == "bool":
        if trimmed.lower() not in BOOL_TRUE | BOOL_FALSE:
            return f"{name} must be a boolean (one of: 1,0,true,false,yes,no,on,off)"
        return None

    if var_type == "enum":
        if not allowed:
            return f"{name} has enum type but no allowed values in schema"
        if trimmed not in allowed:
            return f"{name} must be one of: {', '.join(allowed)}"
        return None

    if var_type == "url":
        parsed = urlparse(trimmed)
        if not parsed.scheme or not parsed.netloc:
            return f"{name} must be a valid URL"
        return None

    if var_type == "e164":
        if not E164_RE.match(trimmed):
            return f"{name} must be E.164 format (example: +15551234567)"
        return None

    if var_type == "json_object":
        try:
            payload = json.loads(trimmed)
        except json.JSONDecodeError as exc:
            return f"{name} must be valid JSON object: {exc.msg}"
        if not isinstance(payload, dict):
            return f"{name} must be a JSON object"
        return None

    return f"{name} uses unsupported schema type: {var_type}"


def validate_scope(
    values: dict[str, str],
    schema_entries: list[dict],
    scope_name: str,
    strict_unknown: bool,
) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []

    names = {entry["name"] for entry in schema_entries}

    for entry in schema_entries:
        name = entry["name"]
        if entry.get("required") and not is_non_empty(values, name):
            errors.append(f"[{scope_name}] missing required variable: {name}")

    for key, value in values.items():
        if key not in names:
            msg = f"[{scope_name}] unknown variable: {key}"
            if strict_unknown:
                errors.append(msg)
            else:
                warnings.append(msg)
            continue

        entry = next(item for item in schema_entries if item["name"] == key)
        if value.strip() == "":
            continue
        err = validate_value(
            key, value, entry.get("type", "string"), entry.get("allowed")
        )
        if err:
            errors.append(f"[{scope_name}] {err}")

    return errors, warnings


def cross_checks(shared: dict[str, str], user: dict[str, str] | None) -> list[str]:
    errors: list[str] = []

    teams_shared = all(
        shared.get(name, "").strip()
        for name in ["MSTEAMS_TENANT_ID", "MSTEAMS_APP_ID", "MSTEAMS_APP_SECRET_VALUE"]
    )

    if (
        user
        and user.get("MSTEAMS_ENABLED", "").strip().lower() in BOOL_TRUE
        and not teams_shared
    ):
        errors.append(
            "[cross] MSTEAMS_ENABLED=true requires shared MSTEAMS_TENANT_ID, "
            "MSTEAMS_APP_ID, and MSTEAMS_APP_SECRET_VALUE"
        )

    signal_user_set = bool(user and user.get("SIGNAL_USER_PHONE", "").strip())
    signal_bot_set = bool(shared.get("SIGNAL_BOT_NUMBER", "").strip())
    if signal_user_set and not signal_bot_set:
        errors.append(
            "[cross] SIGNAL_USER_PHONE is set but SIGNAL_BOT_NUMBER is missing in shared env"
        )

    return errors


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Validate OpenClaw env files against typed schema"
    )
    parser.add_argument("--env", default="dev", help="Environment name (default: dev)")
    parser.add_argument("--user", help="User slug to validate config/users/<slug>.env")
    parser.add_argument("--shared-file", help="Override shared env file path")
    parser.add_argument("--user-file", help="Override user env file path")
    parser.add_argument("--schema", default="config/schema.json", help="Schema path")
    parser.add_argument(
        "--env-dir", default="config/env", help="Environment config directory"
    )
    parser.add_argument(
        "--users-dir", default="config/users", help="User config directory"
    )
    parser.add_argument(
        "--local-dir", default="config/local", help="Local override directory"
    )
    parser.add_argument(
        "--strict-unknown", action="store_true", help="Fail on unknown keys"
    )
    args = parser.parse_args()

    schema_path = Path(args.schema)
    if not schema_path.exists():
        fatal(f"Schema not found: {schema_path}")

    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    variables = schema.get("variables")
    if not isinstance(variables, list):
        fatal("Schema is invalid: missing 'variables' list")

    shared_schema = [entry for entry in variables if entry.get("scope") == "shared"]
    user_schema = [entry for entry in variables if entry.get("scope") == "user"]

    shared_paths: list[Path] = []
    if args.shared_file:
        shared_paths = [Path(args.shared_file)]
    else:
        shared_paths = [
            Path(args.env_dir) / f"{args.env}.env",
            Path(args.local_dir) / f"{args.env}.env",
        ]

    shared_values: dict[str, str] = {}
    shared_scope_name = ", ".join(str(path) for path in shared_paths)
    loaded_shared = 0
    for shared_path in shared_paths:
        if shared_path.exists():
            shared_values.update(parse_env_file(shared_path))
            loaded_shared += 1
    if loaded_shared == 0:
        fatal(
            "Shared env files not found. Expected one of: "
            + ", ".join(str(path) for path in shared_paths)
        )

    user_values: dict[str, str] | None = None
    user_scope_name: str | None = None
    if args.user:
        user_paths: list[Path] = []
        if args.user_file:
            user_paths = [Path(args.user_file)]
        else:
            user_paths = [
                Path(args.users_dir) / f"{args.user}.env",
                Path(args.local_dir) / f"{args.env}.{args.user}.env",
            ]

        user_values = {}
        user_scope_name = ", ".join(str(path) for path in user_paths)
        loaded_user = 0
        for user_path in user_paths:
            if user_path.exists():
                user_values.update(parse_env_file(user_path))
                loaded_user += 1
        if loaded_user == 0:
            fatal(
                "User env files not found. Expected one of: "
                + ", ".join(str(path) for path in user_paths)
            )

    errors, warnings = validate_scope(
        values=shared_values,
        schema_entries=shared_schema,
        scope_name=shared_scope_name,
        strict_unknown=args.strict_unknown,
    )

    if user_values is not None and user_scope_name is not None:
        user_errors, user_warnings = validate_scope(
            values=user_values,
            schema_entries=user_schema,
            scope_name=user_scope_name,
            strict_unknown=args.strict_unknown,
        )
        errors.extend(user_errors)
        warnings.extend(user_warnings)
        errors.extend(cross_checks(shared_values, user_values))

    for warning in warnings:
        print(f"WARNING: {warning}")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)

    if user_scope_name:
        print(
            f"Config validation passed for [{shared_scope_name}] + [{user_scope_name}]"
        )
    else:
        print(f"Config validation passed for [{shared_scope_name}]")


if __name__ == "__main__":
    main()
