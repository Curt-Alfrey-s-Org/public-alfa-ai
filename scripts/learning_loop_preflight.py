#!/usr/bin/env python3
"""Preflight for learning-loop software (L0–L3 wiring). No cluster start/stop.

Usage:
  python scripts/learning_loop_preflight.py
  python scripts/learning_loop_preflight.py --json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

_REPO = Path(__file__).resolve().parents[1]
if str(_REPO) not in sys.path:
    sys.path.insert(0, str(_REPO))


def _check(name: str, ok: bool, detail: str = "") -> dict:
    return {"name": name, "ok": ok, "detail": detail}


def run_checks() -> list[dict]:
    checks: list[dict] = []

    # Skills
    for skill in (
        "audit-repo",
        "implement",
        "review",
        "check-work",
        "error-cataloger",
        "corrective-analyst",
        "sleep-curator",
        "export-train-pack",
        "judge",
    ):
        path = _REPO / "skills" / skill / "SKILL.md"
        checks.append(_check(f"skill:{skill}", path.is_file(), str(path)))

    # Modules
    for mod in (
        "src/runtime/workflow.py",
        "src/runtime/verify.py",
        "src/runtime/error_catalog.py",
        "src/runtime/sleep_curator.py",
        "src/runtime/train_export.py",
        "src/runtime/flywheel.py",
        "src/runtime/lora_registry.py",
        "src/runtime/learning_loop_status.py",
        "src/runtime/review_service.py",
        "src/agent/loop.py",
        "src/agent/openai_tools.py",
        "src/llm/judge.py",
        "src/api/routers/agent.py",
        "scripts/eval/smoke_runner.py",
        "scripts/sleep_curator_nightly.py",
        "scripts/export_train_pack.py",
        "scripts/run_data_flywheel.py",
        "scripts/clear_stuck_missions.py",
        "scripts/scan_pass_jsonl.py",
        "scripts/learning_loop_tier_a.sh",
        "scripts/publish_train_pack_to_hub.sh",
        "scripts/eval/train_checkpoint_gate.py",
        "deploy/llamacpp-rpc/run-llama-server-coordinator.sh",
        "deploy/llamacpp-rpc/docker-compose.rpc-main.lora-volumes.yml",
        "deploy/cluster-members/_common/publish-lora-adapter-to-hub.sh",
        "deploy/cluster-members/gaming-worker-c/learning-loop-trainer-preflight.ps1",
        "deploy/cluster-members/gaming-worker-c/run-qlora-night.ps1",
        "eval/gold/smoke.jsonl",
        "docs/operations/SLEEP_CURATOR_NIGHTLY.md",
        "docs/operations/SLEEP_TRAIN_TIER_B.md",
        "docs/operations/DATA_FLYWHEEL_OPERATOR.md",
        "docs/operations/LORA_ADAPTER_OPERATOR.md",
        "docs/operations/TRAIN_PACK_MANIFEST.md",
        "docs/operations/JUDGE_INSTALL_59.md",
        "docs/operations/ALFA_CODER_DRAFT_ALIAS.md",
        "docs/operations/SCHEDULED_AUDIT_MISSIONS.md",
    ):
        path = _REPO / mod
        checks.append(_check(f"file:{mod}", path.is_file(), str(path)))

    # LiteLLM alias present (text scan — not live proxy)
    litellm = (_REPO / "deploy" / "litellm_config.yaml").read_text(encoding="utf-8")
    checks.append(
        _check(
            "litellm:alfa-coder-draft",
            'model_name: "alfa-coder-draft"' in litellm
            or "model_name: alfa-coder-draft" in litellm,
            "deploy/litellm_config.yaml",
        )
    )

    # Imports
    try:
        from src.runtime.workflow import wants_implement_review_fix
        from src.runtime.sleep_curator import run_sleep_curator
        from src.runtime.train_export import export_train_pack, patch_manifest_scan_pass
        from src.runtime.flywheel import run_data_flywheel
        from src.runtime.lora_registry import list_adapters, sync_registry_from_hub
        from src.runtime.learning_loop_status import collect_learning_loop_status
        from src.llm.judge import judge_enabled, run_judge
        from src.config import agent_mutate_enabled, native_tools_enabled

        checks.append(_check("import:runtime", True, "workflow/sleep/train/judge"))
        checks.append(
            _check(
                "default:mutate_off",
                not agent_mutate_enabled(),
                "ALFA_AI_AGENT_MUTATE_ENABLED should default off",
            )
        )
        checks.append(
            _check(
                "default:native_tools_off",
                not native_tools_enabled(),
                "ALFA_AI_NATIVE_TOOLS should default off",
            )
        )
        checks.append(
            _check(
                "default:judge_off",
                not judge_enabled(),
                "ALFA_AI_JUDGE_ENABLED should default off",
            )
        )
        # dry smoke of pure functions
        assert wants_implement_review_fix(skill="implement")
        _ = run_judge  # noqa: F841
        _ = run_sleep_curator
        _ = export_train_pack
        _ = patch_manifest_scan_pass
        _ = run_data_flywheel
        _ = list_adapters
        _ = sync_registry_from_hub
        _ = collect_learning_loop_status
    except Exception as exc:  # noqa: BLE001
        checks.append(_check("import:runtime", False, str(exc)))

    # Eval gold count
    gold = _REPO / "eval" / "gold" / "smoke.jsonl"
    if gold.is_file():
        n = sum(1 for line in gold.read_text(encoding="utf-8").splitlines() if line.strip())
        checks.append(_check("eval:gold_count", n >= 10, f"{n} rows"))
    else:
        checks.append(_check("eval:gold_count", False, "missing"))

    return checks


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Learning-loop software preflight")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    checks = run_checks()
    failed = [c for c in checks if not c["ok"]]
    report = {
        "ok": len(failed) == 0,
        "passed": sum(1 for c in checks if c["ok"]),
        "total": len(checks),
        "failed": failed,
        "checks": checks,
        "ops_remaining": [
            "OP-LL-1: install judge model on gaming-c (docs/operations/JUDGE_INSTALL_59.md)",
            "OP-LL-2: optional judge calibration set",
            "OP-LL-3: GPU QLoRA night + eval >=70% (docs/operations/SLEEP_TRAIN_TIER_B.md)",
            "Deploy brain + LiteLLM recreate for alfa-coder-draft alias",
            "contracts-bot: ALFA_AI_REVIEW_ENABLED when ready",
        ],
    }
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"learning-loop preflight: {report['passed']}/{report['total']}")
        for c in checks:
            mark = "OK " if c["ok"] else "FAIL"
            print(f"  [{mark}] {c['name']}: {c['detail']}")
        if failed:
            print(f"\n{len(failed)} failure(s)")
        print("\nOperator remaining:")
        for item in report["ops_remaining"]:
            print(f"  - {item}")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
