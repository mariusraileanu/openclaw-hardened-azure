#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

from feature_config import (
    feature_boards_or_env,
    load_feature_config,
    plugins_explicitly_configured,
)


REPO_ROOT = Path(__file__).resolve().parents[2]


def env_flag(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "on"}


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


def env_csv(name: str) -> list[str]:
    raw = os.environ.get(name, "")
    return [item.strip() for item in raw.split(",") if item.strip()]


def resolve_default_path(env_name: str, deployed_path: str, repo_relative: str) -> Path:
    explicit = os.environ.get(env_name, "").strip()
    if explicit:
        return Path(explicit)

    deployed = Path(deployed_path)
    if deployed.exists():
        return deployed

    return REPO_ROOT / repo_relative


def read_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def read_existing_gateway_token(path: Path) -> str | None:
    if not path.exists():
        return None

    try:
        data = read_json(path)
    except (OSError, json.JSONDecodeError):
        return None

    gateway = data.get("gateway")
    if not isinstance(gateway, dict):
        return None

    auth = gateway.get("auth")
    if not isinstance(auth, dict):
        return None

    token = auth.get("token")
    return token if isinstance(token, str) and token.strip() else None


def read_existing_meta(path: Path) -> dict | None:
    candidates = [path, Path(f"{path}.last-good")]
    for candidate in candidates:
        if not candidate.exists():
            continue

        try:
            data = read_json(candidate)
        except (OSError, json.JSONDecodeError):
            continue

        meta = data.get("meta")
        if isinstance(meta, dict):
            return meta

    return None


def resolve_gateway_token(user_slug: str | None, existing_token: str | None) -> str:
    if existing_token:
        return existing_token

    env_token = os.environ.get("OPENCLAW_GATEWAY_AUTH_TOKEN", "").strip()
    if env_token:
        return env_token

    scope = user_slug or "local"
    return hashlib.sha256(f"openclaw-gateway:{scope}".encode("utf-8")).hexdigest()


def build_board_agents(
    state_dir: str, board_dir: Path, board_ids: list[str]
) -> tuple[list[dict], list[str]]:
    agents: list[dict] = []
    allow: list[str] = []

    for board_id in board_ids:
        board_path = board_dir / f"{board_id}.json"
        if not board_path.exists():
            fatal(f"Board definition not found: {board_path}")

        board = read_json(board_path)
        board_slug = board.get("id", board_id)

        chairman_agent_id = f"{board_slug}-chairman"
        agents.append(
            {
                "id": chairman_agent_id,
                "name": board["chairman"]["name"],
                "workspace": f"{state_dir}/workspaces/{board_slug}/chairman",
                "agentDir": f"{state_dir}/agents/{chairman_agent_id}/agent",
            }
        )
        allow.append(chairman_agent_id)

        for member in board.get("members", []):
            member_agent_id = f"{board_slug}-{member['id']}"
            agents.append(
                {
                    "id": member_agent_id,
                    "name": member["name"],
                    "workspace": f"{state_dir}/workspaces/{board_slug}/{member['id']}",
                    "agentDir": f"{state_dir}/agents/{member_agent_id}/agent",
                }
            )
            allow.append(member_agent_id)

    return agents, allow


