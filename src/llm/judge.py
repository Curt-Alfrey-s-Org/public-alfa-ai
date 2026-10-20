"""Independent LLM judge for dual-check (learning-loop L1).

Fail closed: ALFA_AI_JUDGE_ENABLED=0 by default.
Never sets safe_to_auto_apply true for mutate/host paths.
"""

from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass, field
from typing import Any, Literal

from src.config import (
    get,
    judge_api_base,
    judge_api_key,
    judge_enabled,
    judge_max_tokens,
    judge_model,
    judge_on_set,
)
from src.llm.client import get_completion

Verdict = Literal["confirm", "revise", "reject"]


@dataclass(slots=True)
class JudgeIssue:
    severity: str
    claim: str
    reason: str


@dataclass(slots=True)
class JudgeResult:
    verdict: Verdict
    confidence: str
    issues: list[JudgeIssue] = field(default_factory=list)
    missing_evidence: list[str] = field(default_factory=list)
    guidance: str = ""
    safe_to_auto_apply: bool = False
    enabled: bool = True
    skipped: bool = False
    skip_reason: str = ""
    raw: str = ""
    model: str = ""

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d["issues"] = [asdict(i) for i in self.issues]
        # Hard policy: never allow auto-apply via judge
        d["safe_to_auto_apply"] = False
        return d


_JSON_FENCE = re.compile(r"```(?:json)?\s*(\{.*?\})\s*```", re.DOTALL | re.IGNORECASE)


def should_run_judge(context: str) -> bool:
    """context is a key like high_risk, research, merge, freeform, run_command."""
    if not judge_enabled():
        return False
    on = judge_on_set()
    key = (context or "").strip().lower()
    return key in on or "all" in on


def parse_judge_response(text: str) -> JudgeResult:
    raw = (text or "").strip()
    data: dict[str, Any] | None = None
    if raw:
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            m = _JSON_FENCE.search(raw)
            if m:
                try:
                    data = json.loads(m.group(1))
                except json.JSONDecodeError:
                    data = None
            if data is None:
                # try first brace object
                start = raw.find("{")
                end = raw.rfind("}")
                if start >= 0 and end > start:
                    try:
                        data = json.loads(raw[start : end + 1])
                    except json.JSONDecodeError:
                        data = None
    if not isinstance(data, dict):
        return JudgeResult(
            verdict="revise",
            confidence="low",
            issues=[
                JudgeIssue(
                    severity="medium",
                    claim="unparseable_judge_output",
                    reason="Judge did not return valid JSON",
                )
            ],
            missing_evidence=["structured judge JSON"],
            raw=raw[:4000],
            model=judge_model(),
        )

    verdict = str(data.get("verdict") or "revise").lower()
    if verdict not in ("confirm", "revise", "reject"):
        verdict = "revise"
    confidence = str(data.get("confidence") or "low").lower()
    if confidence not in ("high", "medium", "low"):
        confidence = "low"
    issues_raw = data.get("issues") or []
    issues: list[JudgeIssue] = []
    if isinstance(issues_raw, list):
        for item in issues_raw[:30]:
            if not isinstance(item, dict):
                continue
            issues.append(
                JudgeIssue(
                    severity=str(item.get("severity") or "medium"),
                    claim=str(item.get("claim") or "")[:500],
                    reason=str(item.get("reason") or "")[:1000],
                )
            )
    missing = data.get("missing_evidence") or []
    if not isinstance(missing, list):
        missing = [str(missing)]
    guidance = str(data.get("guidance") or "")[:4000]
    return JudgeResult(
        verdict=verdict,  # type: ignore[arg-type]
        confidence=confidence,
        issues=issues,
        missing_evidence=[str(x)[:500] for x in missing[:20]],
        guidance=guidance,
        safe_to_auto_apply=False,
        raw=raw[:4000],
        model=judge_model(),
    )


def run_judge(
    *,
    subject: str,
    context: str = "high_risk",
    claims: str = "",
    evidence: str = "",
    model: str | None = None,
    litellm_only: bool = False,
) -> JudgeResult:
    """Dual-check narrative or freeform proposal. Fail closed when disabled."""
    if not judge_enabled():
        return JudgeResult(
            verdict="confirm",
            confidence="low",
            enabled=False,
            skipped=True,
            skip_reason="ALFA_AI_JUDGE_ENABLED=0",
            safe_to_auto_apply=False,
        )
    if not should_run_judge(context):
        return JudgeResult(
            verdict="confirm",
            confidence="low",
            enabled=True,
            skipped=True,
            skip_reason=f"context '{context}' not in ALFA_AI_JUDGE_ON",
            safe_to_auto_apply=False,
        )

    system = (
        "You are an independent verifier (judge) for ALFa AI. "
        "Respond with a single JSON object only, no markdown fences. Keys: "
        "verdict (confirm|revise|reject), confidence (high|medium|low), "
        "issues (array of {severity, claim, reason}), missing_evidence (string array), "
        "guidance (string: actionable revision notes when verdict is revise), "
        "safe_to_auto_apply (always false). "
        "Reject if the proposal is unsafe or unsupported by evidence. "
        "Revise if incomplete. Confirm only when evidence supports claims."
    )
    user = (
        f"Context tag: {context}\n"
        f"Subject:\n{subject[:6000]}\n\n"
        f"Claims / proposal:\n{(claims or subject)[:6000]}\n\n"
        f"Evidence:\n{(evidence or 'none provided')[:6000]}\n"
    )
    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ]
    resolved_model = (model or judge_model()).strip() or "judge"
    try:
        text = _judge_completion(
            messages,
            model=resolved_model,
            litellm_only=litellm_only,
        )
    except Exception as exc:  # noqa: BLE001 — surface as revise, never raise to auto-approve
        return JudgeResult(
            verdict="revise",
            confidence="low",
            issues=[
                JudgeIssue(
                    severity="high",
                    claim="judge_call_failed",
                    reason=str(exc)[:500],
                )
            ],
            missing_evidence=["successful judge model call"],
            raw="",
            model=resolved_model,
        )
    result = parse_judge_response(text)
    result.model = resolved_model
    result.safe_to_auto_apply = False
    return result


def _judge_completion(
    messages: list[dict[str, str]],
    *,
    model: str | None = None,
    litellm_only: bool = False,
) -> str:
    """Prefer dedicated judge API base (gaming-c); else LiteLLM alias.

    Path B passes litellm_only=True and model=frontier-code so Ollama Path A
    cannot hijack the 27B judge.
    """
    resolved = (model or judge_model()).strip() or "judge"
    max_tok = judge_max_tokens()
    if litellm_only:
        return get_completion(
            messages,
            model=resolved,
            max_tokens=max_tok,
        )
    base = judge_api_base()
    if base:
        from openai import OpenAI

        key = judge_api_key() or "sk-local"
        # Ollama/OpenAI-compat model id (not LiteLLM alias)
        remote = get("ALFA_AI_JUDGE_REMOTE_MODEL", "").strip()
        if not remote:
            remote = resolved if resolved != "judge" else "deepseek-r1:14b"
        client = OpenAI(base_url=_normalize_v1(base), api_key=key)
        response = client.chat.completions.create(
            model=remote,
            messages=messages,  # type: ignore[arg-type]
            max_tokens=max_tok,
            timeout=120,
        )
        return response.choices[0].message.content or ""

    # LiteLLM path: model alias e.g. "judge"
    return get_completion(
        messages,
        model=resolved,
        max_tokens=max_tok,
    )


def _normalize_v1(base: str) -> str:
    b = base.rstrip("/")
    if b.endswith("/v1"):
        return b
    return b + "/v1"
