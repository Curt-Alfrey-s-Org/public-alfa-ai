"""7B draft + 27B judge/guide loop with JSONL audit trail.

Uses ``alfa-coder-draft`` (7B) for drafts and ``run_judge`` (27B ``frontier-code``)
for verification. Default off when ``ALFA_AI_JUDGE_ENABLED=0``. See
``docs/operations/ALFA_7B_27B_WORK_JUDGE.md``.
"""

from __future__ import annotations

import json
import re
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from src.config import get, judge_api_base, judge_enabled
from src.llm.client import get_completion_turn
from src.llm.judge import JudgeResult, Verdict, run_judge, should_run_judge
from src.ops.solar_dump import path_b_sim_dump_guardrail

DRAFT_MODEL = "alfa-coder-draft"
PATH_B_JUDGE_MODEL = "frontier-code"
JUDGE_CONTEXT = "research"
DEFAULT_LOG_PATH = Path("logs/draft-judge/sessions.jsonl")
MAX_LOG_TEXT_CHARS = 8000
_DRAFT_MAX_TOKENS = 4096
_inference_SERVED_MARKERS = ("frontier-code", "qwen3.6-27b", "qwen3.8-27b")

_DRAFT_SYSTEM = (
    "You are ALFa coder draft (7B). You have full control of this project's "
    "sandbox after 27B confirms. Produce a complete, accurate answer or "
    "implementation for the operator task. Do not propose host SSH, cluster "
    "start/stop, inference shard commands, secrets, .env, or guest chat mutate. "
    "The energy rail is simulated Home Assistant dump-load plugs."
)

_SECRET_PATTERNS = (
    re.compile(
        r"(?i)(api[_-]?key|secret|token|password|authorization|private[_-]?key)"
        r"\s*[:=]\s*\S+"
    ),
    re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._\-+/=]{8,}"),
    re.compile(r"(?i)sk-[a-zA-Z0-9]{10,}"),
    re.compile(
        r"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----.*?-----END (?:[A-Z]+ )?PRIVATE KEY-----",
        re.DOTALL,
    ),
    re.compile(
        r"-----BEGIN OPENSSH PRIVATE KEY-----.*?-----END OPENSSH PRIVATE KEY-----",
        re.DOTALL,
    ),
)


@dataclass(slots=True)
class DraftGuideResult:
    task: str
    final_draft: str = ""
    verdict: Verdict = "revise"
    rounds: int = 0
    judge_results: list[JudgeResult] = field(default_factory=list)
    enabled: bool = True
    skipped: bool = False
    skip_reason: str = ""
    safe_to_auto_apply: bool = False
    log_path: str = ""
    session_id: str = ""
    project_auto_applied: bool = False
    applied_path: str = ""
    autonomy_reason: str = ""

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d["judge_results"] = [j.to_dict() for j in self.judge_results]
        d["safe_to_auto_apply"] = False
        return d


def write_confirmed_project_draft(
    *,
    session_id: str,
    task: str,
    draft: str,
) -> str:
    """Write a sanitized confirmed draft under the workspace sandbox.

    Path: ``{ALFA_AI_WORKSPACE_ROOT}/draft-judge/applied/{session_id}.md``.
    Official pathlib containment: https://docs.python.org/3/library/pathlib.html
    """
    from src.config import workspace_root

    try:
        sid = str(uuid.UUID(session_id))
    except ValueError as exc:
        raise ValueError("invalid session_id") from exc
    root = workspace_root().resolve()
    dest_dir = (root / "draft-judge" / "applied").resolve()
    if not dest_dir.is_relative_to(root):
        raise ValueError("applied dir escaped workspace")
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = (dest_dir / f"{sid}.md").resolve()
    if not dest.is_relative_to(dest_dir):
        raise ValueError("applied file escaped applied dir")
    body = (
        f"# Path B confirmed draft\n\n"
        f"session_id: {sid}\n\n"
        f"## Task\n\n{sanitize_secret_text(task)}\n\n"
        f"## Draft\n\n{sanitize_secret_text(draft)}\n"
    )
    dest.write_text(body, encoding="utf-8")
    return str(dest)


