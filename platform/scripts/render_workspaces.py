#!/usr/bin/env python3
import json
import os
import shutil
from pathlib import Path

from feature_config import feature_boards_or_env, load_feature_config, skill_allowlist


REPO_ROOT = Path(__file__).resolve().parents[2]


def env_csv(name: str) -> list[str]:
    raw = os.environ.get(name, "")
    return [item.strip() for item in raw.split(",") if item.strip()]


def fatal(message: str) -> None:
    raise SystemExit(f"FATAL: {message}")


def resolve_default_path(env_name: str, deployed_path: str, repo_relative: str) -> Path:
    explicit = os.environ.get(env_name, "").strip()
    if explicit:
        return Path(explicit)

    deployed = Path(deployed_path)
    if deployed.exists():
        return deployed

    return REPO_ROOT / repo_relative


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def title_to_slug(text: str) -> str:
    return text.lower().replace(" ", "-")


def render_identity(name: str, role_kind: str, title: str) -> str:
    return "\n".join(
        [
            "# IDENTITY.md",
            "",
            f"- Name: {name}",
            f"- Role: {role_kind}",
            f"- Title: {title}",
            "- Vibe: Direct, formal, evidence-aware, and boardroom-oriented",
            "",
            "This workspace represents a named advisory-board persona used for internal structured deliberation.",
            "",
        ]
    )


def render_chairman_soul(board: dict) -> str:
    chairman = board["chairman"]
    lines = [
        "# SOUL.md",
        "",
        f"You are {chairman['name']}, chairing the {board['name']}.",
        "",
        "Core stance:",
        "- Calm, authoritative, procedural, and concise.",
        "- Focus on clarity, discipline, and relevance to the agenda.",
        "- Seek useful disagreement, not artificial consensus.",
        "- Close meetings with a clear recommendation, vote tally, dissent, and next actions.",
        "- When evidence excerpts from public sources are provided, use them as soft grounding for likely priorities and objections.",
        "",
        "Guardrails:",
        "- This is an internal advisory simulation grounded in public roles and expertise.",
        "- Public-source grounding is suggestive, not proof of a current real-world position.",
        "- Do not claim real-world endorsement, participation, or private knowledge from any real person.",
        "- Do not invent attendance. Only selected attendees debate and vote.",
        "",
    ]
    return "\n".join(lines)


def render_member_soul(board: dict, member: dict) -> str:
    lines = [
        "# SOUL.md",
        "",
        f"You are {member['name']}, serving on the {board['name']}.",
        "",
        f"Primary topic: {member['topic']}",
        f"Primary focus: {member['focus']}",
        "",
        "Core stance:",
        "- Think like a serious board member, not a commentator.",
        "- Bring a distinctive point of view anchored in your public domain expertise.",
        "- When public-source grounding excerpts are provided, use them as soft evidence for likely priorities, not as proof of a literal current stance.",
        "- Push on weak assumptions, missing evidence, implementation risk, and second-order effects.",
        "- Stay concise and decision-oriented.",
        "",
        "Guardrails:",
        "- This is an internal advisory simulation grounded in public roles and expertise.",
        "- Do not invent private facts, private conversations, or unpublished positions.",
        "- If public evidence is weak, conflicting, or thin, say so explicitly.",
        "- Do not speak for absent members or fabricate consensus.",
        "",
    ]
    return "\n".join(lines)


def render_decision_packet_contract() -> list[str]:
    return [
        "Decision packet format:",
        "1. Meeting ID",
        "2. Board",
        "3. Chairman",
        "4. Agenda Topic",
        "5. Agenda Summary",
        "6. Selected Attendees",
        "7. Decision Outcome: approve | reject | defer | request_more_analysis",
        "8. Decision Summary",
        "9. Vote Tally: yes / no / abstain",
        "10. Member Votes",
        "11. Majority View",
        "12. Dissenting Views",
        "13. Key Risks",
        "14. Open Questions",
        "15. Recommended Next Actions",
    ]


