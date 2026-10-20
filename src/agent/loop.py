from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any, Literal

from src.agent.personas import build_persona_prompt
from src.agent.roles import ToolEvent
from src.agent.skills import build_skill_prompt, resolve_skill_name
from src.agent.tools import (
    create_file,
    edit_file,
    fetch_url,
    glob_files,
    grep_repo,
    list_dir,
    read_file,
    run_cmd,
    web_search,
)
from src.agent.host_tools import disk_mem, docker_logs, docker_ps, docker_stats, host_processes, log_grep
from src.config import (
    agent_max_steps,
    agent_mutate_enabled,
    audit_root_map,
    native_tools_enabled,
    tool_result_max_chars,
)
from src.llm.client import (
    NativeToolCall,
    get_agent_completion,
    get_agent_completion_turn,
    get_completion,
    get_completion_turn,
)
from src.agent.openai_tools import openai_tools_payload
from src.runtime.memory import append_mission_summary, build_memory_prompt
from src.runtime.mission_events import mission_event_bus

RoleName = Literal["researcher", "coder", "debugger", "doc_maker", "contracts", "default"]

TOOL_MAP = {
    "create_file": create_file,
    "edit_file": edit_file,
    "run_cmd": run_cmd,
    "list_dir": list_dir,
    "read_file": read_file,
    "grep_repo": grep_repo,
    "glob_files": glob_files,
    "fetch_url": fetch_url,
    "web_search": web_search,
    "host_processes": host_processes,
    "disk_mem": disk_mem,
    "docker_ps": docker_ps,
    "docker_stats": docker_stats,
    "docker_logs": docker_logs,
    "log_grep": log_grep,
}

_BASE_SYSTEM_PROMPT = (
    "You are ALFa AI, a coding assistant. "
    "When you need a tool, reply with strict JSON: "
    '{"tool":"tool_name","args":{...}}. '
    "When done, reply with plain text final answer."
)

_RESEARCHER_SYSTEM_PROMPT = (
    "You are ALFa AI research agent. "
    "Prefer internal repo search (grep_repo, read_file, glob_files) before fetch_url or web_search. "
    "When ALFA_AI_AUDIT_ROOTS is configured, use path prefixes such as alfa-ai/deploy/ "
    "and alfa-ai/docs/ (not bare deploy/ unless files exist under workspace). "
    "Use web_search only when enabled, only for operator/LAN-admin missions, "
    "and only when repo/allowlisted fetch cannot answer the question. "
    "After web_search, use fetch_url on allowlisted vendor manual URLs when possible. "
    "Cite repo paths and URLs in the final answer under a Sources section. "
    'When you need a tool, reply with strict JSON: {"tool":"tool_name","args":{...}}. '
    "When done, reply with plain text final answer."
)


def _audit_roots_prompt_line() -> str:
    roots = audit_root_map()
    if not roots:
        return ""
    parts = [f"{name}/ -> {root}" for name, root in sorted(roots.items())]
    return "Configured audit roots (read-only): " + "; ".join(parts) + "\n"

_CODER_SYSTEM_PROMPT = (
    "You are ALFa AI coder agent. "
    "Read the repo first (grep_repo, read_file, glob_files). "
    "Prefer edit_file for targeted changes; use create_file only for new files. "
    "Summarize every file changed in the final answer. "
    'When you need a tool, reply with strict JSON: {"tool":"tool_name","args":{...}}. '
    "When done, reply with plain text final answer."
)

_CONTRACTS_SYSTEM_PROMPT = (
    "You are ALFa AI federal contracting analyst. "
    "Read every input document with list_dir and read_file from the provided input folder. "
    "Write deliverables with create_file into the provided output folder "
    "(for example analysis.md, capability-statement.md, compliance-checklist.md). "
    "create_file args: {\"path\":\"relative/path.md\",\"contents\":\"file body\"}. "
    "read_file args: {\"path\":\"relative/path\"}. list_dir args: {\"path\":\"relative/dir\"}. "
    "Do not use run_cmd. Do not fetch external URLs unless explicitly required. "
    "Cite which input files you used in the final answer. "
    'When you need a tool, reply with strict JSON: {"tool":"tool_name","args":{...}}. '
    "When done, reply with plain text final answer."
)

_DEBUGGER_SYSTEM_PROMPT = (
    "You are ALFa AI debugger agent. "
    "Use read-only tools (grep_repo, read_file, glob_files, list_dir) to find the failure. "
    "Do not edit files unless mutate is enabled. "
    "End with a short diagnosis and the most likely fix. "
    'When you need a tool, reply with strict JSON: {"tool":"tool_name","args":{...}}. '
    "When done, reply with plain text final answer."
)

_DOC_MAKER_SYSTEM_PROMPT = (
    "You are ALFa AI documentation agent. "
    "Read upstream artifacts and repo files, then write clear operator docs. "
    "Prefer create_file only when mutate is enabled; otherwise put the full doc in the final answer. "
    'When you need a tool, reply with strict JSON: {"tool":"tool_name","args":{...}}. '
    "When done, reply with plain text final answer."
)