def sanitize_secret_text(text: str, *, max_chars: int | None = MAX_LOG_TEXT_CHARS) -> str:
    """Redact credential-like spans; optionally truncate for JSONL / Ask ALFa."""
    out = (text or "").strip()
    for pattern in _SECRET_PATTERNS:
        out = pattern.sub("[REDACTED]", out)
    if max_chars is not None and len(out) > max_chars:
        return out[:max_chars] + "..."
    return out


def _is_inference_served_model(served: str) -> bool:
    lower = (served or "").strip().lower()
    if not lower:
        return False
    return any(marker in lower for marker in _inference_SERVED_MARKERS)


def _path_b_skip_reason() -> tuple[bool, str]:
    """Return (judge_master_enabled, skip_reason). Empty skip_reason means proceed."""
    if not judge_enabled():
        return False, "ALFA_AI_JUDGE_ENABLED=0"
    if not should_run_judge(JUDGE_CONTEXT):
        return True, f"context '{JUDGE_CONTEXT}' not in ALFA_AI_JUDGE_ON"
    if judge_api_base():
        return True, (
            "Path B requires empty ALFA_AI_JUDGE_API_BASE "
            "(LiteLLM frontier-code, not Path A Ollama)"
        )
    if not get("LLAMACPP_7B_URL", "").strip():
        return True, (
            "LLAMACPP_7B_URL is unset; Path B needs promoted 7B "
            "(not LiteLLM frontier-code fallback)"
        )
    return True, ""