def render_board_execution_skill(board: dict) -> str:
    chairman = board["chairman"]
    board_id = board["id"]
    lines = [
        "---",
        "name: board-meeting-execution",
        "description: Deterministic execution path for formal board meetings using the local board runner",
        "---",
        "",
        "# Board Meeting Execution",
        "",
        f"Use this skill when {chairman['name']} is asked to convene the {board['name']} and return a formal decision packet.",
        "",
        "## When To Use",
        "",
        "Trigger this skill for requests that ask you to:",
        "- convene the board",
        "- select attendees and deliberate",
        "- run a formal board meeting",
        "- return a decision packet",
        "",
        "Do not handle those requests by free-form simulation.",
        "",
        "## Required Behavior",
        "",
        "1. Build a compact agenda JSON file from the user's request with keys:",
        "   - `meetingId`",
        "   - `boardId`",
        "   - `agendaTopic`",
        "   - `agendaSummary`",
        "   - `context`",
        "   - `decisionRequest`",
        "2. Use the `bash` tool to write that JSON to a temp file inside the container.",
        "3. Use the `bash` tool to run the local board runner:",
        f"   - `node /app/platform/scripts/run_board_meeting.mjs --board {board_id} --agenda <temp-agenda-path> --output <temp-output-path> --trace-output <temp-trace-path> --packet-mode brief --min-attendees 3 --max-attendees 3 --selection-timeout 180 --member-timeout 120 --chairman-timeout 180`",
        "4. Read the generated markdown packet from the temp output path using `bash` and return it to the user.",
        "5. If needed for verification, inspect the trace JSON at `<temp-trace-path>`.",
        "6. If execution fails, say that board execution failed and report the actual error. Do not invent attendee views or votes.",
        "",
        "## Output Requirements",
        "",
        "- Use only named members from the internal board roster.",
        "- Never substitute generic unnamed roles.",
        "- Return the real decision packet produced by the runner.",
        "",
        "## Temp File Convention",
        "",
        "- Agenda path: `/tmp/<meetingId>.agenda.json`",
        "- Output path: `/tmp/<meetingId>.decision.md`",
        "- Trace path: `/tmp/<meetingId>.trace.json`",
        "",
    ]
    return "\n".join(lines)


def render_base_board_router(board_ids: list[str]) -> str:
    if board_ids:
        board_list = ", ".join(board_ids)
    else:
        board_list = "(none enabled)"
    lines = [
        "---",
        "name: board-routing",
        "description: Rules for routing formal board requests to the convene_board_meeting tool",
        "---",
        "",
        "# Board Routing",
        "",
        "Boards are optional specialist agents, not the default entry point.",
        "",
        f"Enabled boards for this user: {board_list}",
        "",
        "## When to convene a board",
        "",
        "Trigger the `convene_board_meeting` tool when the user asks for any of:",
        "- A formal board decision, board review, or board request",
        "- Convening or invoking a specific board",
        "- A decision packet on a topic that falls under a named board",
        "",
        "## Rules",
        "",
        "- If the user names a board, call the tool immediately with that board.",
        "- If the user requests a board decision but does not name a board, ask which board they want. List the available boards.",
        "- Do not infer the board from the topic or domain. A board counts as named only when the user explicitly says the board name.",
        "- Do not silently choose a board on the user's behalf.",
        "- If no boards are enabled, say that no boards are enabled for this user.",
        "",
        "## How to execute",
        "",
        "Call the `convene_board_meeting` tool with:",
        "- `board`: the board ID exactly as listed above (e.g. `fertility`)",
        "- `topic`: a clear statement of the decision being requested",
        "- `context`: any relevant constraints, timelines, history, or background the user provided (optional)",
        "",
        "The tool runs a full board meeting with specialist attendees, deliberation, and a formal vote.",
        "It takes several minutes to complete. Present the returned decision packet to the user verbatim.",
        "Do not summarize, reinterpret, or editorialize the board's decision.",
        "",
    ]
    return "\n".join(lines)


