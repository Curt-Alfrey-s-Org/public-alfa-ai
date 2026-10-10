"""Regression tests for the round-2 review fixes (2026-09-26)."""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import bcrypt
import pytest
from fastapi import HTTPException

from src.agent.tools import glob_files
from src.api.routers import admin as admin_router
from src.api.routers import auth as auth_router


# ── bcrypt 72-byte limit (bcrypt>=5 raises instead of truncating) ──

def test_hash_password_rejects_over_72_bytes_with_422() -> None:
    with pytest.raises(HTTPException) as exc:
        auth_router._hash_password("a" * 73)
    assert exc.value.status_code == 422
    # Multi-byte: 25 emoji = 100 bytes, under the 128-char model limit.
    with pytest.raises(HTTPException):
        auth_router._hash_password("\U0001F600" * 25)


def test_hash_password_accepts_72_bytes() -> None:
    pw = "b" * 72
    hashed = auth_router._hash_password(pw)
    assert auth_router._verify_password(pw, hashed)


def test_verify_password_long_guess_is_wrong_not_500() -> None:
    hashed = auth_router._hash_password("correct-horse-1")
    assert auth_router._verify_password("x" * 128, hashed) is False


def test_verify_password_matches_legacy_truncated_hash() -> None:
    # bcrypt<5 hashed only the first 72 bytes of a longer password.
    long_pw = "c" * 100
    legacy_hash = bcrypt.hashpw(long_pw.encode()[:72], bcrypt.gensalt(rounds=4)).decode()
    assert auth_router._verify_password(long_pw, legacy_hash) is True


# ── setup-2fa must not silently disable enrolled 2FA ──

def test_setup_2fa_refuses_when_already_enabled(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[tuple] = []

    class _Store:
        def update_totp(self, *args, **kwargs) -> None:
            calls.append((args, kwargs))

    monkeypatch.setattr(auth_router, "get_user_store", lambda: _Store())
    user = SimpleNamespace(id="u1", email="operator@example.com", is_2fa_enabled=True)
    with pytest.raises(HTTPException) as exc:
        auth_router.setup_2fa(user=user)
    assert exc.value.status_code == 409
    assert calls == []


def test_setup_2fa_allowed_when_not_enabled(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[tuple] = []

    class _Store:
        def update_totp(self, user_id, secret, enabled) -> None:
            calls.append((user_id, enabled))

    monkeypatch.setattr(auth_router, "get_user_store", lambda: _Store())
    user = SimpleNamespace(id="u1", email="operator@example.com", is_2fa_enabled=False)
    out = auth_router.setup_2fa(user=user)
    assert out["secret"]
    assert calls == [("u1", False)]


# ── admin file browser: component-wise containment ──

def test_admin_safe_path_rejects_sibling_prefix_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    ws = tmp_path / "ws"
    ws.mkdir()
    (tmp_path / "ws-evil").mkdir()
    monkeypatch.setattr(admin_router, "_WORKSPACE", ws.resolve())
    assert admin_router._safe_path("sub/file.txt") == (ws / "sub" / "file.txt").resolve()
    with pytest.raises(HTTPException) as exc:
        admin_router._safe_path("../ws-evil/secret.txt")
    assert exc.value.status_code == 403
    with pytest.raises(HTTPException):
        admin_router._safe_path("../../etc/passwd")


# ── glob_files must not list files outside the allowed roots ──

def test_glob_files_dotdot_pattern_stays_in_workspace(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    ws = tmp_path / "ws"
    (ws / "src").mkdir(parents=True)
    (ws / "src" / "ok.py").write_text("x", encoding="utf-8")
    (tmp_path / "outside.txt").write_text("secret", encoding="utf-8")
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(ws))
    monkeypatch.delenv("ALFA_AI_AUDIT_ROOTS", raising=False)
    result = glob_files("../*", path=".")
    assert result["ok"] is True
    assert result["paths"] == []
    result = glob_files("src/*.py", path=".")
    assert result["paths"] == ["src/ok.py"]


def test_glob_files_skips_symlink_escaping_workspace(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    ws = tmp_path / "ws"
    ws.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "secret.txt").write_text("s", encoding="utf-8")
    try:
        (ws / "link").symlink_to(outside, target_is_directory=True)
    except OSError:
        pytest.skip("symlinks not supported")
    monkeypatch.setenv("ALFA_AI_WORKSPACE_ROOT", str(ws))
    monkeypatch.delenv("ALFA_AI_AUDIT_ROOTS", raising=False)
    result = glob_files("link/*.txt", path=".")
    assert result["paths"] == []