def run_draft_guide_loop(
    task: str,
    *,
    max_rounds: int = 3,
    log_path: Path | str | None = None,
    settings: Any | None = None,
) -> DraftGuideResult:
    """Run up to ``max_rounds`` of 7B draft -> 27B judge; stop on confirm/reject."""
    cleaned_task = (task or "").strip()
    path = Path(log_path) if log_path is not None else DEFAULT_LOG_PATH
    path_str = str(path)

    enabled, skip_reason = _path_b_skip_reason()
    if skip_reason:
        return DraftGuideResult(
            task=cleaned_task,
            enabled=enabled,
            skipped=True,
            skip_reason=skip_reason,
            safe_to_auto_apply=False,
            log_path=path_str,
        )

    rounds_cap = max(1, min(int(max_rounds), 3))
    session_id = str(uuid.uuid4())
    draft_messages: list[dict[str, str]] = [
        {"role": "system", "content": _DRAFT_SYSTEM},
        {"role": "user", "content": f"Task:\n{cleaned_task[:8000]}"},
    ]
    judge_results: list[JudgeResult] = []
    final_draft = ""
    final_verdict: Verdict = "revise"

    for round_num in range(1, rounds_cap + 1):
        try:
            turn = get_completion_turn(
                draft_messages,
                model=DRAFT_MODEL,
                max_tokens=_DRAFT_MAX_TOKENS,
            )
            draft_text = turn.content
            served = turn.model
        except Exception as exc:  # noqa: BLE001 -- fail closed, surface as revise
            draft_text = f"[draft call failed: {str(exc)[:300]}]"
            served = ""

        if _is_inference_served_model(served):
            return DraftGuideResult(
                task=cleaned_task,
                final_draft=final_draft,
                verdict=final_verdict,
                rounds=len(judge_results),
                judge_results=judge_results,
                enabled=True,
                skipped=True,
                skip_reason=(
                    f"draft completion served model {served!r} looks like inference "
                    "(alfa-coder-draft LiteLLM fallback)"
                ),
                safe_to_auto_apply=False,
                log_path=path_str,
            )

        final_draft = (draft_text or "").strip()
        draft_role = "7b_draft" if round_num == 1 else "7b_revise"
        _append_jsonl(
            path,
            session_id=session_id,
            round_num=round_num,
            role=draft_role,
            model=DRAFT_MODEL,
            text=final_draft,
            verdict="",
            guidance="",
        )

        judge = run_judge(
            subject=cleaned_task,
            context=JUDGE_CONTEXT,
            claims=final_draft,
            evidence="",
            model=PATH_B_JUDGE_MODEL,
            litellm_only=True,
        )
        judge.safe_to_auto_apply = False
        judge_results.append(judge)
        final_verdict = judge.verdict
        guidance_text = _judge_guidance_text(judge) if judge.verdict == "revise" else ""

        _append_jsonl(
            path,
            session_id=session_id,
            round_num=round_num,
            role="27b_judge",
            model=judge.model or PATH_B_JUDGE_MODEL,
            text=judge.raw or _judge_summary(judge),
            verdict=judge.verdict,
            guidance=guidance_text,
        )

        if judge.verdict in ("confirm", "reject"):
            break

        if round_num >= rounds_cap:
            break

        draft_messages = [
            {"role": "system", "content": _DRAFT_SYSTEM},
            {
                "role": "user",
                "content": (
                    f"Task:\n{cleaned_task[:8000]}\n\n"
                    f"Previous draft:\n{final_draft[:6000]}\n\n"
                    f"Judge revision guidance:\n{guidance_text[:4000]}"
                ),
            },
        ]

    if final_verdict == "confirm":
        decision = "confirmed"
    elif final_verdict == "reject":
        decision = "rejected"
    else:
        decision = "max_rounds"

    project_auto_applied = False
    applied_path = ""
    autonomy_reason = ""
    if final_verdict == "confirm":
        ok, autonomy_reason = path_b_sim_dump_guardrail(settings)
        if ok:
            try:
                applied_path = write_confirmed_project_draft(
                    session_id=session_id,
                    task=cleaned_task,
                    draft=final_draft,
                )
                project_auto_applied = True
            except (OSError, ValueError) as exc:
                autonomy_reason = f"workspace write failed: {exc}"
                applied_path = ""
                project_auto_applied = False

    _append_jsonl(
        path,
        session_id=session_id,
        round_num=len(judge_results) or 1,
        role="decision",
        model="frontier-code",
        text=decision,
        verdict=final_verdict,
        guidance="",
        decision=decision,
        extra={
            "project_auto_applied": project_auto_applied,
            "applied_path": applied_path,
            "autonomy_reason": autonomy_reason,
        },
    )

    return DraftGuideResult(
        task=cleaned_task,
        final_draft=final_draft,
        verdict=final_verdict,
        rounds=len(judge_results),
        judge_results=judge_results,
        enabled=True,
        skipped=False,
        safe_to_auto_apply=False,
        log_path=path_str,
        session_id=session_id,
        project_auto_applied=project_auto_applied,
        applied_path=applied_path,
        autonomy_reason=autonomy_reason,
    )


def _judge_guidance_text(judge: JudgeResult) -> str:
    if judge.guidance:
        return judge.guidance.strip()
    parts: list[str] = []
    for issue in judge.issues:
        parts.append(f"- [{issue.severity}] {issue.claim}: {issue.reason}")
    for miss in judge.missing_evidence:
        parts.append(f"- missing evidence: {miss}")
    if parts:
        return "\n".join(parts)
    return "Address judge concerns and improve the draft."


def _judge_summary(judge: JudgeResult) -> str:
    parts = [f"verdict={judge.verdict}", f"confidence={judge.confidence}"]
    if judge.guidance:
        parts.append(f"guidance={judge.guidance}")
    return "; ".join(parts)


def _sanitize_log_text(text: str) -> str:
    return sanitize_secret_text(text)


def _append_jsonl(
    path: Path,
    *,
    session_id: str,
    round_num: int,
    role: str,
    model: str,
    text: str,
    verdict: str,
    guidance: str = "",
    decision: str = "",
    extra: dict[str, Any] | None = None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "session_id": session_id,
        "round": round_num,
        "role": role,
        "model": model,
        "text": _sanitize_log_text(text),
        "verdict": verdict,
        "guidance": _sanitize_log_text(guidance) if guidance else "",
    }
    if decision:
        record["decision"] = decision
    if extra:
        record.update(extra)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=True) + "\n")