def render_chairman_agents(base_agents: str, board: dict) -> str:
    chairman = board["chairman"]
    lines = [
        base_agents.rstrip(),
        "",
        "---",
        "",
        "# Board-Specific Instructions",
        "",
        f"You are the chairman of the {board['name']}.",
        f"Chairman identity: {chairman['name']} - {chairman['title']}",
        f"Board description: {board['description']}",
        "",
        "Operating rules:",
        "- Run each agenda item as a structured board meeting.",
        "- Select attendees from the roster based on topic relevance.",
        "- Only selected attendees may debate and vote.",
        "- Ask for one independent first-pass view from each attendee before any rebuttal.",
        "- Then provide a short cross-member synthesis and request a final vote.",
        "- If evidence is weak or unresolved risks are material, prefer defer or request_more_analysis.",
        "- Produce a formal decision packet at the end.",
        "- For any formal request to convene the board or return a decision packet, use the board-meeting-execution skill and run the local board runner. Do not simulate the board in free text.",
        "",
        "Collaboration rules:",
        "- For deterministic formal board execution, prefer the board-meeting runner over ad hoc free-chat orchestration.",
        "- Use the agent-to-agent or session tools only when the user is explicitly asking for exploratory chairman chat rather than a formal decision packet.",
        "- Keep each member request explicit about the agenda, evidence provided, and required output.",
        "- Treat any injected evidence excerpts as public-source grounding, not as proof of current endorsement.",
        "- Do not let one member's first response anchor the rest before the independent round is complete.",
        "",
        "Roster:",
    ]
    for member in board["members"]:
        lines.append(
            f"- {member['name']} | {member['topic']} | attendance default: {member['attendance']}"
        )
    lines.extend(["", *render_decision_packet_contract(), ""])
    return "\n".join(lines)


def render_member_agents(base_agents: str, board: dict, member: dict) -> str:
    lines = [
        base_agents.rstrip(),
        "",
        "---",
        "",
        "# Board-Specific Instructions",
        "",
        f"You are {member['name']}, a board member of the {board['name']}.",
        f"Topic area: {member['topic']}",
        f"Attendance default: {member['attendance']}",
        "",
        "Operating rules:",
        "- Represent this named member as an internal advisory simulation grounded in public role and expertise.",
        "- When invited to deliberate, respond in two rounds: independent first view, then final vote after rebuttal.",
        "- Use any provided public-source grounding excerpts as soft evidence for likely priorities and objections.",
        "- Keep recommendations practical, explicit, and evidence-aware.",
        "- State when evidence is insufficient.",
        "- Never invent the views of other members.",
        "",
        "Your decision lens:",
    ]
    for item in member.get("decisionLens", []):
        lines.append(f"- {item}")
    lines.extend(
        [
            "",
            "First-pass response format:",
            "1. Recommendation: support | oppose | conditional_support | defer",
            "2. Rationale: 3-5 bullets",
            "3. Key Risks: 1-3 bullets",
            "4. Questions for the Board: 0-3 bullets",
            "",
            "Final-vote response format:",
            "1. Vote: yes | no | abstain",
            "2. Confidence: 0-100",
            "3. Final reasoning summary: 2-4 bullets",
            "4. Conditions or caveats: 0-3 bullets",
            "",
        ]
    )
    return "\n".join(lines)


def render_board_skill() -> str:
    lines = [
        "---",
        "name: board-deliberation",
        "description: Structured protocol for chairman-led advisory board debate, voting, and decision packets",
        "---",
        "",
        "# Board Deliberation",
        "",
        "Use this skill when running an advisory board meeting with a chairman and selected members.",
        "",
        "## Protocol",
        "",
        "1. Chairman selects attendees relevant to the agenda.",
        "2. Each attendee gives an independent first-pass view before seeing peer positions.",
        "3. Chairman shares a short synthesis of similarities, disagreements, and unresolved issues.",
        "4. Each attendee gives a final vote and confidence score.",
        "5. Chairman issues the final decision packet.",
        "",
        "## Decision Packet",
        "",
        *render_decision_packet_contract(),
        "",
        "## Rules",
        "",
        "- Only selected attendees debate and vote.",
        "- Do not fabricate absent-member positions.",
        "- Prefer defer or request_more_analysis when evidence is incomplete.",
        "- Keep outputs concise, decision-grade, and explicit about risks.",
        "",
    ]
    return "\n".join(lines)