_ROLE_PROMPTS: dict[RoleName, str] = {
    "researcher": _RESEARCHER_SYSTEM_PROMPT,
    "default": _BASE_SYSTEM_PROMPT,
    "coder": _CODER_SYSTEM_PROMPT,
    "debugger": _DEBUGGER_SYSTEM_PROMPT,
    "doc_maker": _DOC_MAKER_SYSTEM_PROMPT,
    "contracts": _CONTRACTS_SYSTEM_PROMPT,
}

_AGENT_MODEL_ROLES: frozenset[RoleName] = frozenset(
    {"researcher", "coder", "debugger", "doc_maker", "contracts"}
)

_READ_ONLY_TOOLS: frozenset[str] = frozenset(
    {
        "list_dir",
        "read_file",
        "grep_repo",
        "glob_files",
        "fetch_url",
        "web_search",
        "host_processes",
        "disk_mem",
        "docker_ps",
        "docker_stats",
        "docker_logs",
        "log_grep",
    }
)
_CONTRACTS_TOOLS: frozenset[str] = frozenset({"list_dir", "read_file", "create_file"})


@dataclass(slots=True)
class AgentRunResult:
    text: str
    tool_events: list[ToolEvent] = field(default_factory=list)


def _parse_tool_call(raw: str) -> tuple[str, dict[str, Any]] | None:
    text = raw.strip()
    if text.startswith("```json") and text.endswith("```"):
        text = text[len("```json") : -3].strip()
    elif text.startswith("```") and text.endswith("```"):
        text = text[3:-3].strip()

    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return None

    if not isinstance(parsed, dict):
        return None
    tool = parsed.get("tool")
    args = parsed.get("args", {})
    if not isinstance(tool, str) or not isinstance(args, dict):
        return None
    return tool, args


def _normalize_tool_args(tool_name: str, args: dict[str, Any]) -> dict[str, Any]:
    """Map common model arg aliases to tool function parameter names."""
    normalized = dict(args)
    if tool_name == "create_file":
        if "contents" not in normalized:
            for alias in ("content", "text", "body", "data"):
                if alias in normalized:
                    normalized["contents"] = normalized.pop(alias)
                    break
        if "path" not in normalized:
            for alias in ("file_path", "filepath", "filename", "file"):
                if alias in normalized:
                    normalized["path"] = normalized.pop(alias)
                    break
    elif tool_name == "read_file" and "path" not in normalized:
        for alias in ("file_path", "filepath", "filename", "file"):
            if alias in normalized:
                normalized["path"] = normalized.pop(alias)
                break
    elif tool_name == "list_dir" and "path" not in normalized:
        for alias in ("dir", "directory", "folder"):
            if alias in normalized:
                normalized["path"] = normalized.pop(alias)
                break
    return normalized


def _allowed_tools_for_run(
    role: RoleName,
    *,
    research_only: bool,
) -> frozenset[str] | None:
    """Return allowed tool names, or None for full TOOL_MAP (coder with mutate on)."""
    if research_only or role == "researcher":
        return _READ_ONLY_TOOLS
    if role == "contracts":
        return _CONTRACTS_TOOLS
    if role == "coder" and agent_mutate_enabled():
        return None
    if role in ("debugger", "doc_maker", "default"):
        return _READ_ONLY_TOOLS if not agent_mutate_enabled() else None
    return _READ_ONLY_TOOLS


def _execute_tool(
    tool_name: str,
    args: dict[str, Any],
    *,
    allowed_tools: frozenset[str] | None,
) -> dict[str, Any]:
    tool = TOOL_MAP.get(tool_name)
    if tool is None:
        return {"ok": False, "error": f"Unknown tool: {tool_name}"}
    if allowed_tools is not None and tool_name not in allowed_tools:
        return {
            "ok": False,
            "error": (
                f"Tool '{tool_name}' is not allowed for this run "
                "(ALFA_AI_AGENT_MUTATE_ENABLED=0 or research_only)."
            ),
        }
    try:
        return tool(**_normalize_tool_args(tool_name, args))
    except TypeError as exc:
        return {"ok": False, "error": f"Invalid tool args: {exc}"}


def _truncate_tool_payload(tool_name: str, tool_result: dict[str, Any]) -> str:
    serialized = json.dumps(
        {"tool": tool_name, "result": tool_result},
        ensure_ascii=True,
    )
    limit = tool_result_max_chars()
    if len(serialized) <= limit:
        return serialized
    return serialized[:limit] + "...(truncated)"


def _system_prompt_for_role(
    role: RoleName | None,
    *,
    skill: str | None = None,
    persona: str | None = None,
    research_only: bool = False,
) -> str:
    role_key: RoleName = role if role else "default"
    base = _ROLE_PROMPTS.get(role_key, _BASE_SYSTEM_PROMPT)
    skill_name = resolve_skill_name(
        role_key,
        explicit=skill,
        research_only=research_only,
    )
    extra = _audit_roots_prompt_line() if role_key == "researcher" else ""
    return (
        base
        + extra
        + build_persona_prompt(persona)
        + build_skill_prompt(skill_name)
        + build_memory_prompt(role_key)
    )


