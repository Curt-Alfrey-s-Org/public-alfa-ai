#!/usr/bin/env python3
"""Verify multi-repo completion corpus output.

Checks CORPUS_MANIFEST.json and train/val JSONL files produced by
``build_multi_repo_corpus.py``. Row shape matches Axolotl completion format:
https://docs.axolotl.ai/docs/dataset-formats/

Usage:
  python scripts/verify_multi_repo_corpus.py C:/Users/operator/alfa-ai-cache/train-corpus/multirepo
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

TRAIN_NAME = "alfa-corpus-multirepo-train.jsonl"
VAL_NAME = "alfa-corpus-multirepo-val.jsonl"
MANIFEST_NAME = "CORPUS_MANIFEST.json"
REQUIRED_FIELDS = ("repo", "path", "content")


def load_jsonl(path: Path) -> tuple[list[dict], list[str]]:
    rows: list[dict] = []
    errors: list[str] = []
    if not path.is_file():
        return rows, [f"missing file: {path}"]
    for lineno, line in enumerate(
        path.read_text(encoding="utf-8", errors="replace").splitlines(),
        1,
    ):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            errors.append(f"{path}:{lineno} invalid json: {exc}")
            continue
        if not isinstance(row, dict):
            errors.append(f"{path}:{lineno} row is not an object")
            continue
        for field in REQUIRED_FIELDS:
            if field not in row or row[field] in (None, ""):
                errors.append(f"{path}:{lineno} missing or empty field: {field}")
        rows.append(row)
    return rows, errors


def verify_corpus(out_dir: Path) -> int:
    manifest_path = out_dir / MANIFEST_NAME
    train_path = out_dir / TRAIN_NAME
    val_path = out_dir / VAL_NAME

    if not manifest_path.is_file():
        print(f"ERROR missing manifest: {manifest_path}", file=sys.stderr)
        return 1

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"ERROR invalid manifest json: {exc}", file=sys.stderr)
        return 1

    train_rows, train_errors = load_jsonl(train_path)
    val_rows, val_errors = load_jsonl(val_path)
    errors = train_errors + val_errors

    skipped = manifest.get("skipped_repos") or []
    if skipped:
        errors.append(f"manifest skipped_repos is not empty: {skipped!r}")

    if not train_rows:
        errors.append("train jsonl is empty")

    totals = manifest.get("totals") or {}
    expected_train = int(totals.get("train_rows", -1))
    expected_val = int(totals.get("val_rows", -1))
    expected_all = int(totals.get("rows", -1))

    if expected_train >= 0 and expected_train != len(train_rows):
        errors.append(
            f"manifest train_rows={expected_train} but file has {len(train_rows)}"
        )
    if expected_val >= 0 and expected_val != len(val_rows):
        errors.append(f"manifest val_rows={expected_val} but file has {len(val_rows)}")
    if expected_all >= 0 and expected_all != len(train_rows) + len(val_rows):
        errors.append(
            f"manifest rows={expected_all} but train+val={len(train_rows) + len(val_rows)}"
        )

    per_repo_counts: Counter[str] = Counter()
    for row in train_rows + val_rows:
        per_repo_counts[str(row.get("repo", ""))] += 1

    if errors:
        print("FAIL corpus verification", file=sys.stderr)
        for err in errors:
            print(f"  {err}", file=sys.stderr)
        return 1

    print(f"ok out_dir={out_dir}")
    print(f"train_rows={len(train_rows)} val_rows={len(val_rows)} total={len(train_rows) + len(val_rows)}")
    print("per_repo_counts:")
    for repo_id, count in sorted(per_repo_counts.items()):
        print(f"  {repo_id}={count}")
    manifest_repos = manifest.get("repos") or {}
    if isinstance(manifest_repos, dict):
        print("manifest_repo_files:")
        for repo_id, stats in sorted(manifest_repos.items()):
            if isinstance(stats, dict):
                print(f"  {repo_id} files={stats.get('files', 0)} bytes={stats.get('bytes', 0)}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Verify multi-repo corpus output")
    parser.add_argument("out_dir", type=Path, help="Corpus output directory")
    args = parser.parse_args(argv)
    out_dir = args.out_dir.resolve()
    if not out_dir.is_dir():
        print(f"ERROR out_dir not found: {out_dir}", file=sys.stderr)
        return 1
    return verify_corpus(out_dir)


if __name__ == "__main__":
    raise SystemExit(main())
