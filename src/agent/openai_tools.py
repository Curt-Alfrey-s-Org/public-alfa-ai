"""OpenAI Chat Completions `tools` schemas for the agent loop.

Official: https://platform.openai.com/docs/guides/function-calling
LiteLLM proxy: https://docs.litellm.ai/docs/completion/function_call

Default path remains JSON-in-text. Native tools are opt-in
(`ALFA_AI_NATIVE_TOOLS=1`) for 27B smoke and Pool80.
"""

from __future__ import annotations

from typing import Any

# Compact JSON Schema per tool. Keep required fields aligned with src/agent/tools.py.
_TOOL_SCHEMAS: dict[str, dict[str, Any]] = {
    "list_dir": {
        "description": "List files in a workspace or audit-root directory.",
        "parameters": {
            "type": "object",
            "properties": {"path": {"type": "string"}},
            "required": ["path"],
        },
    },
    "read_file": {
        "description": "Read a text file under the workspace or an audit root.",
        "parameters": {
            "type": "object",
            "properties": {"path": {"type": "string"}},
            "required": ["path"],
        },
    },
    "grep_repo": {
        "description": "Search file contents with a regex.",
        "parameters": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string"},
                "path": {"type": "string"},
                "glob": {"type": "string"},
            },
            "required": ["pattern"],
        },
    },
    "glob_files": {
        "description": "Find files by glob pattern.",
        "parameters": {
            "type": "object",
            "properties": {
                "pattern": {"type": "string"},
                "path": {"type": "string"},
            },
            "required": ["pattern"],
        },
    },
    "fetch_url": {
        "description": "Fetch an allowlisted vendor-doc URL.",
        "parameters": {
            "type": "object",
            "properties": {"url": {"type": "string"}},
            "required": ["url"],
        },
    },
    "web_search": {
        "description": "LAN SearXNG search when enabled.",
        "parameters": {
            "type": "object",
            "properties": {"query": {"type": "string"}},
            "required": ["query"],
        },
    },
    "create_file": {
        "description": "Create a new file in the workspace.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "contents": {"type": "string"},
            },
            "required": ["path", "contents"],
        },
    },
    "edit_file": {
        "description": "Search/replace in an existing workspace file.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "old_string": {"type": "string"},
                "new_string": {"type": "string"},
                "replace_all": {"type": "boolean"},
            },
            "required": ["path", "old_string", "new_string"],
        },
    },
    "run_cmd": {
        "description": "Run a bounded shell command in the workspace.",
        "parameters": {
            "type": "object",
            "properties": {"command": {"type": "string"}},
            "required": ["command"],
        },
    },
    "host_processes": {
        "description": "List local host processes (read-only).",
        "parameters": {"type": "object", "properties": {}},
    },
    "disk_mem": {
        "description": "Disk and memory snapshot (read-only).",
        "parameters": {"type": "object", "properties": {}},
    },
    "docker_ps": {
        "description": "docker ps snapshot (read-only).",
        "parameters": {"type": "object", "properties": {}},
    },
    "docker_stats": {
        "description": "docker stats snapshot (read-only).",
        "parameters": {"type": "object", "properties": {}},
    },
    "docker_logs": {
        "description": "Tail docker logs for a container.",
        "parameters": {
            "type": "object",
            "properties": {"container": {"type": "string"}},
            "required": ["container"],
        },
    },
    "log_grep": {
        "description": "Grep a log file path.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "pattern": {"type": "string"},
            },
            "required": ["path", "pattern"],
        },
    },
}


# Ask ALFa host tools (separate from mission TOOL_MAP / _TOOL_SCHEMAS).
_ASK_ALFA_TOOL_SCHEMAS: dict[str, dict[str, Any]] = {
    "inspect_host": {
        "description": "Run a read-only catalog inspect action on a cluster host.",
        "parameters": {
            "type": "object",
            "properties": {
                "action_key": {"type": "string"},
                "host": {"type": "string"},
                "params": {"type": "object"},
            },
            "required": ["action_key"],
        },
    },
    "propose_host_action": {
        "description": (
            "Propose a mutating host catalog action. Operator must Approve before "
            "execution, except Home Assistant solar dump keys (ha_switch_on, "
            "ha_switch_off, ha_set_number, ha_select_option, ha_dump_tick) which "
            "run immediately when HA is enabled."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "action_key": {"type": "string"},
                "host": {"type": "string"},
                "params": {"type": "object"},
            },
            "required": ["action_key", "host"],
        },
    },
}


def ask_alfa_openai_tools_payload() -> list[dict[str, Any]]:
    """OpenAI `tools` for Ask ALFa: inspect_host + propose_host_action only."""
    out: list[dict[str, Any]] = []
    for name in sorted(_ASK_ALFA_TOOL_SCHEMAS):
        spec = _ASK_ALFA_TOOL_SCHEMAS[name]
        out.append(
            {
                "type": "function",
                "function": {
                    "name": name,
                    "description": spec["description"],
                    "parameters": spec["parameters"],
                },
            }
        )
    return out


def openai_tools_payload(allowed: frozenset[str] | None) -> list[dict[str, Any]]:
    """OpenAI `tools` array. None allowed = all known schemas."""
    names = sorted(_TOOL_SCHEMAS if allowed is None else (n for n in allowed if n in _TOOL_SCHEMAS))
    out: list[dict[str, Any]] = []
    for name in names:
        spec = _TOOL_SCHEMAS[name]
        out.append(
            {
                "type": "function",
                "function": {
                    "name": name,
                    "description": spec["description"],
                    "parameters": spec["parameters"],
                },
            }
        )
    return out