def _extract_sources_section(text: str) -> str:
    marker = "## Sources"
    alt = "## sources"
    idx = text.find(marker)
    if idx < 0:
        idx = text.find(alt)
    if idx < 0:
        return ""
    return text[idx:].strip()


def _should_persist_memory(role: RoleName, text: str) -> bool:
    if role not in {"researcher", "coder"}:
        return False
    cleaned = text.strip()
    if not cleaned:
        return False
    if cleaned.startswith("Stopped after max steps"):
        return False
    return True


def _uses_agent_model(role: RoleName | None, use_agent_model: bool) -> bool:
    return use_agent_model or (role in _AGENT_MODEL_ROLES)


def _iso_now() -> str:
    return datetime.now(tz=UTC).isoformat()


def run_agent(
    user_message: str,
    max_steps: int | None = None,
    *,
    role: RoleName | None = None,
    use_agent_model: bool = False,
    model: str | None = None,
    skill: str | None = None,
    persona: str | None = None,
    research_only: bool = False,
    run_id: str | None = None,
) -> AgentRunResult:
    steps = max_steps if max_steps is not None else agent_max_steps()
    role_key: RoleName = role if role else "default"
    system_prompt = _system_prompt_for_role(
        role_key,
        skill=skill,
        persona=persona,
        research_only=research_only,
    )
    tool_events: list[ToolEvent] = []
    allowed_tools = _allowed_tools_for_run(role_key, research_only=research_only)

    messages: list[dict[str, Any]] = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_message},
    ]

    completion_kwargs: dict[str, Any] = {}
    if model and not _uses_agent_model(role_key, use_agent_model):
        completion_kwargs["model"] = model

    tools_payload = (
        openai_tools_payload(allowed_tools) if native_tools_enabled() else None
    )

    for _ in range(steps):
        if native_tools_enabled():
            if _uses_agent_model(role_key, use_agent_model):
                turn = get_agent_completion_turn(messages, tools=tools_payload)
            else:
                turn = get_completion_turn(messages, tools=tools_payload, **completion_kwargs)
            llm_reply = turn.content
            native_calls = [c for c in turn.tool_calls if c.name]
        else:
            if _uses_agent_model(role_key, use_agent_model):
                llm_reply = get_agent_completion(messages)
            else:
                llm_reply = get_completion(messages, **completion_kwargs)
            native_calls = []

        parsed_calls: list[NativeToolCall] = list(native_calls)
        if not parsed_calls:
            parsed_json = _parse_tool_call(llm_reply)
            if parsed_json is not None:
                parsed_calls = [
                    NativeToolCall(id="", name=parsed_json[0], arguments=parsed_json[1])
                ]

        if not parsed_calls:
            final_text = (llm_reply or "").strip()
            if _should_persist_memory(role_key, final_text):
                append_mission_summary(
                    user_message,
                    final_text[:4000],
                    _extract_sources_section(final_text),
                )
            return AgentRunResult(text=final_text, tool_events=tool_events)

        assistant_msg: dict[str, Any]
        if native_calls:
            assistant_msg = {
                "role": "assistant",
                "content": llm_reply or None,
                "tool_calls": [
                    {
                        "id": call.id or f"call_{idx}",
                        "type": "function",
                        "function": {
                            "name": call.name,
                            "arguments": json.dumps(call.arguments, ensure_ascii=True),
                        },
                    }
                    for idx, call in enumerate(parsed_calls)
                ],
            }
        else:
            assistant_msg = {"role": "assistant", "content": llm_reply}
        messages.append(assistant_msg)

        for idx, call in enumerate(parsed_calls):
            tool_name, args = call.name, call.arguments
            call_id = call.id or f"call_{idx}"
            started = time.perf_counter()
            started_at = _iso_now()
            if run_id:
                mission_event_bus.publish(
                    run_id,
                    "tool_start",
                    {"tool": tool_name, "args": args},
                )
            tool_result = _execute_tool(tool_name, args, allowed_tools=allowed_tools)
            duration_ms = int((time.perf_counter() - started) * 1000)
            if run_id:
                mission_event_bus.publish(
                    run_id,
                    "tool_end",
                    {
                        "tool": tool_name,
                        "ok": bool(tool_result.get("ok")),
                        "duration_ms": duration_ms,
                    },
                )
            tool_events.append(
                ToolEvent(
                    tool_name=tool_name,
                    ok=bool(tool_result.get("ok")),
                    started_at=started_at,
                    duration_ms=duration_ms,
                    details={"args": args, "result": tool_result},
                )
            )
            payload = _truncate_tool_payload(tool_name, tool_result)
            if native_calls:
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": call_id,
                        "content": payload,
                    }
                )
            else:
                messages.append({"role": "tool", "content": payload})

    return AgentRunResult(
        text="Stopped after max steps without final answer.",
        tool_events=tool_events,
    )