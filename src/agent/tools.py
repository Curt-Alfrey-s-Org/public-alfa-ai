from __future__ import annotations

import json
import re
import subprocess
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin, urlparse

import httpx

from src.config import (
    audit_root_map,
    command_timeout_seconds,
    fetch_allowlist_suffixes,
    fetch_max_chars,
    glob_files_max_results,
    grep_repo_default_head_limit,
    max_command_output_chars,
    searxng_base_url,
    web_search_enabled,
    web_search_max_results,
    workspace_root,
)

BLOCKED_FRAGMENTS = (
    "rm -rf /",
    "shutdown",
    "reboot",
    "poweroff",
    "mkfs",
    "dd if=",
    ":(){:|:&};:",
    "git reset --hard",
    "--no-preserve-root",
)

# Defence in depth only: run_cmd is mutate-gated (never in the read-only tool set),
# and a substring/regex blocklist cannot make ``shell=True`` safe. These patterns
# close the cheapest bypasses of BLOCKED_FRAGMENTS (extra spaces/tabs, flag order
# such as ``rm -fr /`` or ``rm -r -f ~``, ``init 0``/``halt``). Matched against the
# lower-cased command with runs of whitespace collapsed to one space.
_BLOCKED_PATTERNS = (
    # rm with both recursive and force flags (any order/grouping) aimed at /, ~, $HOME or /*
    re.compile(
        r"\brm(?=[^;&|]*\s-(?:[a-z]*r[a-z]*|-recursive)\b)(?=[^;&|]*\s-(?:[a-z]*f[a-z]*|-force)\b)"
        r"[^;&|]*\s(?:/\*?|~/?|\$home|\$\{home\})(?=\s|$|[;&|])"
    ),
    re.compile(r"\b(?:halt|init\s+0|init\s+6|telinit\s+0)\b"),
    re.compile(r"\bdd\s+[^;&|]*\bif="),
    re.compile(r":\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"),
    re.compile(r"\bgit\s+reset\s+[^;&|]*--hard\b"),
)


def _command_blocked(command: str) -> bool:
    lowered = command.lower()
    normalized = re.sub(r"\s+", " ", lowered)
    if any(fragment in lowered or fragment in normalized for fragment in BLOCKED_FRAGMENTS):
        return True
    return any(pattern.search(normalized) for pattern in _BLOCKED_PATTERNS)

_FETCH_USER_AGENT = "ALFa-AI-Research/1.0"
_FETCH_MAX_REDIRECTS = 5
_REDIRECT_STATUSES = frozenset({301, 302, 303, 307, 308})
_SCRIPT_STYLE_RE = re.compile(r"(?is)<(script|style)[^>]*>.*?</\1>")
_TAG_RE = re.compile(r"(?is)<[^>]+>")


def _relative_display_path(item: Path) -> str:
    """Path for agent output: workspace-relative or audit-root alias."""
    resolved = item.resolve()
    base = workspace_root()
    try:
        return str(resolved.relative_to(base))
    except ValueError:
        pass
    for name, root in audit_root_map().items():
        root_resolved = root.resolve()
        try:
            rel = resolved.relative_to(root_resolved)
            suffix = rel.as_posix() if rel.parts else ""
            return f"{name}/{suffix}" if suffix else name
        except ValueError:
            continue
    return str(resolved)


def _resolve_write_path(path: str) -> Path:
    base = workspace_root()
    candidate = (base / path).expanduser().resolve()
    try:
        candidate.relative_to(base)
    except ValueError as exc:
        raise ValueError(f"Path escapes workspace root: {path}") from exc
    return candidate


def _resolve_read_path(path: str) -> Path:
    """Workspace-relative paths, audit alias (name/rel), or absolute under allowed roots."""
    raw = path.strip()
    if not raw:
        raise ValueError("Path must not be empty.")

    for name, root in audit_root_map().items():
        prefix = f"{name}/"
        if raw == name or raw.startswith(prefix):
            rel = raw[len(name) :].lstrip("/\\")
            candidate = (root / rel).resolve() if rel else root.resolve()
            try:
                candidate.relative_to(root)
            except ValueError as exc:
                raise ValueError(f"Path escapes audit root {name}: {path}") from exc
            return candidate

    base = workspace_root()
    candidate = Path(raw).expanduser()
    if candidate.is_absolute():
        resolved = candidate.resolve()
        # Component-wise containment (not a string prefix): /srv/ws-evil must not
        # pass for workspace root /srv/ws (org review 2026-09-25).
        if _is_within(resolved, base):
            return resolved
        for root in audit_root_map().values():
            if _is_within(resolved, root):
                return resolved
        raise ValueError(f"Path not in workspace or audit roots: {path}")

    resolved = (base / raw).resolve()
    try:
        resolved.relative_to(base)
    except ValueError as exc:
        raise ValueError(f"Path escapes workspace root: {path}") from exc
    if resolved.exists():
        return resolved
    for _name, root in audit_root_map().items():
        alt = (root / raw).resolve()
        try:
            alt.relative_to(root.resolve())
        except ValueError:
            continue
        if alt.exists():
            return alt
    return resolved


