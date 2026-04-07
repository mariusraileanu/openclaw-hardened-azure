from __future__ import annotations

import json
import re
from pathlib import Path

from common import discover_deployer_ips
from env_loader import load_layered_env
from naming import resolve_and_validate_naming
from runner import run, run_capture


CANONICAL_OID_SECRET_SUFFIX = "-entra-object-id"
LEGACY_OID_SECRET_SUFFIX = "-graph-mcp-object-id"


def _prepare_context(repo_root: Path, env_name: str) -> dict[str, str]:
    env_map, _ = load_layered_env(repo_root=repo_root, env_name=env_name)
    resolved = resolve_and_validate_naming(repo_root, env_map, env_name)
    env_map.update(resolved)
    env_map["AZURE_ENVIRONMENT"] = env_name
    return env_map


def _kv_secret_get(
    repo_root: Path, context: dict[str, str], secret_name: str
) -> str | None:
    kv = context.get("AZURE_KEY_VAULT_NAME", "").strip()
    if not kv:
        raise RuntimeError("AZURE_KEY_VAULT_NAME is required")
    try:
        value = run_capture(
            [
                "az",
                "keyvault",
                "secret",
                "show",
                "--vault-name",
                kv,
                "--name",
                secret_name,
                "--query",
                "value",
                "-o",
                "tsv",
            ],
            repo_root,
            env=context,
        ).strip()
        return value or None
    except Exception:
        return None


def _kv_secret_set(
    repo_root: Path, context: dict[str, str], secret_name: str, value: str
) -> None:
    kv = context.get("AZURE_KEY_VAULT_NAME", "").strip()
    if not kv:
        raise RuntimeError("AZURE_KEY_VAULT_NAME is required")
    run_capture(
        [
            "az",
            "keyvault",
            "secret",
            "set",
            "--vault-name",
            kv,
            "--name",
            secret_name,
            "--value",
            value,
            "--output",
            "none",
        ],
        repo_root,
        env=context,
    )


def _resolve_oid_from_slug_upn(
    repo_root: Path, context: dict[str, str], user_slug: str
) -> str:
    upn = f"{user_slug}@doh.gov.ae"
    oid = run_capture(
        [
            "az",
            "ad",
            "user",
            "show",
            "--id",
            upn,
            "--query",
            "id",
            "-o",
            "tsv",
        ],
        repo_root,
        env=context,
    ).strip()
    if not oid:
        raise RuntimeError(f"Could not resolve Entra object ID for {upn}")
    return oid.lower()


def _ensure_expected_oid(
    repo_root: Path,
    context: dict[str, str],
    user_slug: str,
) -> str:
    canonical_secret = f"{user_slug}{CANONICAL_OID_SECRET_SUFFIX}"
    canonical_value = _kv_secret_get(repo_root, context, canonical_secret)
    if canonical_value:
        return canonical_value.strip().lower()

    legacy_secret = f"{user_slug}{LEGACY_OID_SECRET_SUFFIX}"
    legacy_secret_value = _kv_secret_get(repo_root, context, legacy_secret)
    if legacy_secret_value:
        normalized = legacy_secret_value.strip().lower()
        try:
            _kv_secret_set(repo_root, context, canonical_secret, normalized)
            print(f"  ↳ seeded {canonical_secret} from legacy secret")
        except Exception as exc:
            print(
                f"  ↳ warning: failed to write {canonical_secret} ({exc}); continuing with resolved value"
            )
        return normalized

    looked_up = _resolve_oid_from_slug_upn(repo_root, context, user_slug)
    try:
        _kv_secret_set(repo_root, context, canonical_secret, looked_up)
        print(f"  ↳ created {canonical_secret} from Entra lookup")
    except Exception as exc:
        print(
            f"  ↳ warning: failed to write {canonical_secret} ({exc}); using Entra lookup result"
        )
    return looked_up


def _open_key_vault_firewall(
    repo_root: Path, context: dict[str, str], deployer_ips: str
) -> None:
    rg = context.get("AZURE_RESOURCE_GROUP", "")
    kv = context.get("AZURE_KEY_VAULT_NAME", "")
    if not kv:
        return
    for ip in [p.strip() for p in deployer_ips.split(",") if p.strip()]:
        run(
            [
                "az",
                "keyvault",
                "network-rule",
                "add",
                "--name",
                kv,
                "--resource-group",
                rg,
                "--ip-address",
                f"{ip}/32",
                "--output",
                "none",
            ],
            repo_root,
            env=context,
        )


def _close_key_vault_firewall(
    repo_root: Path, context: dict[str, str], deployer_ips: str
) -> None:
    rg = context.get("AZURE_RESOURCE_GROUP", "")
    kv = context.get("AZURE_KEY_VAULT_NAME", "")
    if not kv:
        return
    for ip in [p.strip() for p in deployer_ips.split(",") if p.strip()]:
        run(
            [
                "az",
                "keyvault",
                "network-rule",
                "remove",
                "--name",
                kv,
                "--resource-group",
                rg,
                "--ip-address",
                f"{ip}/32",
                "--output",
                "none",
            ],
            repo_root,
            env=context,
        )