def ensure_file(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def copy_if_missing(source: Path, dest: Path) -> None:
    if not dest.exists():
        shutil.copy2(source, dest)


def _has_user_profile(feature_config: dict) -> bool:
    """Return True if feature config includes a user profile with minimum fields."""
    user = feature_config.get("user")
    if not isinstance(user, dict):
        return False
    return bool(user.get("name")) and bool(user.get("timezone"))


def _user_md_needs_generation(workspace: Path) -> bool:
    """Return True if USER.md doesn't exist or still has template placeholders."""
    user_md = workspace / "USER.md"
    if not user_md.exists():
        return True
    content = user_md.read_text(encoding="utf-8")
    return "<your-name>" in content or "<your-timezone>" in content


def render_user_md(user_config: dict) -> str:
    """Generate USER.md content from the user profile in feature config."""
    name = user_config.get("name", "")
    preferred = user_config.get("preferredName", name)
    timezone = user_config.get("timezone", "")
    role = user_config.get("role", "")
    notes = user_config.get("notes", [])

    lines = [
        "# USER.md - About Your Human",
        "",
        f"- **Name:** {name}",
        f"- **What to call them:** {preferred}",
        f"- **Timezone:** {timezone}",
        "- **Notes:**",
    ]
    if role:
        lines.append(f"  - {role}")
    for note in notes:
        lines.append(f"  - {note}")
    if not role and not notes:
        lines.append("  - (no additional notes)")

    lines.extend(
        [
            "",
            "## Context",
            "",
            "- When preparing anything:",
            "  - Default to **executive brief**: 3-5 bullets, one clear ask, one risk to watch.",
            "  - Make numbers traceable to real sources (internal docs, dashboards, official stats).",
            "  - Avoid internal jargon unless it's already standard in their materials.",
            "  - Highlight how a decision or initiative reinforces the organization's strategic goals.",
            "",
            "---",
            "",
            "Remember: your job is to compress complexity into a small number of true, "
            "actionable statements—with clear trade-offs and a credible path forward.",
        ]
    )
    return "\n".join(lines) + "\n"


def filter_workspace_skills(
    workspace: Path, allowed_skill_names: list[str], required_skill_names: list[str]
) -> None:
    skills_dir = workspace / "skills"
    if not skills_dir.exists():
        return

    allowed = set(allowed_skill_names) | set(required_skill_names)
    for child in skills_dir.iterdir():
        if child.name in allowed:
            continue
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()


def write_base_workspace(
    board_ids: list[str], feature_config: dict, state_dir: Path
) -> None:
    workspace = state_dir / "workspace"
    ensure_file(
        workspace / "skills" / "board-routing" / "SKILL.md",
        render_base_board_router(board_ids),
    )

    allowlist = skill_allowlist(feature_config, "baseWorkspace")
    if allowlist is not None:
        filter_workspace_skills(workspace, allowlist, ["board-routing"])

    # USER.md: generate from config if a user profile is present and the
    # current file still has template placeholders (or doesn't exist).
    if _has_user_profile(feature_config) and _user_md_needs_generation(workspace):
        ensure_file(workspace / "USER.md", render_user_md(feature_config["user"]))

    # BOOTSTRAP.md: delete if user profile exists (no conversational
    # onboarding needed).  Otherwise leave it for the agent to handle.
    bootstrap_path = workspace / "BOOTSTRAP.md"
    if _has_user_profile(feature_config) and bootstrap_path.exists():
        bootstrap_path.unlink()

    agents_file = workspace / "AGENTS.md"
    if agents_file.exists():
        base_text = agents_file.read_text(encoding="utf-8")
        marker = "\n# Board Access\n"
        marker_index = base_text.find(marker)
        if marker_index >= 0:
            base_text = base_text[:marker_index].rstrip()
        else:
            base_text = base_text.rstrip()
        board_block = [
            "",
            "---",
            "",
            "# Board Access",
            "",
            "Boards are available as specialist agents, not the default entry point.",
            "",
        ]
        if board_ids:
            board_block.extend(
                [
                    f"Enabled boards: {', '.join(board_ids)}",
                    "- If the user explicitly names a board, execute that board via the deterministic board runner.",
                    "- If the user asks for a formal board decision without naming one, ask exactly: `Which board?`",
                    "- Do not infer the board from the topic alone; only an explicit board name counts.",
                    "- Do not try to open chairman-only board skills from absolute paths; named-board execution from the base workspace should use the local board runner directly.",
                    "- Do not provide a simulated board packet from the base workspace when the user asked for a named board.",
                ]
            )
        else:
            board_block.extend(
                [
                    "No boards are enabled for this user.",
                    "- If the user asks for a board decision, explain that no boards are enabled.",
                ]
            )
        ensure_file(agents_file, "\n".join([base_text, *board_block, ""]))


def load_base_agents(base_workspace: Path, graph_url: str) -> str:
    source_agents = base_workspace / "AGENTS.md"
    if not source_agents.exists():
        fatal(f"Base AGENTS.md not found: {source_agents}")

    text = source_agents.read_text(encoding="utf-8")
    if graph_url:
        text = text.replace("${GRAPH_MCP_URL}", graph_url)
    return text


def refresh_m365_skill(base_workspace: Path, workspace: Path, graph_url: str) -> None:
    source_skill = base_workspace / "skills" / "m365-graph-gateway" / "SKILL.md"
    dest_skill = workspace / "skills" / "m365-graph-gateway" / "SKILL.md"
    if source_skill.exists():
        skill_text = source_skill.read_text(encoding="utf-8")
        if graph_url:
            skill_text = skill_text.replace("${GRAPH_MCP_URL}", graph_url)
        ensure_file(dest_skill, skill_text)

    source_contract = (
        base_workspace
        / "skills"
        / "m365-graph-gateway"
        / "references"
        / "TOOL_CONTRACT.md"
    )
    dest_contract = (
        workspace / "skills" / "m365-graph-gateway" / "references" / "TOOL_CONTRACT.md"
    )
    if source_contract.exists():
        ensure_file(dest_contract, source_contract.read_text(encoding="utf-8"))


def seed_workspace(base_workspace: Path, dest_workspace: Path) -> None:
    if dest_workspace.exists():
        return
    shutil.copytree(base_workspace, dest_workspace)


def write_common_files(
    base_workspace: Path,
    workspace: Path,
    graph_url: str,
    allowed_skill_names: list[str],
    required_skill_names: list[str],
    feature_config: dict | None = None,
) -> None:
    source_heartbeat = base_workspace / "HEARTBEAT.md"
    if source_heartbeat.exists():
        ensure_file(
            workspace / "HEARTBEAT.md", source_heartbeat.read_text(encoding="utf-8")
        )

    source_tools = base_workspace / "TOOLS.md"
    copy_if_missing(source_tools, workspace / "TOOLS.md")

    source_memory = base_workspace / "MEMORY.md"
    copy_if_missing(source_memory, workspace / "MEMORY.md")

    # USER.md: generate from config if a user profile exists (and USER.md
    # still has template placeholders or doesn't exist yet).  Otherwise
    # fall back to copying the template once.
    fc = feature_config or {}
    if _has_user_profile(fc) and _user_md_needs_generation(workspace):
        ensure_file(workspace / "USER.md", render_user_md(fc["user"]))
    else:
        source_user = base_workspace / "USER.md"
        copy_if_missing(source_user, workspace / "USER.md")

    # BOOTSTRAP.md: skip entirely when a user profile is present (the
    # agent already has what it needs).  Otherwise only copy on first
    # creation — never recreate after the agent deletes it.
    bootstrap_dest = workspace / "BOOTSTRAP.md"
    if _has_user_profile(fc):
        if bootstrap_dest.exists():
            bootstrap_dest.unlink()
    else:
        copy_if_missing(base_workspace / "BOOTSTRAP.md", bootstrap_dest)

    filter_workspace_skills(workspace, allowed_skill_names, required_skill_names)
    refresh_m365_skill(base_workspace, workspace, graph_url)
    if "board-deliberation" in required_skill_names:
        ensure_file(
            workspace / "skills" / "board-deliberation" / "SKILL.md",
            render_board_skill(),
        )


def write_chairman_skill(workspace: Path, board: dict) -> None:
    ensure_file(
        workspace / "skills" / "board-meeting-execution" / "SKILL.md",
        render_board_execution_skill(board),
    )


def render_board(
    base_workspace: Path,
    state_dir: Path,
    board: dict,
    graph_url: str,
    feature_config: dict,
) -> None:
    board_root = state_dir / "workspaces" / board["id"]
    base_agents = load_base_agents(base_workspace, graph_url)
    base_allowed_skills = (
        feature_config.get("skills", {}).get("baseWorkspace", {}).get("allow", [])
    )
    chairman_allowed_skills = (
        feature_config.get("skills", {}).get("chairman", {}).get("allow", [])
    )
    member_allowed_skills = (
        feature_config.get("skills", {}).get("members", {}).get("allow", [])
    )

    chairman_workspace = board_root / "chairman"
    seed_workspace(base_workspace, chairman_workspace)
    write_common_files(
        base_workspace,
        chairman_workspace,
        graph_url,
        base_allowed_skills + chairman_allowed_skills,
        ["board-deliberation", "board-meeting-execution"],
        feature_config,
    )
    write_chairman_skill(chairman_workspace, board)
    ensure_file(
        chairman_workspace / "IDENTITY.md",
        render_identity(
            board["chairman"]["name"], "Board Chairman", board["chairman"]["title"]
        ),
    )
    ensure_file(chairman_workspace / "SOUL.md", render_chairman_soul(board))
    ensure_file(
        chairman_workspace / "AGENTS.md", render_chairman_agents(base_agents, board)
    )

    for member in board["members"]:
        member_workspace = board_root / member["id"]
        seed_workspace(base_workspace, member_workspace)
        write_common_files(
            base_workspace,
            member_workspace,
            graph_url,
            base_allowed_skills + member_allowed_skills,
            ["board-deliberation"],
            feature_config,
        )
        ensure_file(
            member_workspace / "IDENTITY.md",
            render_identity(member["name"], "Board Member", member["title"]),
        )
        ensure_file(member_workspace / "SOUL.md", render_member_soul(board, member))
        ensure_file(
            member_workspace / "AGENTS.md",
            render_member_agents(base_agents, board, member),
        )


def main() -> None:
    state_dir_raw = os.environ.get("OPENCLAW_STATE_DIR", "").strip()
    if not state_dir_raw:
        fatal("OPENCLAW_STATE_DIR is required")

    user_slug = os.environ.get("USER_SLUG", "").strip() or None
    env_name = os.environ.get("AZURE_ENVIRONMENT", "dev")
    feature_config = load_feature_config(REPO_ROOT, env_name, user_slug)

    board_ids = feature_boards_or_env(feature_config, env_csv)
    write_base_workspace(board_ids, feature_config, Path(state_dir_raw))
    if not board_ids:
        print(
            "No boards enabled for this user; refreshed base workspace board-routing rules only."
        )
        return

    board_dir = resolve_default_path(
        "OPENCLAW_BOARD_DIR", "/app/config/boards", "config/boards"
    )
    base_workspace = resolve_default_path(
        "OPENCLAW_BASE_WORKSPACE", "/app/config/workspace", "workspace"
    )
    graph_url = os.environ.get("GRAPH_MCP_URL", "").strip()
    state_dir = Path(state_dir_raw)

    if not board_dir.exists():
        fatal(f"Board directory not found: {board_dir}")
    if not base_workspace.exists():
        fatal(f"Base workspace not found: {base_workspace}")

    for board_id in board_ids:
        board_path = board_dir / f"{board_id}.json"
        if not board_path.exists():
            fatal(f"Board definition not found: {board_path}")
        render_board(
            base_workspace,
            state_dir,
            read_json(board_path),
            graph_url,
            feature_config,
        )

    print(
        f"Rendered board workspaces for: {', '.join(board_ids)} -> {state_dir / 'workspaces'}"
    )


if __name__ == "__main__":
    main()
