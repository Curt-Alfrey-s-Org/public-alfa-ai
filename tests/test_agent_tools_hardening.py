"""Agent tool hardening (org code review 2026-09-25: grep_repo flag injection,
fetch_url redirects, prefix-only path check, run_cmd blocklist)."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import MagicMock

import pytest

from src.agent import tools
from src.agent.tools import _resolve_read_path, fetch_url, grep_repo, run_cmd


def _need_rg(result: dict) -> None:
    if result.get("error") == "ripgrep (rg) is not installed on this host.":
        pytest.skip("rg not installed")


# ── grep_repo ────────────────────────────────────────────────

def test_grep_repo_pattern_is_never_an_rg_flag(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    marker = tmp_path / "pwned"
    (tmp_path / "a.txt").write_text("literal --pre=sh here\n", encoding="utf-8")
    # A preprocessor that would create the marker if --pre were honoured.
    evil = tmp_path / "evil.sh"
    evil.write_text(f"#!/bin/sh\ntouch {marker}\ncat \"$1\"\n", encoding="utf-8")
    evil.chmod(0o755)

    result = grep_repo(f"--pre={evil}", path=".")
    _need_rg(result)
    assert not marker.exists()
    assert result["ok"] is True
    assert result["matches"] == []  # searched literally; text not present

    result = grep_repo("--pre=sh", path=".")
    assert result["ok"] is True
    assert [m["line"] for m in result["matches"]] == [1]
    assert not marker.exists()


def test_grep_repo_command_shape(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    seen: dict[str, list[str]] = {}

    def fake_run(cmd, **kwargs):
        seen["cmd"] = cmd
        return MagicMock(returncode=1, stdout="", stderr="")

    monkeypatch.setattr(tools.subprocess, "run", fake_run)
    result = grep_repo("-x", path=".", glob="--hidden")
    assert result["ok"] is True
    cmd = seen["cmd"]
    assert "--glob=--hidden" in cmd
    i = cmd.index("-e")
    assert cmd[i + 1] == "-x"
    assert cmd[i + 2] == "--"
    assert cmd[-1] == str(tmp_path.resolve())


# ── fetch_url redirects ──────────────────────────────────────

def _resp(status: int, *, location: str | None = None, url: str = "", text: str = "") -> MagicMock:
    r = MagicMock()
    r.status_code = status
    r.headers = {"content-type": "text/html"}
    if location is not None:
        r.headers["location"] = location
    r.text = text
    r.url = url
    return r


def _mock_client(monkeypatch, responses: list[MagicMock]) -> MagicMock:
    client = MagicMock()
    client.get.side_effect = responses
    client.__enter__ = MagicMock(return_value=client)
    client.__exit__ = MagicMock(return_value=False)
    captured: dict = {}

    def factory(**kwargs):
        captured.update(kwargs)
        return client

    monkeypatch.setattr("src.agent.tools.httpx.Client", factory)
    client.captured = captured
    return client


_HTML = "<html><body>" + "<p>allowlisted documentation body text.</p>" * 20 + "</body></html>"


def test_fetch_url_blocks_redirect_off_allowlist(monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_FETCH_ALLOWLIST", "docs.docker.com")
    client = _mock_client(monkeypatch, [
        _resp(302, location="http://hub/api/admin/health"),
        _resp(200, url="http://hub/api/admin/health", text=_HTML),
    ])
    result = fetch_url("https://docs.docker.com/redirect")
    assert result["ok"] is False
    assert "allowlist" in result["error"].lower()
    assert client.get.call_count == 1
    assert client.captured.get("follow_redirects") is False


def test_fetch_url_blocks_redirect_to_other_scheme(monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_FETCH_ALLOWLIST", "docs.docker.com")
    _mock_client(monkeypatch, [_resp(301, location="file:///etc/passwd")])
    result = fetch_url("https://docs.docker.com/x")
    assert result["ok"] is False


def test_fetch_url_follows_allowlisted_relative_redirect(monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_FETCH_ALLOWLIST", "docs.docker.com")
    client = _mock_client(monkeypatch, [
        _resp(301, location="/engine/"),
        _resp(200, url="https://docs.docker.com/engine/", text=_HTML),
    ])
    result = fetch_url("https://docs.docker.com/old")
    assert result["ok"] is True, result
    assert client.get.call_args_list[1].args[0] == "https://docs.docker.com/engine/"


def test_fetch_url_redirect_loop_capped(monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_FETCH_ALLOWLIST", "docs.docker.com")
    _mock_client(monkeypatch, [_resp(302, location="/loop") for _ in range(20)])
    result = fetch_url("https://docs.docker.com/loop")
    assert result["ok"] is False
    assert "redirect" in result["error"].lower()


# ── read path containment ────────────────────────────────────

def test_absolute_read_path_sibling_prefix_rejected(tmp_path: Path, monkeypatch) -> None:
    ws = tmp_path / "ws"
    ws.mkdir()
    evil = tmp_path / "ws-evil"
    evil.mkdir()
    (evil / "secret.txt").write_text("x", encoding="utf-8")
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(ws))
    monkeypatch.setattr(tools, "audit_root_map", lambda: {})
    with pytest.raises(ValueError):
        _resolve_read_path(str(evil / "secret.txt"))
    (ws / "ok.txt").write_text("y", encoding="utf-8")
    assert _resolve_read_path(str(ws / "ok.txt")) == (ws / "ok.txt").resolve()


# ── run_cmd blocklist ────────────────────────────────────────

@pytest.mark.parametrize("cmd", [
    "rm -rf /",
    "rm  -rf   /",
    "rm -fr /",
    "rm -r -f ~",
    "rm -Rf /*",
    "rm --recursive --force $HOME",
    "cd x && rm -rf /",
    "sudo halt",
    "git reset  --hard HEAD",
    "dd  if=/dev/zero of=/dev/sda",
])
def test_run_cmd_blocks_variants(tmp_path: Path, monkeypatch, cmd: str) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    result = run_cmd(cmd)
    assert result["ok"] is False
    assert "blocked" in result["error"].lower()


def test_run_cmd_allows_ordinary_commands(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(tmp_path))
    (tmp_path / "build").mkdir()
    result = run_cmd("rm -rf build && echo done")
    assert result.get("error") != "Command blocked by safety policy."
    assert not (tmp_path / "build").exists()
