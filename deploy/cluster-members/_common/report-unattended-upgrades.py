#!/usr/bin/env python3
"""Read-only snapshot of unattended-upgrades / OS identity. ASCII only."""
from __future__ import annotations

import os
import subprocess
from pathlib import Path


def run(cmd: list[str]) -> str:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        out = (p.stdout or "").strip()
        err = (p.stderr or "").strip()
        return out if out else (err or "empty")
    except Exception as exc:
        return "ERR " + type(exc).__name__


def main() -> None:
    host = Path("/etc/hostname").read_text(encoding="utf-8", errors="replace").strip()
    osrel = Path("/etc/os-release").read_text(encoding="utf-8", errors="replace")
    pretty = ""
    for line in osrel.splitlines():
        if line.startswith("PRETTY_NAME="):
            pretty = line.split("=", 1)[1].strip().strip('"')
    print("HOST", host)
    print("OS", pretty)
    print("UU_PKG", run(["dpkg-query", "-W", "-f", "${Status}", "unattended-upgrades"]))
    p20 = Path("/etc/apt/apt.conf.d/20auto-upgrades")
    print("FILE20", "yes" if p20.is_file() else "no")
    if p20.is_file():
        print(p20.read_text(encoding="utf-8", errors="replace").rstrip())
    print("TIMER_DAILY", run(["systemctl", "is-enabled", "apt-daily.timer"]))
    print("TIMER_UPG", run(["systemctl", "is-enabled", "apt-daily-upgrade.timer"]))
    print("SVC_UU", run(["systemctl", "is-enabled", "unattended-upgrades.service"]))
    p50 = Path("/etc/apt/apt.conf.d/50unattended-upgrades")
    if p50.is_file():
        for line in p50.read_text(encoding="utf-8", errors="replace").splitlines():
            s = line.strip()
            if "Automatic-Reboot" in s or s.startswith("Unattended-Upgrade::Allowed-Origins") or '"${distro_id}:${distro_codename}-updates"' in s:
                print("P50", s)
    p51 = Path("/etc/apt/apt.conf.d/51alfa-unattended")
    print("FILE51", "yes" if p51.is_file() else "no")
    nr_drop = Path("/etc/needrestart/conf.d/50-alfa-list-only.conf")
    print("NR_ALFA", "yes" if nr_drop.is_file() else "no")
    print("NEEDRESTART", run(["dpkg-query", "-W", "-f", "${Status}", "needrestart"]))


if __name__ == "__main__":
    main()