def _is_within(path: Path, root: Path) -> bool:
    """True when resolved *path* is *root* or inside it (component-wise)."""
    try:
        path.relative_to(root.resolve())
        return True
    except ValueError:
        return False


def _resolve_in_workspace(path: str) -> Path:
    return _resolve_write_path(path)


def _host_allowed(hostname: str) -> bool:
    host = (hostname or "").strip().lower().rstrip(".")
    if not host:
        return False
    for suffix in fetch_allowlist_suffixes():
        if host == suffix or host.endswith(f".{suffix}"):
            return True
    return False


def _truncate_text(text: str, limit: int) -> tuple[str, bool]:
    if len(text) <= limit:
        return text, False
    return text[:limit], True


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self._parts: list[str] = []
        self._skip_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in {"script", "style", "noscript"}:
            self._skip_depth += 1

    def handle_endtag(self, tag: str) -> None:
        if tag in {"script", "style", "noscript"} and self._skip_depth > 0:
            self._skip_depth -= 1

    def handle_data(self, data: str) -> None:
        if self._skip_depth == 0:
            stripped = data.strip()
            if stripped:
                self._parts.append(stripped)

    def text(self) -> str:
        return re.sub(r"\n{3,}", "\n\n", "\n".join(self._parts))


def _html_to_text(html: str) -> str:
    cleaned = _SCRIPT_STYLE_RE.sub(" ", html)
    cleaned = _TAG_RE.sub("\n", cleaned)
    parser = _TextExtractor()
    parser.feed(cleaned)
    parser.close()
    return parser.text()


def list_dir(path: str = ".") -> dict:
    try:
        target = _resolve_read_path(path)
        if not target.exists():
            return {"ok": False, "error": f"Path not found: {path}"}
        if not target.is_dir():
            return {"ok": False, "error": f"Not a directory: {path}"}
        entries = sorted(item.name for item in target.iterdir())
        return {"ok": True, "path": str(target), "entries": entries}
    except Exception as exc:  # pragma: no cover - defensive
        return {"ok": False, "error": str(exc)}


def read_file(path: str, max_chars: int = 12000) -> dict:
    try:
        target = _resolve_read_path(path)
        if not target.exists():
            return {"ok": False, "error": f"File not found: {path}"}
        if not target.is_file():
            return {"ok": False, "error": f"Not a file: {path}"}
        content = target.read_text(encoding="utf-8")
        safe_max = max(1000, min(max_chars, 200000))
        truncated = len(content) > safe_max
        shown = content[:safe_max]
        return {
            "ok": True,
            "path": str(target),
            "content": shown,
            "truncated": truncated,
        }
    except Exception as exc:  # pragma: no cover - defensive
        return {"ok": False, "error": str(exc)}


def create_file(path: str, contents: str) -> dict:
    try:
        target = _resolve_in_workspace(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents, encoding="utf-8")
        return {"ok": True, "path": str(target), "bytes": len(contents.encode("utf-8"))}
    except Exception as exc:  # pragma: no cover - defensive
        return {"ok": False, "error": str(exc)}


def edit_file(
    path: str,
    old_string: str,
    new_string: str,
    *,
    replace_all: bool = False,
) -> dict:
    try:
        if not old_string:
            return {"ok": False, "error": "old_string must not be empty."}
        target = _resolve_in_workspace(path)
        if not target.exists():
            return {"ok": False, "error": f"File not found: {path}"}
        if not target.is_file():
            return {"ok": False, "error": f"Not a file: {path}"}
        content = target.read_text(encoding="utf-8")
        count = content.count(old_string)
        if count == 0:
            return {"ok": False, "error": "old_string not found in file."}
        if not replace_all and count > 1:
            return {
                "ok": False,
                "error": f"old_string appears {count} times; set replace_all=true or use a unique snippet.",
            }
        if replace_all:
            updated = content.replace(old_string, new_string)
            replacements = count
        else:
            updated = content.replace(old_string, new_string, 1)
            replacements = 1
        target.write_text(updated, encoding="utf-8")
        return {
            "ok": True,
            "path": str(target),
            "replacements": replacements,
            "bytes": len(updated.encode("utf-8")),
        }
    except Exception as exc:  # pragma: no cover - defensive
        return {"ok": False, "error": str(exc)}


