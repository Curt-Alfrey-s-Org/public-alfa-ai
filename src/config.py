import os
from pathlib import Path

from dotenv import load_dotenv

# Load from repo root so `python -m src.main` works from any cwd (e.g. systemd, scripts).
_REPO_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(_REPO_ROOT / ".env")
load_dotenv()  # optional overrides from process cwd

_DEFAULT_FETCH_ALLOWLIST = (
    "learn.microsoft.com,docs.docker.com,docs.python.org,fastapi.tiangolo.com,"
    "vite.dev,nginx.org,postgresql.org,redis.io,github.com,compose-spec.io,"
    "open.gsa.gov,api.data.gov,12factor.net,docs.kernel.org,raw.githubusercontent.com"
)


def get(key: str, default: str = "") -> str:
    return os.environ.get(key, default)


def repo_root() -> Path:
    return _REPO_ROOT


def workspace_root() -> Path:
    configured = get("ALFA_AI_WORKSPACE_ROOT", "").strip()
    if configured:
        return Path(configured).expanduser().resolve()
    return Path.cwd().resolve()


def audit_root_map() -> dict[str, Path]:
    """Named read-only audit roots: ALFA_AI_AUDIT_ROOTS=name=/path,name2=/path2."""
    raw = get("ALFA_AI_AUDIT_ROOTS", "").strip()
    if not raw:
        return {}
    roots: dict[str, Path] = {}
    for entry in raw.split(","):
        piece = entry.strip()
        if not piece or "=" not in piece:
            continue
        name, path_str = piece.split("=", 1)
        name = name.strip()
        if not name:
            continue
        target = Path(path_str.strip()).expanduser().resolve()
        if target.is_dir():
            roots[name] = target
    return roots


def command_timeout_seconds() -> int:
    raw = get("ALFA_AI_COMMAND_TIMEOUT_SEC", "30").strip()
    try:
        value = int(raw)
    except ValueError:
        return 30
    return max(1, min(value, 300))


def max_command_output_chars() -> int:
    raw = get("ALFA_AI_MAX_COMMAND_OUTPUT_CHARS", "12000").strip()
    try:
        value = int(raw)
    except ValueError:
        return 12000
    return max(1000, min(value, 100000))


def _bounded_int(key: str, default: int, minimum: int, maximum: int) -> int:
    raw = get(key, str(default)).strip()
    try:
        value = int(raw)
    except ValueError:
        return default
    return max(minimum, min(value, maximum))


def agent_model() -> str:
    return get("ALFA_AI_AGENT_MODEL", "frontier-code").strip() or "frontier-code"


def agent_fallback_model() -> str:
    return get("ALFA_AI_AGENT_FALLBACK_MODEL", "agent").strip() or "agent"


def agent_max_steps() -> int:
    return _bounded_int("ALFA_AI_AGENT_MAX_STEPS", 6, 1, 20)


def agent_synthesis_max_tokens() -> int:
    return _bounded_int("ALFA_AI_AGENT_SYNTHESIS_MAX_TOKENS", 2048, 256, 8192)


def agent_mutate_enabled() -> bool:
    """When false (default), agent runs block create_file/edit_file/run_cmd unless role allows."""
    raw = get("ALFA_AI_AGENT_MUTATE_ENABLED", "0").strip().lower()
    return raw in ("1", "true", "yes", "on")


def native_tools_enabled() -> bool:
    """When true, agent loop sends OpenAI `tools` and prefers `tool_calls`.

    Default off: JSON-in-text remains the 27B path. Enable for Pool80 / 27B smoke.
    Official: https://platform.openai.com/docs/guides/function-calling
    """
    raw = get("ALFA_AI_NATIVE_TOOLS", "0").strip().lower()
    return raw in ("1", "true", "yes", "on")


def mcp_enabled() -> bool:
    """When true, mount Streamable HTTP MCP for inspectable catalog only (brain :8420 LAN).

    Default off. Official: https://py.sdk.modelcontextprotocol.io/run/asgi/
    """
    raw = get("ALFA_AI_MCP_ENABLED", "0").strip().lower()
    return raw in ("1", "true", "yes", "on")


def mcp_allowed_hosts() -> list[str]:
    """Host allowlist for MCP transport security (DNS rebinding protection).

    Official: https://py.sdk.modelcontextprotocol.io/run/deploy/
    """
    hosts = ["127.0.0.1", "localhost", "127.0.0.1:*", "localhost:*"]
    extra = get("ALFA_AI_MCP_ALLOWED_HOSTS", "").strip()
    if extra:
        for part in extra.split(","):
            token = part.strip()
            if token and token not in hosts:
                hosts.append(token)
    return hosts