def build_main_agent(state_dir: str) -> dict:
    return {
        "id": "main",
        "name": "Main",
        "workspace": f"{state_dir}/workspace",
        "agentDir": f"{state_dir}/agents/main/agent",
        "default": True,
    }


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
    user_slug = os.environ.get("USER_SLUG", "").strip() or None
    force_no_auth = env_flag("OPENCLAW_FORCE_NO_AUTH")
    existing_gateway_token = read_existing_gateway_token(output_path)
    existing_meta = read_existing_meta(output_path)
    gateway_token = resolve_gateway_token(user_slug, existing_gateway_token)
    feature_config = load_feature_config(
        REPO_ROOT, os.environ.get("AZURE_ENVIRONMENT", "dev"), user_slug
    )

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

    defaults = ensure_path(cfg, ["agents", "defaults"])
    defaults["workspace"] = f"{state_dir}/workspace"
    agents_cfg = ensure_path(cfg, ["agents"])
    agents_cfg["defaults"] = defaults
    plugin_entries = ensure_path(cfg, ["plugins", "entries"])
    plugins = ensure_path(cfg, ["plugins"])
    plugin_load_paths = ensure_path(plugins, ["load"])
    paths = plugin_load_paths.get("paths")
    if not isinstance(paths, list):
        paths = []
    board_router_path = "/app/plugins/board-router"
    if board_router_path not in paths:
        paths.append(board_router_path)
    plugin_load_paths["paths"] = paths
    memory_wiki_vault = ensure_path(
        plugin_entries, ["memory-wiki", "config", "vault"]
    )
    memory_wiki_vault["path"] = f"{state_dir}/wiki/main"
    main_agent = build_main_agent(state_dir)
    agents_cfg["list"] = [main_agent]

    board_ids = feature_boards_or_env(feature_config, env_csv)
    board_mode = len(board_ids) > 0
    if board_mode:
        board_router = ensure_path(plugin_entries, ["board-router"])
        board_router_config = ensure_path(board_router, ["config"])
        board_router_config["boardIds"] = board_ids
        board_router["enabled"] = True

        board_dir = resolve_default_path(
            "OPENCLAW_BOARD_DIR", "/app/config/boards", "config/boards"
        )
        agents, allow = build_board_agents(state_dir, board_dir, board_ids)
        for agent in agents:
            agent.pop("default", None)
        agents_cfg["list"] = [main_agent, *agents]
        tools = ensure_path(cfg, ["tools"])
        tools["agentToAgent"] = {"enabled": True, "allow": allow}

        active_memory = ensure_path(
            cfg, ["plugins", "entries", "active-memory", "config"]
        )
        active_memory["agents"] = [
            "main",
            *[agent["id"] for agent in agents if agent["id"].endswith("-chairman")],
        ]
    else:
        plugin_entries.pop("board-router", None)
        agents_cfg["defaults"] = defaults

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
        webhook = ensure_path(msteams, ["webhook"])
        webhook["port"] = 3978
        webhook["path"] = "/api/messages"
        if "requireMention" not in msteams:
            msteams["requireMention"] = False
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

    auto_enabled_plugins: set[str] = set()
    if signal_ready:
        auto_enabled_plugins.add("signal")
    if teams_ready:
        auto_enabled_plugins.add("msteams")

    gateway = ensure_path(cfg, ["gateway"])
    auth = ensure_path(gateway, ["auth"])

    if force_no_auth:
        auth["mode"] = "token"
        auth["token"] = gateway_token
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
        auth["token"] = gateway_token

    control_ui = ensure_path(gateway, ["controlUi"])
    if is_azure:
        default_domain = os.environ.get("AZURE_CONTAINERAPPS_DEFAULT_DOMAIN", "").strip()
        if default_domain:
            control_ui["allowedOrigins"] = [
                f"https://ca-openclaw-{os.environ.get('AZURE_ENVIRONMENT', 'dev')}-{user_slug}.{default_domain}"
            ]
        control_ui.pop("dangerouslyAllowHostHeaderOriginFallback", None)
        control_ui.pop("dangerouslyDisableDeviceAuth", None)
    else:
        control_ui.pop("dangerouslyAllowHostHeaderOriginFallback", None)
        control_ui.pop("dangerouslyDisableDeviceAuth", None)
    if not control_ui:
        gateway.pop("controlUi", None)

    tools_web = ensure_path(cfg, ["tools", "web"])
    tavily_api_key = os.environ.get("TAVILY_API_KEY", "").strip()
    plugins_are_explicit = plugins_explicitly_configured(feature_config)
    enabled_plugins = set(feature_config.get("plugins", {}).get("enable", []))
    disabled_plugins = set(feature_config.get("plugins", {}).get("disable", []))
    if board_mode:
        enabled_plugins.add("board-router")
        disabled_plugins.discard("board-router")
    overlap = enabled_plugins & disabled_plugins
    if overlap:
        fatal(
            f"Feature config plugin overlap is not allowed: {', '.join(sorted(overlap))}"
        )

    known_plugins = set(plugin_entries.keys()) | {"tavily"}
    unknown_plugins = (enabled_plugins | disabled_plugins) - known_plugins
    if unknown_plugins:
        fatal(
            f"Feature config references unknown plugins: {', '.join(sorted(unknown_plugins))}"
        )

    tavily_enabled_by_feature = True
    if plugins_are_explicit:
        tavily_enabled_by_feature = "tavily" in enabled_plugins
    if "tavily" in disabled_plugins:
        tavily_enabled_by_feature = False

    if tavily_enabled_by_feature and tavily_api_key:
        tavily = ensure_path(plugin_entries, ["tavily"])
        web_search = ensure_path(tavily, ["config", "webSearch"])
        tavily["enabled"] = True
        web_search["baseUrl"] = "https://api.tavily.com"
        web_search["apiKey"] = tavily_api_key
        ensure_path(tools_web, ["search"])["provider"] = "tavily"
    else:
        plugin_entries.pop("tavily", None)
        tools_web.pop("search", None)
        if not tools_web:
            ensure_path(cfg, ["tools"]).pop("web", None)

    for plugin_name, plugin_cfg in list(plugin_entries.items()):
        if plugin_name == "tavily":
            continue
        if plugins_are_explicit and plugin_name not in enabled_plugins:
            plugin_entries.pop(plugin_name, None)
            continue
        if plugin_name in disabled_plugins:
            plugin_entries.pop(plugin_name, None)
            continue
        if isinstance(plugin_cfg, dict):
            plugin_cfg.setdefault("enabled", True)

    plugin_allow = set(plugin_entries.keys()) | auto_enabled_plugins
    if plugin_allow:
        plugins["allow"] = sorted(plugin_allow)
    else:
        plugins.pop("allow", None)

    cfg.pop("instructions", None)

    if existing_meta:
        cfg["meta"] = existing_meta

    if output_path.exists():
        try:
            current = json.dumps(read_json(output_path), indent=2, sort_keys=True)
            candidate = json.dumps(cfg, indent=2, sort_keys=True)
            if current == candidate:
                digest = hashlib.sha256(candidate.encode("utf-8")).hexdigest()
                env_label = "azure" if is_azure else "local"
                print(
                    f"Runtime config unchanged [{env_label}] -> {output_path} sha256={digest}"
                )
                return
        except (OSError, json.JSONDecodeError):
            pass

    if output_path.exists():
        try:
            output_path.unlink()
        except OSError:
            pass

    rendered = json.dumps(cfg, indent=2, sort_keys=True)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(f"{rendered}\n", encoding="utf-8")

    digest = hashlib.sha256(rendered.encode("utf-8")).hexdigest()
    env_label = "azure" if is_azure else "local"
    print(f"Built runtime config [{env_label}] -> {output_path} sha256={digest}")


if __name__ == "__main__":
    main()