def glob_files(pattern: str, path: str = ".") -> dict:
    try:
        target = _resolve_read_path(path)
        if not target.exists():
            return {"ok": False, "error": f"Path not found: {path}"}
        if not target.is_dir():
            return {"ok": False, "error": f"Not a directory: {path}"}
        # Path.glob honours ".." segments and follows symlinks, so a pattern such as
        # "../../etc/*" listed files outside every allowed root. Only report matches
        # that resolve inside the workspace or an audit root (round-2 review 2026-09-26).
        allowed_roots = [workspace_root(), *audit_root_map().values()]
        cap = glob_files_max_results()
        matches: list[str] = []
        truncated = False
        for item in sorted(target.glob(pattern)):
            if not item.is_file():
                continue
            resolved = item.resolve()
            if not any(_is_within(resolved, root) for root in allowed_roots):
                continue
            matches.append(_relative_display_path(item))
            if len(matches) >= cap:
                truncated = True
                break
        return {"ok": True, "pattern": pattern, "paths": matches, "truncated": truncated}
    except Exception as exc:  # pragma: no cover - defensive
        return {"ok": False, "error": str(exc)}


def grep_repo(
    pattern: str,
    path: str = ".",
    glob: str | None = None,
    head_limit: int | None = None,
) -> dict:
    if not pattern.strip():
        return {"ok": False, "error": "Pattern must not be empty."}
    try:
        target = _resolve_read_path(path)
        if not target.exists():
            return {"ok": False, "error": f"Path not found: {path}"}
        limit = head_limit if head_limit is not None else grep_repo_default_head_limit()
        limit = max(1, min(int(limit), grep_repo_default_head_limit() * 10))
        cmd = [
            "rg",
            "--json",
            "--line-number",
            "--max-count",
            str(limit + 1),
        ]
        if glob:
            # ``--glob=VALUE`` form so a glob starting with "-" is never parsed as a flag.
            cmd.append(f"--glob={glob}")
        # ``-e PATTERN`` + ``--``: a model-supplied pattern such as ``--pre=sh`` must be
        # searched for literally, never parsed as an rg option (org review 2026-09-25).
        cmd.extend(["-e", pattern, "--", str(target)])
        completed = subprocess.run(
            cmd,
            check=False,
            capture_output=True,
            text=True,
            timeout=command_timeout_seconds(),
        )
        if completed.returncode not in {0, 1}:
            err = (completed.stderr or completed.stdout or "rg failed").strip()
            return {"ok": False, "error": err[:500]}
        matches: list[dict[str, str | int]] = []
        truncated = False
        for line in completed.stdout.splitlines():
            if not line.strip():
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("type") != "match":
                continue
            if len(matches) >= limit:
                truncated = True
                break
            data = event.get("data", {})
            file_path = data.get("path", {}).get("text", "")
            line_no = data.get("line_number", 0)
            text = data.get("lines", {}).get("text", "").strip()
            rel = _relative_display_path(Path(file_path))
            matches.append({"file": rel, "line": int(line_no), "text": text})
        return {"ok": True, "pattern": pattern, "matches": matches, "truncated": truncated}
    except FileNotFoundError:
        return {"ok": False, "error": "ripgrep (rg) is not installed on this host."}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "grep_repo timed out."}
    except Exception as exc:  # pragma: no cover - defensive
        return {"ok": False, "error": str(exc)}


def fetch_url(url: str, max_chars: int | None = None) -> dict:
    parsed = urlparse(url.strip())
    if parsed.scheme not in {"http", "https"}:
        return {"ok": False, "error": "URL must use http or https."}
    if not _host_allowed(parsed.hostname or ""):
        return {
            "ok": False,
            "error": f"Host not on fetch allowlist: {parsed.hostname or ''}",
        }
    limit = max_chars if max_chars is not None else fetch_max_chars()
    limit = max(500, min(int(limit), fetch_max_chars()))
    try:
        # Redirects are followed by hand so every hop is re-checked against the
        # scheme + host allowlist; httpx follow_redirects=True would happily land
        # on an off-allowlist (e.g. LAN) host (org review 2026-09-25).
        with httpx.Client(
            timeout=httpx.Timeout(15.0, connect=10.0),
            follow_redirects=False,
            headers={"User-Agent": _FETCH_USER_AGENT},
        ) as client:
            current = url.strip()
            response = client.get(current)
            hops = 0
            while response.status_code in _REDIRECT_STATUSES:
                location = (response.headers.get("location") or "").strip()
                if not location:
                    break
                hops += 1
                if hops > _FETCH_MAX_REDIRECTS:
                    return {"ok": False, "error": "fetch_url: too many redirects"}
                current = urljoin(current, location)
                next_parsed = urlparse(current)
                if next_parsed.scheme not in {"http", "https"}:
                    return {"ok": False, "error": "Redirect target must use http or https."}
                if not _host_allowed(next_parsed.hostname or ""):
                    return {
                        "ok": False,
                        "error": f"Redirect to host not on fetch allowlist: {next_parsed.hostname or ''}",
                    }
                response = client.get(current)
        if response.status_code >= 400:
            return {"ok": False, "error": f"HTTP {response.status_code} for {url}"}
        content_type = (response.headers.get("content-type") or "").lower()
        body = response.text
        if "html" in content_type or "<html" in body[:500].lower():
            text = _html_to_text(body)
        else:
            text = body
        if len(text.strip()) < 200:
            return {"ok": False, "error": "no readable content"}
        shown, truncated = _truncate_text(text, limit)
        return {
            "ok": True,
            "url": str(response.url),
            "content": shown,
            "truncated": truncated,
        }
    except httpx.TimeoutException:
        return {"ok": False, "error": "fetch_url timed out."}
    except httpx.HTTPError as exc:
        return {"ok": False, "error": f"fetch failed: {exc}"}
    except Exception as exc:  # pragma: no cover - defensive
        return {"ok": False, "error": str(exc)}


