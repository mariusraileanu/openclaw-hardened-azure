from __future__ import annotations

import os
import subprocess
from pathlib import Path


NAMING_EXPORT_KEYS = [
    "AZURE_RESOURCE_GROUP",
    "AZURE_CONTAINERAPPS_ENV",
    "AZURE_ACR_NAME",
    "AZURE_KEY_VAULT_NAME",
    "NFS_SA_NAME",
    "CAE_NFS_STORAGE_NAME",
    "TF_STATE_RG",
    "TF_STATE_SA",
    "TF_STATE_KEY",
    "ACR_NAME",
    "SA_NAME",
    "FUNC_RELAY_NAME",
]


def resolve_and_validate_naming(
    repo_root: Path, env_map: dict[str, str], env_name: str
) -> dict[str, str]:
    script = repo_root / "scripts" / "naming-contract.sh"
    if not script.exists():
        raise FileNotFoundError(f"Missing naming contract script: {script}")

    run_env = os.environ.copy()
    run_env.update(env_map)
    run_env["ENV_NAME"] = env_name

    validate = subprocess.run(
        [str(script), "validate"],
        cwd=repo_root,
        env=run_env,
        text=True,
    )
    if validate.returncode != 0:
        raise RuntimeError("Naming contract validation failed")

    export_proc = subprocess.run(
        [str(script), "export"],
        cwd=repo_root,
        env=run_env,
        text=True,
        capture_output=True,
        check=True,
    )

    resolved: dict[str, str] = {}
    for raw in export_proc.stdout.splitlines():
        line = raw.strip()
        if not line.startswith("export ") or "=" not in line:
            continue
        payload = line[len("export ") :]
        key, value = payload.split("=", 1)
        key = key.strip()
        value = value.strip().strip("'").strip('"')
        if key in NAMING_EXPORT_KEYS:
            resolved[key] = value

    return resolved
