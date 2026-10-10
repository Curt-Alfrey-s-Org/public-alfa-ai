#!/usr/bin/env python3
"""GPU worker monitor. Stdlib only. No Petals.

GET /health, /stats, /logs on MONITOR_PORT (default 31331).
GPU fields match Admin Health GpuInfo (nvidia-smi CSV).
"""

from __future__ import annotations

import json
import os
import platform
import re
import shutil
import socket
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Lock

MONITOR_PORT = int(os.getenv("MONITOR_PORT", "31331"))
WORKER_NAME = os.getenv("WORKER_NAME", socket.gethostname())
WORKER_ROLE = os.getenv("WORKER_ROLE", "gpu-worker")

_cache: dict = {}
_cache_lock = Lock()
_CACHE_TTL = 5


def _run(cmd: list[str], timeout: int = 10) -> str | None:
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return result.stdout.strip() if result.returncode == 0 else None
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None


def _num(value: str) -> float | None:
    try:
        return float(value)
    except (ValueError, TypeError):
        return None


def _gpu_stats() -> list[dict]:
    fields = (
        "index,name,memory.total,memory.used,memory.free,"
        "utilization.gpu,utilization.memory,temperature.gpu,"
        "power.draw,power.limit,fan.speed"
    )
    raw = _run(["nvidia-smi", f"--query-gpu={fields}", "--format=csv,noheader,nounits"])
    if not raw:
        return []
    gpus = []
    for line in raw.splitlines():
        parts = [part.strip() for part in line.split(",")]
        if len(parts) < 11:
            continue
        gpus.append({
            "index": int(float(parts[0])),
            "name": parts[1],
            "vram_total_mb": _num(parts[2]),
            "vram_used_mb": _num(parts[3]),
            "vram_free_mb": _num(parts[4]),
            "gpu_util_pct": _num(parts[5]),
            "mem_util_pct": _num(parts[6]),
            "temp_c": _num(parts[7]),
            "power_draw_w": _num(parts[8]),
            "power_limit_w": _num(parts[9]),
            "fan_pct": _num(parts[10]),
        })
    return gpus


def _nvidia_driver() -> str | None:
    raw = _run(["nvidia-smi", "--query-gpu=driver_version", "--format=csv,noheader"])
    if not raw:
        return None
    return raw.splitlines()[0].strip()


def _system_stats() -> dict:
    info: dict = {
        "hostname": socket.gethostname(),
        "platform": platform.platform(),
        "cpu_count": os.cpu_count(),
    }
    try:
        with open("/proc/stat", encoding="utf-8") as handle:
            parts = handle.readline().split()
        if parts and parts[0] == "cpu":
            idle = int(parts[4])
            total = sum(int(item) for item in parts[1:])
            if total:
                info["cpu_idle_pct"] = round(idle / total * 100, 1)
                info["cpu_used_pct"] = round(100 - (idle / total * 100), 1)
    except (OSError, IndexError, ValueError):
        pass
    try:
        info["load_avg"] = [round(item, 2) for item in os.getloadavg()]
    except OSError:
        pass
    try:
        mem: dict[str, int] = {}
        with open("/proc/meminfo", encoding="utf-8") as handle:
            for line in handle:
                key, value = line.split(":", 1)
                mem[key.strip()] = int(re.sub(r"[^\d]", "", value))
        total_kb = mem.get("MemTotal", 0)
        available_kb = mem.get("MemAvailable", 0)
        info["ram_total_mb"] = round(total_kb / 1024)
        info["ram_available_mb"] = round(available_kb / 1024)
        info["ram_used_mb"] = round((total_kb - available_kb) / 1024)
        if total_kb:
            info["ram_used_pct"] = round((total_kb - available_kb) / total_kb * 100, 1)
    except (OSError, ValueError):
        pass
    try:
        usage = shutil.disk_usage("/")
        info["disk_total_gb"] = round(usage.total / (1024 ** 3), 1)
        info["disk_used_gb"] = round(usage.used / (1024 ** 3), 1)
        info["disk_free_gb"] = round(usage.free / (1024 ** 3), 1)
        if usage.total:
            info["disk_used_pct"] = round(usage.used / usage.total * 100, 1)
    except OSError:
        pass
    return info


def _collect_stats() -> dict:
    with _cache_lock:
        cached = _cache.get("data")
        if cached is not None and _cache.get("ts", 0) > time.time() - _CACHE_TTL:
            return cached
    data = {
        "worker_name": WORKER_NAME,
        "worker_role": WORKER_ROLE,
        "monitor_port": MONITOR_PORT,
        "timestamp": time.time(),
        "timestamp_iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "nvidia_driver": _nvidia_driver(),
        "gpus": _gpu_stats(),
        "system": _system_stats(),
    }
    with _cache_lock:
        _cache["data"] = data
        _cache["ts"] = time.time()
    return data


class MonitorHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        if path == "/health":
            stats = _collect_stats()
            gpu_count = len(stats["gpus"])
            body = json.dumps({
                "status": "healthy" if gpu_count > 0 else "degraded",
                "worker_name": WORKER_NAME,
                "gpu_count": gpu_count,
            }).encode()
            self._respond(200, body)
            return
        if path == "/stats":
            self._respond(200, json.dumps(_collect_stats(), default=str).encode())
            return
        if path == "/logs":
            self._respond(200, b'{"lines":[]}')
            return
        self._respond(404, b'{"error":"not found"}')

    def _respond(self, code: int, body: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: object) -> None:
        return


if __name__ == "__main__":
    print(f"worker-monitor listening on :{MONITOR_PORT} name={WORKER_NAME}")
    server = HTTPServer(("0.0.0.0", MONITOR_PORT), MonitorHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