def _extract_auth_status_json(exec_stdout: str) -> dict[str, object] | None:
    match = re.search(r'(\{"graph":\{[^\n]*\}\})', exec_stdout)
    if not match:
        return None
    try:
        payload = json.loads(match.group(1))
    except Exception:
        return None
    if not isinstance(payload, dict):
        return None
    return payload


def _fetch_gateway_auth_status(
    repo_root: Path, context: dict[str, str], app_name: str
) -> dict[str, object] | None:
    rg = context.get("AZURE_RESOURCE_GROUP", "")
    if not rg:
        raise RuntimeError("AZURE_RESOURCE_GROUP is required")

    output = run_capture(
        [
            "script",
            "-q",
            "/dev/null",
            "az",
            "containerapp",
            "exec",
            "-g",
            rg,
            "-n",
            app_name,
            "--command",
            "curl -s http://localhost:3000/auth/status",
        ],
        repo_root,
        env=context,
    )
    return _extract_auth_status_json(output)


def graph_auth_check(repo_root: Path, env_name: str, users: list[str]) -> int:
    context = _prepare_context(repo_root, env_name)

    if not users:
        raise RuntimeError("At least one --user is required")

    deployer_ips = discover_deployer_ips(repo_root)
    key_vault_opened = False
    if context.get("AZURE_KEY_VAULT_NAME", "") and deployer_ips:
        try:
            _open_key_vault_firewall(repo_root, context, deployer_ips)
            key_vault_opened = True
        except Exception as exc:
            print(f"WARNING: Could not open Key Vault firewall for auth-check: {exc}")

    print(f"▸ Graph auth identity check for env={env_name}")
    print(
        "  slug | gateway_status | auth | reported_user | expected_oid | actual_oid | result"
    )

    failures = 0
    try:
        for raw_user in users:
            user = raw_user.strip().lower()
            expected_oid = _ensure_expected_oid(repo_root, context, user)
            app_name = f"ca-graph-mcp-gw-{env_name}-{user}"

            gateway_status = "unknown"
            try:
                gateway_status = run_capture(
                    [
                        "az",
                        "containerapp",
                        "show",
                        "-n",
                        app_name,
                        "-g",
                        context.get("AZURE_RESOURCE_GROUP", ""),
                        "--query",
                        "properties.runningStatus",
                        "-o",
                        "tsv",
                    ],
                    repo_root,
                    env=context,
                ).strip()
            except Exception:
                gateway_status = "missing"

            reported_user = ""
            auth_state = "unknown"
            actual_oid = ""
            result = "PASS"

            status_payload = None
            if gateway_status.lower() == "running":
                try:
                    status_payload = _fetch_gateway_auth_status(
                        repo_root, context, app_name
                    )
                except Exception:
                    status_payload = None

            if not status_payload:
                auth_state = "unreadable"
                result = "FAIL"
            else:
                graph = status_payload.get("graph")
                if isinstance(graph, dict):
                    authenticated = bool(graph.get("authenticated"))
                    reported_user = str(graph.get("user") or "")
                    auth_state = (
                        "authenticated" if authenticated else "not_authenticated"
                    )

                    if authenticated and reported_user:
                        try:
                            actual_oid = (
                                run_capture(
                                    [
                                        "az",
                                        "ad",
                                        "user",
                                        "show",
                                        "--id",
                                        reported_user,
                                        "--query",
                                        "id",
                                        "-o",
                                        "tsv",
                                    ],
                                    repo_root,
                                    env=context,
                                )
                                .strip()
                                .lower()
                            )
                        except Exception:
                            actual_oid = "lookup_failed"

            if result != "FAIL":
                if not expected_oid:
                    result = "WARN_NO_EXPECTED_OID"
                elif auth_state == "not_authenticated":
                    result = "WARN_LOGIN_REQUIRED"
                elif auth_state == "authenticated":
                    if not actual_oid or actual_oid == "lookup_failed":
                        result = "WARN_ID_LOOKUP_FAILED"
                    elif actual_oid != expected_oid:
                        result = "FAIL_MISMATCH"
                    else:
                        result = "PASS"

            if result.startswith("FAIL"):
                failures += 1

            print(
                " | ".join(
                    [
                        user,
                        gateway_status or "unknown",
                        auth_state,
                        reported_user or "-",
                        expected_oid or "-",
                        actual_oid or "-",
                        result,
                    ]
                )
            )
    finally:
        if key_vault_opened:
            try:
                _close_key_vault_firewall(repo_root, context, deployer_ips)
            except Exception as exc:
                print(
                    f"WARNING: Could not close Key Vault firewall after auth-check: {exc}"
                )

    if failures:
        print(f"Graph auth check finished with {failures} failure(s).")
        return 1

    print("Graph auth check passed (warnings may still require action).")
    return 0
