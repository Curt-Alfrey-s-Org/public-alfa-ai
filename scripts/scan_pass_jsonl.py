#!/usr/bin/env python3
"""Scan JSONL training packs for likely secrets before hub publish.

Usage:
  python scripts/scan_pass_jsonl.py path/to/pack
  python scripts/scan_pass_jsonl.py path/to/pack --json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# Patterns aligned with public-surface / secrets policy (heuristic, not exhaustive).
PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("jwt_like", re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")),
    ("bearer_token", re.compile(r"(?i)bearer\s+[A-Za-z0-9._-]{20,}")),
    ("api_key_assign", re.compile(r"(?i)(api[_-]?key|secret|password|token)\s*[=:]\s*['\"]?[A-Za-z0-9._-]{12,}")),
    ("private_key_block", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("postgres_url", re.compile(r"postgresql://[^@]+@")),
    ("redis_url", re.compile(r"redis://]+@")),
    ("sk_prefix", re.compile(r"\bsk-[A-Za-z0-9]{20,}\b")),
]


def redact_text(text: str) -> tuple[str, int]:
    """Replace heuristic secret spans with [REDACTED_<PATTERN>] placeholders."""
    redacted = text
    total = 0
    for name, pat in PATTERNS:
        placeholder = f"[REDACTED_{name.upper()}]"
        redacted, count = pat.subn(placeholder, redacted)
        total += count
    return redacted, total


def scan_text(text: str) -> list[dict[str, str]]:
    hits: list[dict[str, str]] = []
    for name, pat in PATTERNS:
        if pat.search(text):
            hits.append({"pattern": name, "snippet": text[:120].replace("\n", " ")})
    return hits


def scan_file(path: Path) -> list[dict[str, str]]:
    findings: list[dict[str, str]] = []
    if not path.is_file():
        return findings
    for lineno, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
            blob = json.dumps(row, ensure_ascii=True)
        except json.JSONDecodeError:
            blob = line
        for hit in scan_text(blob):
            findings.append({"file": str(path), "line": str(lineno), **hit})
    return findings


def scan_pack(pack_dir: Path) -> dict:
    files = sorted(pack_dir.glob("*.jsonl"))
    all_hits: list[dict[str, str]] = []
    for f in files:
        all_hits.extend(scan_file(f))
    return {
        "ok": len(all_hits) == 0,
        "pack_dir": str(pack_dir),
        "jsonl_files": [str(f) for f in files],
        "hit_count": len(all_hits),
        "hits": all_hits[:50],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Secret-scan JSONL train pack")
    parser.add_argument("pack_dir", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    report = scan_pack(args.pack_dir.resolve())
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=True))
    else:
        print(f"ok={report['ok']} hits={report['hit_count']} pack={report['pack_dir']}")
        for hit in report.get("hits") or []:
            print(f"  {hit['file']}:{hit['line']} {hit['pattern']}")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