def web_search(query: str, max_results: int | None = None) -> dict:
    """LAN SearXNG JSON search (operator missions only; gated by env)."""
    if not web_search_enabled():
        return {"ok": False, "error": "web_search disabled"}
    base = searxng_base_url()
    if not base:
        return {"ok": False, "error": "ALFA_AI_SEARXNG_URL not configured"}
    q = query.strip()
    if not q:
        return {"ok": False, "error": "query is required"}
    limit = max_results if max_results is not None else web_search_max_results()
    limit = max(1, min(int(limit), web_search_max_results()))
    per_result_chars = max(200, min(fetch_max_chars() // max(limit, 1), 2000))
    try:
        with httpx.Client(
            timeout=httpx.Timeout(20.0, connect=10.0),
            follow_redirects=True,
            headers={"User-Agent": _FETCH_USER_AGENT},
        ) as client:
            response = client.get(
                f"{base}/search",
                params={"q": q, "format": "json", "categories": "general"},
            )
        if response.status_code >= 400:
            return {"ok": False, "error": f"SearXNG HTTP {response.status_code}"}
        payload = response.json()
        if not isinstance(payload, dict):
            return {"ok": False, "error": "invalid SearXNG JSON response"}
        raw_results = payload.get("results")
        if not isinstance(raw_results, list):
            return {"ok": False, "error": "SearXNG response missing results array"}
        results: list[dict[str, str]] = []
        for item in raw_results[:limit]:
            if not isinstance(item, dict):
                continue
            title = str(item.get("title") or "").strip()
            url = str(item.get("url") or "").strip()
            content = str(item.get("content") or item.get("snippet") or "").strip()
            if not url:
                continue
            shown, _ = _truncate_text(content, per_result_chars)
            results.append({"title": title, "url": url, "content": shown})
        if not results:
            return {"ok": False, "error": "no search results"}
        return {
            "ok": True,
            "query": q,
            "results": results,
            "truncated": len(raw_results) > limit,
        }
    except httpx.TimeoutException:
        return {"ok": False, "error": "web_search timed out"}
    except httpx.HTTPError as exc:
        return {"ok": False, "error": f"web_search failed: {exc}"}
    except json.JSONDecodeError:
        return {"ok": False, "error": "SearXNG returned non-JSON (enable format: json in settings)"}
    except Exception as exc:  # pragma: no cover - defensive
        return {"ok": False, "error": str(exc)}


def run_cmd(command: str, cwd: str | None = None) -> dict:
    if _command_blocked(command):
        return {"ok": False, "error": "Command blocked by safety policy."}

    try:
        workdir = _resolve_write_path(cwd or ".")
        if not workdir.is_dir():
            return {"ok": False, "error": f"Invalid cwd: {cwd}"}

        completed = subprocess.run(
            command,
            cwd=str(workdir),
            shell=True,
            check=False,
            capture_output=True,
            text=True,
            timeout=command_timeout_seconds(),
        )
        limit = max_command_output_chars()
        stdout = completed.stdout[:limit]
        stderr = completed.stderr[:limit]
        return {
            "ok": completed.returncode == 0,
            "returncode": completed.returncode,
            "stdout": stdout,
            "stderr": stderr,
            "cwd": str(workdir),
            "truncated": len(completed.stdout) > limit or len(completed.stderr) > limit,
        }
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "Command timed out."}
    except Exception as exc:  # pragma: no cover - defensive
        return {"ok": False, "error": str(exc)}