def fetch_max_chars() -> int:
    return _bounded_int("ALFA_AI_FETCH_MAX_CHARS", 6000, 500, 50000)


def tool_result_max_chars() -> int:
    return _bounded_int("ALFA_AI_TOOL_RESULT_MAX_CHARS", 8000, 1000, 100000)


def fetch_allowlist_suffixes() -> tuple[str, ...]:
    raw = get("ALFA_AI_FETCH_ALLOWLIST", _DEFAULT_FETCH_ALLOWLIST).strip()
    if not raw:
        raw = _DEFAULT_FETCH_ALLOWLIST
    parts = [item.strip().lower() for item in raw.split(",") if item.strip()]
    return tuple(parts)


def glob_files_max_results() -> int:
    return _bounded_int("ALFA_AI_GLOB_MAX_RESULTS", 200, 10, 1000)


def grep_repo_default_head_limit() -> int:
    return _bounded_int("ALFA_AI_GREP_HEAD_LIMIT", 50, 1, 500)


def run_input_max_file_chars() -> int:
    return _bounded_int("ALFA_AI_RUN_INPUT_MAX_FILE_CHARS", 200000, 1000, 2000000)


def run_input_max_files() -> int:
    return _bounded_int("ALFA_AI_RUN_INPUT_MAX_FILES", 10, 1, 50)


def alfa_ai_data_dir() -> Path:
    """Persistent ALFa data root (memory, artifacts). Default: workspace/.alfa_ai."""
    configured = get("ALFA_AI_DATA", "").strip()
    if configured:
        path = Path(configured).expanduser().resolve()
    else:
        path = (workspace_root() / ".alfa_ai").resolve()
    path.mkdir(parents=True, exist_ok=True)
    return path


def memory_load_max_chars() -> int:
    return _bounded_int("ALFA_AI_MEMORY_MAX_CHARS", 4000, 500, 32000)


def memory_max_file_bytes() -> int:
    return _bounded_int("ALFA_AI_MEMORY_MAX_FILE_BYTES", 65536, 4096, 524288)


def memory_max_entries() -> int:
    return _bounded_int("ALFA_AI_MEMORY_MAX_ENTRIES", 50, 5, 500)


def web_search_enabled() -> bool:
    raw = get("ALFA_AI_WEB_SEARCH_ENABLED", "0").strip().lower()
    return raw in ("1", "true", "yes", "on")


def searxng_base_url() -> str:
    return get("ALFA_AI_SEARXNG_URL", "http://alfa-searxng:8080").strip().rstrip("/")


def web_search_max_results() -> int:
    return _bounded_int("ALFA_AI_WEB_SEARCH_MAX_RESULTS", 5, 1, 20)


def judge_enabled() -> bool:
    """Independent LLM judge dual-check (L1). Default off — fail closed."""
    raw = get("ALFA_AI_JUDGE_ENABLED", "0").strip().lower()
    return raw in ("1", "true", "yes", "on")


def judge_model() -> str:
    """LiteLLM alias or Ollama model name for judge."""
    return get("ALFA_AI_JUDGE_MODEL", "judge").strip() or "judge"


def judge_api_base() -> str:
    """Optional direct OpenAI-compat base (e.g. http://orchestrator/v1)."""
    return get("ALFA_AI_JUDGE_API_BASE", "").strip().rstrip("/")


def judge_api_key() -> str:
    return get("ALFA_AI_JUDGE_API_KEY", "").strip()


def judge_max_tokens() -> int:
    return _bounded_int("ALFA_AI_JUDGE_MAX_TOKENS", 1024, 128, 4096)


def judge_on_set() -> frozenset[str]:
    """Contexts that trigger judge: high_risk, research, merge, freeform, run_command, all."""
    raw = get("ALFA_AI_JUDGE_ON", "high_risk,research,merge,freeform,run_command").strip()
    if not raw:
        return frozenset()
    return frozenset(p.strip().lower() for p in raw.split(",") if p.strip())


def sleep_curator_enabled() -> bool:
    raw = get("ALFA_AI_SLEEP_CURATOR_ENABLED", "0").strip().lower()
    return raw in ("1", "true", "yes", "on")
