from __future__ import annotations

import shutil
from pathlib import Path

from env_loader import load_layered_env
from naming import resolve_and_validate_naming
from runner import run, run_quiet


def _check_binary(name: str) -> bool:
    return shutil.which(name) is not None


def _print_result(ok: bool, label: str, details: str = "") -> None:
    status = "PASS" if ok else "FAIL"
    suffix = f" ({details})" if details else ""
    print(f"[{status}] {label}{suffix}")


def _print_warn(label: str, details: str = "") -> None:
    suffix = f" ({details})" if details else ""
    print(f"[WARN] {label}{suffix}")


def doctor(repo_root: Path, env_name: str, user: str | None) -> int:
    print(
        f"▸ Running platform doctor for env={env_name}{f' user={user}' if user else ''}"
    )

    failures = 0

    required_bins = ["az", "terraform", "bash"]
    optional_bins = ["docker", "node", "npm", "func"]

    for binary in required_bins:
        ok = _check_binary(binary)
        _print_result(ok, f"binary '{binary}' is available")
        if not ok:
            failures += 1

    for binary in optional_bins:
        ok = _check_binary(binary)
        if ok:
            _print_result(True, f"optional binary '{binary}' is available")
        else:
            _print_warn(f"optional binary '{binary}' is missing")

    az_ok = run_quiet(["az", "account", "show", "--output", "none"], repo_root) == 0
    _print_result(az_ok, "Azure CLI session is active")
    if not az_ok:
        failures += 1

    try:
        env_map, paths = load_layered_env(
            repo_root=repo_root,
            env_name=env_name,
            user=user,
            require_user_file=bool(user),
        )
        _print_result(
            True,
            "Layered config files loaded",
            ", ".join(str(path.relative_to(repo_root)) for path in paths),
        )
    except FileNotFoundError as exc:
        _print_result(False, "Layered config files loaded", str(exc))
        failures += 1
        env_map = {}

    if env_map:
        try:
            resolved = resolve_and_validate_naming(repo_root, env_map, env_name)
            env_map.update(resolved)
            _print_result(True, "Naming contract validation")
        except (FileNotFoundError, RuntimeError, Exception) as exc:
            _print_result(False, "Naming contract validation", str(exc))
            failures += 1

    validate_cmd = ["./platform/scripts/validate_config.py", "--env", env_name]
    if user:
        validate_cmd.extend(["--user", user])
    validate_ok = run(validate_cmd, repo_root) == 0
    _print_result(validate_ok, "Typed config schema validation")
    if not validate_ok:
        failures += 1

    if env_map:
        env_map["AZURE_ENVIRONMENT"] = env_name
        provider_ok = (
            run_quiet(
                ["terraform", "-chdir=infra/shared", "providers", "schema", "-json"],
                repo_root,
                env=env_map,
            )
            == 0
        )
        _print_result(provider_ok, "Terraform provider auth check")
        if not provider_ok:
            failures += 1

    if failures:
        print(f"Doctor finished with {failures} failure(s).")
        return 1

    print("Doctor passed.")
    return 0
