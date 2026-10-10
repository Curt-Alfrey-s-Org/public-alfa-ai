#!/usr/bin/env python3
"""Host-side pool switch daemon on hub hub (operator).

Binds 127.0.0.1 only. Called by alfa-ai-api after admin step-up auth.
See docs/POOL_SWITCH_OPERATOR.md.

Usage:
  ALFA_AI_REPO=/mnt/hub/alfa-ai/repo/alfa-ai python3 pool-switchd.py
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

REPO_DIR = Path(os.environ.get("ALFA_AI_REPO", "/mnt/hub/alfa-ai/repo/alfa-ai")).resolve()
ENV_FILE = REPO_DIR / "deploy" / ".env"
SCRIPT_DIR = REPO_DIR / "deploy" / "cluster-members" / "hub-111"
COMMON = REPO_DIR / "deploy" / "cluster-members" / "_common"
LLC = REPO_DIR / "deploy" / "llamacpp-rpc"
HOST = os.environ.get("ALFA_POOL_SWITCHD_BIND", "127.0.0.1")
PORT = int(os.environ.get("ALFA_POOL_SWITCHD_HOST_PORT", "8421"))

_lock = threading.Lock()
_switch_thread: threading.Thread | None = None

PHASES = (
    "stopping_current",
    "verifying_shards",
    "switching_env",
    "starting_coordinator",
    "loading_model",
    "recreating_litellm",
    "ready",
)

COLD_START = {"inference": 210, "pool35": 240}


def _log(msg: str) -> None:
    ts = datetime.now(tz=UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[pool-switchd] {ts} {msg}", flush=True)


def _read_env_file() -> dict[str, str]:
    out: dict[str, str] = {}
    if not ENV_FILE.is_file():
        return out
    for line in ENV_FILE.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def _expected_bearer() -> str:
    env = _read_env_file()
    return (os.environ.get("ALFA_POOL_SWITCH_BEARER_TOKEN") or env.get("ALFA_POOL_SWITCH_BEARER_TOKEN") or "").strip()


def _redis_password() -> str:
    env = _read_env_file()
    return (os.environ.get("REDIS_PASSWORD") or env.get("REDIS_PASSWORD") or "").strip()


def _redis_set_json(key: str, payload: dict[str, Any], ttl_sec: int = 3600) -> None:
    pw = _redis_password()
    if not pw:
        raise RuntimeError("REDIS_PASSWORD missing in deploy/.env")
    body = json.dumps(payload)
    cmd = [
        "sudo",
        "docker",
        "exec",
        "alfa-redis",
        "redis-cli",
        "-a",
        pw,
        "SET",
        key,
        body,
        "EX",
        str(ttl_sec),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if proc.returncode != 0:
        raise RuntimeError(f"redis-cli SET failed: {proc.stderr or proc.stdout}")


def _redis_get_json(key: str) -> dict[str, Any] | None:
    pw = _redis_password()
    if not pw:
        return None
    cmd = [
        "sudo",
        "docker",
        "exec",
        "alfa-redis",
        "redis-cli",
        "-a",
        pw,
        "GET",
        key,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    if proc.returncode != 0 or not proc.stdout.strip() or proc.stdout.strip() == "(nil)":
        return None
    try:
        return json.loads(proc.stdout.strip())
    except json.JSONDecodeError:
        return None


def _phase_rows(current: str, *, failed: bool = False) -> list[dict[str, Any]]:
    labels = {
        "stopping_current": "Stopping current model",
        "verifying_shards": "Verifying GPU shards",
        "switching_env": "Updating configuration",
        "starting_coordinator": "Starting coordinator",
        "loading_model": "Loading model weights",
        "recreating_litellm": "Restarting inference proxy",
        "ready": "Ready",
    }
    idx = PHASES.index(current) if current in PHASES else -1
    rows = []
    for i, pid in enumerate(PHASES):
        done = i < idx or (not failed and current == "ready" and pid == "ready")
        if pid == current and current == "ready":
            done = True
        rows.append({"id": pid, "label": labels[pid], "done": done})
    return rows


def _update_status(
    *,
    target: str,
    from_pool: str,
    phase: str,
    started_at: str,
    requested_by: str,
    elapsed_sec: int,
    error: str | None = None,
) -> None:
    est = COLD_START.get(target, 240)
    if phase == "ready":
        pct = 100
    elif phase == "loading_model":
        pct = min(95, round(100 * elapsed_sec / est)) if est else 0
    elif phase == "failed":
        pct = 0
    else:
        idx = PHASES.index(phase) if phase in PHASES else 0
        pct = min(40, idx * 8)
    payload = {
        "switching": phase not in ("ready", "failed", "idle"),
        "target_pool": target,
        "from_pool": from_pool,
        "active_pool": target if phase == "ready" else from_pool,
        "phase": phase,
        "phases": _phase_rows(phase, failed=(phase == "failed")),
        "elapsed_sec": elapsed_sec,
        "estimated_pct": pct,
        "estimated_label": True,
        "cold_start_estimate_sec": est,
        "error": error,
        "requested_by_user_id": requested_by,
        "started_at": started_at,
        "updated_at": datetime.now(tz=UTC).isoformat(),
    }
    _redis_set_json("alfaai:pool_switch:status", payload)


def _run_cmd(args: list[str], *, check: bool = True, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    _log(f"exec: {' '.join(args)}")
    return subprocess.run(
        args,
        cwd=str(cwd or REPO_DIR),
        capture_output=True,
        text=True,
        timeout=3600,
        check=check,
    )


def _poll_coordinator_health(timeout_sec: int, started: float, target: str, from_pool: str, req_user: str, started_at: str) -> None:
    url = "http://127.0.0.1:31360/health"
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        elapsed = int(time.time() - started)
        _update_status(
            target=target,
            from_pool=from_pool,
            phase="loading_model",
            started_at=started_at,
            requested_by=req_user,
            elapsed_sec=elapsed,
        )
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:
                if resp.status == 200:
                    data = json.loads(resp.read().decode())
                    if data.get("status") == "ok":
                        return
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, json.JSONDecodeError):
            pass
        time.sleep(5)
    raise RuntimeError("Coordinator /health did not return ok before timeout")


def _recreate_brain_services() -> None:
    deploy = REPO_DIR / "deploy"
    _run_cmd(
        [
            "sudo",
            "docker",
            "compose",
            "--env-file",
            ".env",
            "-f",
            "docker-compose.yml",
            "up",
            "-d",
            "--force-recreate",
            "alfa-ai-litellm",
            "alfa-ai-api",
        ],
        cwd=deploy,
    )
    _run_cmd(["bash", str(COMMON / "wait-litellm-liveliness.sh"), "120"], check=True)


def _switch_worker(target: str, from_pool: str, requested_by: str) -> None:
    started_at = datetime.now(tz=UTC).isoformat()
    t0 = time.time()
    try:
        _update_status(
            target=target,
            from_pool=from_pool,
            phase="stopping_current",
            started_at=started_at,
            requested_by=requested_by,
            elapsed_sec=0,
        )
        if target == "pool35":
            _run_cmd(["sudo", "docker", "stop", "llamacpp-server-111-grev27-pool", "llamacpp-server"], check=False)
            _run_cmd(["sudo", "docker", "rm", "-f", "llamacpp-server-111-grev27-pool", "llamacpp-server"], check=False)
        else:
            _run_cmd(["sudo", "docker", "stop", "llamacpp-server-111-grev35", "llamacpp-server"], check=False)
            _run_cmd(["sudo", "docker", "rm", "-f", "llamacpp-server-111-grev35", "llamacpp-server"], check=False)

        _update_status(
            target=target,
            from_pool=from_pool,
            phase="verifying_shards",
            started_at=started_at,
            requested_by=requested_by,
            elapsed_sec=int(time.time() - t0),
        )
        shards = str(LLC / ("pool35-shards.env" if target == "pool35" else "inference-shards.env"))
        _run_cmd(["bash", str(COMMON / "verify-inference-shards.sh"), shards])

        _update_status(
            target=target,
            from_pool=from_pool,
            phase="switching_env",
            started_at=started_at,
            requested_by=requested_by,
            elapsed_sec=int(time.time() - t0),
        )
        if target == "pool35":
            _run_cmd(["sudo", "bash", str(SCRIPT_DIR / "switch-pool-35b.sh")])
        else:
            _run_cmd(["sudo", "bash", str(SCRIPT_DIR / "switch-pool-27b.sh")])

        _update_status(
            target=target,
            from_pool=from_pool,
            phase="starting_coordinator",
            started_at=started_at,
            requested_by=requested_by,
            elapsed_sec=int(time.time() - t0),
        )
        if target == "pool35":
            _run_cmd(["sudo", "bash", str(SCRIPT_DIR / "deploy-grev35-coordinator.sh")])
        else:
            _run_cmd(["sudo", "bash", str(SCRIPT_DIR / "deploy-grev27-pool-coordinator.sh")])

        _update_status(
            target=target,
            from_pool=from_pool,
            phase="loading_model",
            started_at=started_at,
            requested_by=requested_by,
            elapsed_sec=int(time.time() - t0),
        )
        _poll_coordinator_health(900, t0, target, from_pool, requested_by, started_at)

        _update_status(
            target=target,
            from_pool=from_pool,
            phase="recreating_litellm",
            started_at=started_at,
            requested_by=requested_by,
            elapsed_sec=int(time.time() - t0),
        )
        _recreate_brain_services()

        _update_status(
            target=target,
            from_pool=from_pool,
            phase="ready",
            started_at=started_at,
            requested_by=requested_by,
            elapsed_sec=int(time.time() - t0),
        )
        _log(f"switch to {target} complete")
    except Exception as exc:
        _log(f"switch failed: {exc}")
        _update_status(
            target=target,
            from_pool=from_pool,
            phase="failed",
            started_at=started_at,
            requested_by=requested_by,
            elapsed_sec=int(time.time() - t0),
            error=str(exc)[:500],
        )


def _switch_in_progress() -> bool:
    raw = _redis_get_json("alfaai:pool_switch:status")
    return bool(raw and raw.get("switching"))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: Any) -> None:
        _log(fmt % args)

    def _auth_ok(self) -> bool:
        expected = _expected_bearer()
        if not expected:
            return False
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return False
        return auth[7:].strip() == expected

    def _json_response(self, code: int, body: dict[str, Any]) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_json_body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw.decode() or "{}")

    def do_GET(self) -> None:
        if self.path.rstrip("/") == "/health":
            if not _auth_ok():
                self._json_response(401, {"ok": False})
                return
            self._json_response(200, {"ok": True, "service": "pool-switchd"})
            return
        self.send_error(404)

    def do_POST(self) -> None:
        if self.path.rstrip("/") != "/switch":
            self.send_error(404)
            return
        if not _auth_ok():
            self._json_response(401, {"detail": "Unauthorized"})
            return
        try:
            body = self._read_json_body()
        except json.JSONDecodeError:
            self._json_response(400, {"detail": "Invalid JSON"})
            return
        target = str(body.get("target") or "").strip()
        if target not in ("inference", "pool35"):
            self._json_response(400, {"detail": "Invalid target"})
            return
        from_pool = str(body.get("from_pool") or "").strip() or ("inference" if target == "pool35" else "pool35")
        requested_by = str(body.get("requested_by_user_id") or "").strip() or "unknown"

        global _switch_thread
        with _lock:
            if _switch_in_progress():
                self._json_response(409, {"detail": "Switch already in progress"})
                return
            _switch_thread = threading.Thread(
                target=_switch_worker,
                args=(target, from_pool, requested_by),
                daemon=True,
            )
            _switch_thread.start()
        self._json_response(202, {"accepted": True, "target": target})


def main() -> int:
    if not REPO_DIR.is_dir():
        _log(f"ERROR: repo not found: {REPO_DIR}")
        return 1
    if not _expected_bearer():
        _log("ERROR: ALFA_POOL_SWITCH_BEARER_TOKEN not set in deploy/.env")
        return 1
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    _log(f"listening on {HOST}:{PORT} repo={REPO_DIR}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        _log("shutdown")
    return 0


if __name__ == "__main__":
    sys.exit(main())
