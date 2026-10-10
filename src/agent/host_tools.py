"""Read-only host fact gathering tools (local processes, docker, disk, logs)."""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

from src.config import audit_root_map, max_command_output_chars, workspace_root

_LOG_GLOB = re.compile(r"\.(log|journal)$", re.I)
_MAX_LOG_BYTES = 256_000
_MAX_DOCKER_LOG_LINES = 200
_MAX_PROCESS_LINES = 40


def _truncate(text: str, limit: int | None = None) -> str:
    cap = limit or max_command_output_chars()
    if len(text) <= cap:
        return text
    return text[:cap] + "\n...(truncated)"


def _run_local(command: str, *, timeout: int = 30) -> dict:
    try:
        completed = subprocess.run(
            command,
            shell=True,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        stdout = _truncate(completed.stdout)
        stderr = _truncate(completed.stderr)
        return {
            "ok": completed.returncode == 0,
            "returncode": completed.returncode,
            "stdout": stdout,
            "stderr": stderr,
        }
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "command timed out"}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


def host_processes(limit: int = _MAX_PROCESS_LINES) -> dict:
    """Top CPU/RSS process snapshot (read-only)."""
    lim = max(5, min(int(limit), 100))
    if os.name == "nt":
        cmd = (
            "powershell -NoProfile -Command "
            f"\"Get-Process | Sort-Object CPU -Descending | Select-Object -First {lim} "
            "Name,Id,CPU,WorkingSet | Format-Table -AutoSize\""
        )
    else:
        cmd = f"ps aux --sort=-%cpu | head -n {lim + 1}"
    result = _run_local(cmd)
    result["tool"] = "host_processes"
    return result


def disk_mem() -> dict:
    """Disk free and memory summary (read-only)."""
    if os.name == "nt":
        out = _run_local(
            "powershell -NoProfile -Command "
            "\"Get-PSDrive -PSProvider FileSystem | Select-Object Name,Used,Free; "
            "Get-CimInstance Win32_OperatingSystem | "
            "Select-Object TotalVisibleMemorySize,FreePhysicalMemory\""
        )
    else:
        df = _run_local("df -h 2>/dev/null || df")
        mem = _run_local("grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo 2>/dev/null || true")
        out = {
            "ok": df.get("ok") or mem.get("ok"),
            "stdout": (df.get("stdout") or "") + "\n" + (mem.get("stdout") or ""),
            "stderr": (df.get("stderr") or "") + (mem.get("stderr") or ""),
        }
    out["tool"] = "disk_mem"
    return out


def docker_ps() -> dict:
    """Local docker container list (requires docker CLI/socket)."""
    result = _run_local("docker ps -a --no-trunc --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>&1")
    result["tool"] = "docker_ps"
    if "not found" in (result.get("stderr") or "").lower() or "not found" in (result.get("stdout") or "").lower():
        result["ok"] = False
        result["error"] = "docker CLI not available in worker container"
    return result


def docker_stats() -> dict:
    """One-shot per-container CPU% and memory (requires docker CLI/socket)."""
    fmt = "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"
    result = _run_local(f"docker stats --no-stream --format '{fmt}' 2>&1", timeout=60)
    result["tool"] = "docker_stats"
    combined = ((result.get("stderr") or "") + (result.get("stdout") or "")).lower()
    if "not found" in combined or "cannot connect to the docker daemon" in combined:
        result["ok"] = False
        result["error"] = "docker CLI not available in worker container"
    return result


def docker_logs(container: str, tail: int = 50) -> dict:
    """Tail container logs (capped, read-only)."""
    name = (container or "").strip()
    if not name or not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", name):
        return {"ok": False, "error": "invalid container name"}
    lines = max(10, min(int(tail), _MAX_DOCKER_LOG_LINES))
    result = _run_local(f"docker logs --tail {lines} {name} 2>&1", timeout=45)
    result["tool"] = "docker_logs"
    result["container"] = name
    return result


def _log_path_allowed(path: Path) -> bool:
    resolved = path.resolve()
    if resolved.is_dir():
        return False
    text = str(resolved)
    if text.startswith("/var/log"):
        return True
    base = workspace_root()
    try:
        resolved.relative_to(base)
        return _LOG_GLOB.search(resolved.name) is not None
    except ValueError:
        pass
    for root in audit_root_map().values():
        try:
            resolved.relative_to(root.resolve())
            return _LOG_GLOB.search(resolved.name) is not None or resolved.suffix in {".log", ".journal"}
        except ValueError:
            continue
    return False


def log_grep(path: str, pattern: str, head_limit: int = 50) -> dict:
    """Grep allowlisted log files only."""
    raw = (path or "").strip()
    pat = (pattern or "").strip()
    if not raw or not pat:
        return {"ok": False, "error": "path and pattern required"}
    candidate = Path(raw).expanduser()
    if not candidate.is_absolute():
        candidate = (workspace_root() / raw).resolve()
    else:
        candidate = candidate.resolve()
    if not candidate.is_file():
        return {"ok": False, "error": f"log file not found: {candidate}"}
    if not _log_path_allowed(candidate):
        return {"ok": False, "error": "path not in allowlisted log locations"}
    try:
        if candidate.stat().st_size > _MAX_LOG_BYTES:
            return {"ok": False, "error": "log file too large for grep (max 256KB)"}
        text = candidate.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        return {"ok": False, "error": str(exc)}
    try:
        rx = re.compile(pat)
    except re.error as exc:
        return {"ok": False, "error": f"invalid pattern: {exc}"}
    lim = max(1, min(int(head_limit), 200))
    matches = [line for line in text.splitlines() if rx.search(line)][:lim]
    return {
        "ok": True,
        "path": str(candidate),
        "pattern": pat,
        "match_count": len(matches),
        "lines": matches,
        "tool": "log_grep",
    }
