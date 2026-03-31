#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path


def env_flag(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "on"}


def env_csv(name: str) -> list[str]:
    raw = os.environ.get(name, "")
    return [item.strip() for item in raw.split(",") if item.strip()]


def fatal(message: str) -> None:
    print(f"FATAL: {message}", file=sys.stderr)
    raise SystemExit(1)


def ensure_path(obj: dict, keys: list[str]) -> dict:
    current = obj
    for key in keys:
        value = current.get(key)
        if not isinstance(value, dict):
            value = {}
            current[key] = value
        current = value
    return current


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build deterministic OpenClaw runtime config"
    )
    parser.add_argument("--template", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    template_path = Path(args.template)
    output_path = Path(args.output)

    if not template_path.exists():
        fatal(f"Template not found: {template_path}")

    with template_path.open("r", encoding="utf-8") as f:
        cfg = json.load(f)

    is_azure = bool(os.environ.get("USER_SLUG"))
    force_no_auth = env_flag("OPENCLAW_FORCE_NO_AUTH")

    compass_base_url = os.environ.get("COMPASS_BASE_URL", "https://api.core42.ai/v1")
    compass_api_key = os.environ.get("COMPASS_API_KEY", "").strip()
    if is_azure and not compass_api_key:
        fatal("COMPASS_API_KEY is required in Azure/user mode")

    signal_bot = os.environ.get("SIGNAL_BOT_NUMBER", "").strip()
    signal_user_phone = os.environ.get("SIGNAL_USER_PHONE", "").strip()
    signal_cli_url = os.environ.get("SIGNAL_CLI_URL", "").strip()
    signal_proxy_auth_token = os.environ.get("SIGNAL_PROXY_AUTH_TOKEN", "").strip()

    signal_any = any([signal_bot, signal_user_phone, signal_cli_url])
    signal_ready = all([signal_bot, signal_user_phone, signal_cli_url])
    if is_azure and signal_any and not signal_ready:
        fatal(
            "Signal is partially configured. Set SIGNAL_BOT_NUMBER, SIGNAL_USER_PHONE, and SIGNAL_CLI_URL together."
        )

    signal_http_url = ""
    if signal_ready:
        signal_http_url = f"{signal_cli_url}/user/{signal_user_phone}"
        if signal_proxy_auth_token:
            signal_http_url = f"{signal_http_url}/{signal_proxy_auth_token}"

    teams_app_id = os.environ.get("MSTEAMS_APP_ID", "").strip()
    teams_app_password = os.environ.get("MSTEAMS_APP_PASSWORD", "").strip()
    teams_tenant_id = os.environ.get("MSTEAMS_TENANT_ID", "").strip()

    teams_any = any([teams_app_id, teams_app_password, teams_tenant_id])
    teams_ready = all([teams_app_id, teams_app_password, teams_tenant_id])
    if is_azure and teams_any and not teams_ready:
        fatal(
            "Microsoft Teams is partially configured. Set MSTEAMS_APP_ID, MSTEAMS_APP_PASSWORD, and MSTEAMS_TENANT_ID together."
        )

    if is_azure and not (signal_ready or teams_ready):
        fatal(
            "At least one channel must be configured in Azure/user mode (Signal and/or Microsoft Teams)."
        )

    state_dir = os.environ.get("OPENCLAW_STATE_DIR", "").strip()
    if not state_dir:
        fatal("OPENCLAW_STATE_DIR is required")

    providers = ensure_path(cfg, ["models", "providers"])
    compass = ensure_path(providers, ["compass"])
    compass["baseUrl"] = compass_base_url
    if compass_api_key:
        compass["apiKey"] = compass_api_key
    else:
        compass.pop("apiKey", None)

    defaults = ensure_path(cfg, ["agents", "defaults"])
    defaults["workspace"] = f"{state_dir}/workspace"

    channels = ensure_path(cfg, ["channels"])

    signal = ensure_path(channels, ["signal"])
    if signal_ready:
        signal["enabled"] = True
        signal["account"] = signal_bot
        signal["httpUrl"] = signal_http_url
        signal["autoStart"] = False
        signal["dmPolicy"] = "allowlist"
        signal["allowFrom"] = [signal_user_phone]
    else:
        signal["enabled"] = False
        signal["autoStart"] = False
        signal.pop("account", None)
        signal.pop("dmPolicy", None)
        signal.pop("allowFrom", None)
        signal.pop("httpUrl", None)

    msteams = ensure_path(channels, ["msteams"])
    if teams_ready:
        msteams["enabled"] = True
        msteams["appId"] = teams_app_id
        msteams["appPassword"] = teams_app_password
        msteams["tenantId"] = teams_tenant_id
        webhook = ensure_path(msteams, ["webhook"])
        webhook["port"] = 3978
        webhook["path"] = "/api/messages"
        if "requireMention" not in msteams:
            msteams["requireMention"] = True
        if "replyStyle" not in msteams:
            msteams["replyStyle"] = "thread"
        if is_azure:
            explicit_allow = env_csv("MSTEAMS_ALLOW_FROM")
            if explicit_allow:
                msteams["allowFrom"] = explicit_allow
                msteams["dmPolicy"] = "allowlist"
            else:
                msteams["dmPolicy"] = "open"
                msteams["allowFrom"] = ["*"]
        else:
            allow = msteams.get("allowFrom", [])
            if allow:
                msteams["dmPolicy"] = "allowlist"
            else:
                msteams.pop("dmPolicy", None)
                msteams.pop("allowFrom", None)
    else:
        msteams["enabled"] = False
        for key in ["appId", "appPassword", "tenantId", "dmPolicy", "allowFrom"]:
            msteams.pop(key, None)

    for stale in [
        "welcomeCard",
        "promptStarters",
        "feedbackEnabled",
        "feedbackReflection",
    ]:
        msteams.pop(stale, None)

    gateway = ensure_path(cfg, ["gateway"])
    auth = ensure_path(gateway, ["auth"])

    if force_no_auth:
        auth["mode"] = "none"
        auth.pop("token", None)
    elif is_azure:
        token = os.environ.get("OPENCLAW_GATEWAY_AUTH_TOKEN", "").strip()
        if not token:
            fatal(
                "OPENCLAW_GATEWAY_AUTH_TOKEN is required in Azure/user mode unless OPENCLAW_FORCE_NO_AUTH=true"
            )
        auth["mode"] = "token"
        auth["token"] = token
    else:
        auth["mode"] = "none"
        auth.pop("token", None)

    control_ui = ensure_path(gateway, ["controlUi"])
    if is_azure:
        control_ui["dangerouslyAllowHostHeaderOriginFallback"] = True
        control_ui.pop("dangerouslyDisableDeviceAuth", None)
    else:
        control_ui.pop("dangerouslyAllowHostHeaderOriginFallback", None)
        control_ui.pop("dangerouslyDisableDeviceAuth", None)
    if not control_ui:
        gateway.pop("controlUi", None)

    plugins = ensure_path(cfg, ["plugins", "entries", "tavily"])
    plugins["enabled"] = True
    web_search = ensure_path(plugins, ["config", "webSearch"])
    web_search["baseUrl"] = "https://api.tavily.com"
    tavily_key = os.environ.get("TAVILY_API_KEY", "").strip()
    if tavily_key:
        web_search["apiKey"] = tavily_key
    else:
        web_search.pop("apiKey", None)

    tools_search = ensure_path(cfg, ["tools", "web", "search"])
    tools_search["provider"] = "tavily"

    cfg.pop("instructions", None)

    rendered = json.dumps(cfg, indent=2, sort_keys=True)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(f"{rendered}\n", encoding="utf-8")

    digest = hashlib.sha256(rendered.encode("utf-8")).hexdigest()
    env_label = "azure" if is_azure else "local"
    print(f"Built runtime config [{env_label}] -> {output_path} sha256={digest}")


if __name__ == "__main__":
    main()
