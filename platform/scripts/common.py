"""Shared helpers used across platform/scripts/ operation modules.

Extracted to eliminate ~200+ lines of copy-paste duplication across
user_deploy_ops.py, signal_ops.py, teams_ops.py, and deploy_ops.py.
"""

from __future__ import annotations

from pathlib import Path

from runner import run, run_capture, run_quiet


# ---------------------------------------------------------------------------
# Required config keys validated before any deployment
# ---------------------------------------------------------------------------

REQUIRED_SHARED_KEYS = [
    "AZURE_LOCATION",
    "COMPASS_API_KEY",
    "OPENCLAW_GATEWAY_AUTH_TOKEN",
]


def ensure_shared_requirements(env_map: dict[str, str]) -> None:
    missing = [key for key in REQUIRED_SHARED_KEYS if not env_map.get(key)]
    if missing:
        raise RuntimeError(
            "Missing required shared config keys: "
            + ", ".join(missing)
            + " (set them in config/env/<env>.env or config/local/<env>.env)"
        )


# ---------------------------------------------------------------------------
# Azure / Terraform auth checks
# ---------------------------------------------------------------------------


def has_active_az_session(repo_root: Path, context: dict[str, str]) -> bool:
    return (
        run_quiet(["az", "account", "show", "--output", "none"], repo_root, env=context)
        == 0
    )


def ensure_terraform_provider_auth(repo_root: Path, context: dict[str, str]) -> None:
    rc = run_quiet(
        ["terraform", "-chdir=infra/shared", "providers", "schema", "-json"],
        repo_root,
        env=context,
    )
    if rc != 0:
        raise RuntimeError(
            "Terraform provider auth check failed. Refresh Azure auth (az logout && az login) and retry."
        )


# ---------------------------------------------------------------------------
# IP discovery
# ---------------------------------------------------------------------------


def discover_deployer_ips(repo_root: Path) -> str:
    script = (
        "collect() { "
        "  for url in "
        "    https://ifconfig.me "
        "    https://api.ipify.org "
        "    https://checkip.amazonaws.com "
        "    https://icanhazip.com; do "
        "    curl -4fsS --connect-timeout 5 --max-time 10 \"$url\" 2>/dev/null || true; "
        "    printf '\\n'; "
        "  done; "
        "}; "
        "{ collect; collect; } | "
        "tr -d '\\r' | "
        "grep -E '^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$' | "
        "awk '!seen[$0]++' | paste -sd, -"
    )
    return run_capture(["bash", "-lc", script], repo_root)


# ---------------------------------------------------------------------------
# NFS storage account resolution & firewall
# ---------------------------------------------------------------------------


def resolve_nfs_storage_account(repo_root: Path, context: dict[str, str]) -> str:
    rg = context.get("AZURE_RESOURCE_GROUP", "")
    configured = context.get("NFS_SA_NAME", "")
    if configured:
        rc = run_quiet(
            [
                "az",
                "storage",
                "account",
                "show",
                "--name",
                configured,
                "--resource-group",
                rg,
                "--output",
                "none",
            ],
            repo_root,
            env=context,
        )
        if rc == 0:
            return configured

    try:
        discovered = run_capture(
            [
                "terraform",
                "-chdir=infra/shared",
                "output",
                "-json",
                "nfs_storage_account_name",
            ],
            repo_root,
            env=context,
        ).strip('"')
    except Exception:
        discovered = ""

    if discovered:
        rc = run_quiet(
            [
                "az",
                "storage",
                "account",
                "show",
                "--name",
                discovered,
                "--resource-group",
                rg,
                "--output",
                "none",
            ],
            repo_root,
            env=context,
        )
        if rc == 0:
            return discovered

    raise RuntimeError(
        "Could not resolve accessible NFS storage account. "
        "Set NFS_SA_NAME in config/env/<env>.env or ensure infra/shared output nfs_storage_account_name is available."
    )


def open_nfs_firewall(repo_root: Path, context: dict[str, str]) -> None:
    rg = context.get("AZURE_RESOURCE_GROUP", "")
    nfs_sa = resolve_nfs_storage_account(repo_root, context)
    run(
        [
            "az",
            "storage",
            "account",
            "update",
            "--name",
            nfs_sa,
            "--resource-group",
            rg,
            "--default-action",
            "Allow",
            "--output",
            "none",
        ],
        repo_root,
        env=context,
    )
    run(["sleep", "15"], repo_root, env=context)


def close_nfs_firewall(repo_root: Path, context: dict[str, str]) -> None:
    rg = context.get("AZURE_RESOURCE_GROUP", "")
    nfs_sa = resolve_nfs_storage_account(repo_root, context)
    run(
        [
            "az",
            "storage",
            "account",
            "update",
            "--name",
            nfs_sa,
            "--resource-group",
            rg,
            "--default-action",
            "Deny",
            "--output",
            "none",
        ],
        repo_root,
        env=context,
    )


# ---------------------------------------------------------------------------
# Shared Terraform argument builders (infra/shared)
# ---------------------------------------------------------------------------


def shared_tf_init_args(context: dict[str, str]) -> list[str]:
    backend_override_path = (
        Path(__file__).resolve().parents[2] / "infra" / "shared" / "backend_override.tf"
    )
    if (
        backend_override_path.exists()
        and 'backend "local"' in backend_override_path.read_text(encoding="utf-8")
    ):
        return ["terraform", "-chdir=infra/shared", "init"]

    return [
        "terraform",
        "-chdir=infra/shared",
        "init",
        "-backend-config",
        f"resource_group_name={context.get('TF_STATE_RG', '')}",
        "-backend-config",
        f"storage_account_name={context.get('TF_STATE_SA', '')}",
        "-backend-config",
        f"key={context.get('TF_STATE_KEY', '')}",
    ]


def shared_tf_var_args(
    context: dict[str, str], *, deployer_ips: str | None = None
) -> list[str]:
    args = [
        "-var",
        f"environment={context.get('AZURE_ENVIRONMENT', '')}",
        "-var",
        f"location={context.get('AZURE_LOCATION', '')}",
        "-var",
        f"owner_slug={context.get('AZURE_OWNER_SLUG', 'platform')}",
        "-var",
        f"cae_internal_only={context.get('CAE_INTERNAL_ONLY', 'true')}",
        "-var",
        f"msteams_relay_enabled={context.get('MSTEAMS_RELAY_ENABLED', 'false')}",
        "-var",
        f"msteams_app_id={context.get('MSTEAMS_APP_ID', '')}",
        "-var",
        f"msteams_app_secret_value={context.get('MSTEAMS_APP_SECRET_VALUE', '')}",
        "-var",
        f"msteams_tenant_id={context.get('MSTEAMS_TENANT_ID', '')}",
        "-var",
        f"acr_name={context.get('ACR_NAME', '')}",
        "-var",
        f"sa_name={context.get('SA_NAME', '')}",
        "-var",
        f"func_relay_name={context.get('FUNC_RELAY_NAME', '')}",
        "-var",
        f"bot_name={context.get('BOT_NAME', '')}",
    ]
    if deployer_ips is not None:
        args.extend(["-var", f"deployer_ips={deployer_ips}"])
    return args
