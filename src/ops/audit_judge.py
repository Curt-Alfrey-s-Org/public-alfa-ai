"""Dual-check exported audit findings and build Cursor review handoff.

Host-safe: runs on hub with stdlib only when ALFA_AI_JUDGE_ENABLED=0 or src deps
are missing. Uses src.llm.judge when available (brain container / venv).
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Literal

Verdict = Literal["confirm", "revise", "reject"]

FINDING_HEADER = re.compile(
    r"### Finding (\d+)\s*[-\u2014]\s*Severity:\s*(\S+)",
    re.IGNORECASE,
)
RUN_HEADER = re.compile(r"^## Run ([0-9a-f-]{36})\s*$", re.MULTILINE)
FIELD_FILE = re.compile(r"^-\s*File:\s*(.+)$", re.MULTILINE)
FIELD_DESC = re.compile(r"^-\s*Description:\s*(.+)$", re.MULTILINE)
FIELD_SUGGEST = re.compile(r"^-\s*Suggestion:\s*(.+)$", re.MULTILINE)
_JSON_FENCE = re.compile(r"```(?:json)?\s*(\{.*?\})\s*```", re.DOTALL | re.IGNORECASE)


@dataclass(slots=True)
class AuditJudgeIssue:
    severity: str
    claim: str
    reason: str


@dataclass(slots=True)
class AuditJudgeResult:
    verdict: Verdict = "revise"
    confidence: str = "low"
    issues: list[AuditJudgeIssue] = field(default_factory=list)
    missing_evidence: list[str] = field(default_factory=list)
    safe_to_auto_apply: bool = False
    enabled: bool = True
    skipped: bool = False
    skip_reason: str = ""
    raw: str = ""
    model: str = ""


@dataclass(slots=True)
class AuditFinding:
    run_id: str
    finding_index: int
    severity: str
    file_path: str
    description: str
    suggestion: str
    raw_block: str

    @property
    def fingerprint(self) -> str:
        payload = (
            f"{self.run_id}|{self.finding_index}|{self.severity}|"
            f"{self.file_path}|{self.description[:300]}"
        )
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:24]


@dataclass(slots=True)
class JudgedFinding:
    finding: AuditFinding
    judge: AuditJudgeResult
    judged_at: str = field(default_factory=lambda: datetime.now(tz=UTC).isoformat())

    def to_record(self) -> dict[str, Any]:
        return {
            "fingerprint": self.finding.fingerprint,
            "run_id": self.finding.run_id,
            "finding_index": self.finding.finding_index,
            "severity": self.finding.severity,
            "file": self.finding.file_path,
            "description": self.finding.description[:2000],
            "suggestion": self.finding.suggestion[:2000],
            "judged_at": self.judged_at,
            "judge_verdict": self.judge.verdict,
            "judge_confidence": self.judge.confidence,
            "judge_skipped": self.judge.skipped,
            "judge_skip_reason": self.judge.skip_reason,
            "judge_model": self.judge.model,
            "judge_issues": [asdict(i) for i in self.judge.issues],
            "judge_missing_evidence": list(self.judge.missing_evidence),
        }


def parse_findings_from_markdown(text: str) -> list[AuditFinding]:
    """Extract structured findings from exported findings markdown."""
    findings: list[AuditFinding] = []
    if not text.strip():
        return findings

    run_spans: list[tuple[str, int, int]] = []
    for match in RUN_HEADER.finditer(text):
        run_spans.append((match.group(1), match.start(), match.end()))

    if not run_spans:
        return _parse_findings_in_block(text, run_id="unknown", findings=findings)

    for idx, (run_id, _start, header_end) in enumerate(run_spans):
        block_end = run_spans[idx + 1][1] if idx + 1 < len(run_spans) else len(text)
        block = text[header_end:block_end]
        _parse_findings_in_block(block, run_id=run_id, findings=findings)

    return findings


def _parse_findings_in_block(
    block: str,
    *,
    run_id: str,
    findings: list[AuditFinding],
) -> list[AuditFinding]:
    headers = list(FINDING_HEADER.finditer(block))
    for i, header in enumerate(headers):
        start = header.start()
        end = headers[i + 1].start() if i + 1 < len(headers) else len(block)
        raw = block[start:end].strip()
        finding_index = int(header.group(1))
        severity = header.group(2).strip().lower()
        file_path = _first_group(FIELD_FILE, raw)
        description = _first_group(FIELD_DESC, raw)
        suggestion = _first_group(FIELD_SUGGEST, raw)
        findings.append(
            AuditFinding(
                run_id=run_id,
                finding_index=finding_index,
                severity=severity,
                file_path=file_path,
                description=description,
                suggestion=suggestion,
                raw_block=raw,
            )
        )
    return findings


def _first_group(pattern: re.Pattern[str], text: str) -> str:
    match = pattern.search(text)
    return match.group(1).strip() if match else ""


def _env_flag(key: str, default: str = "0") -> bool:
    return os.environ.get(key, default).strip().lower() in ("1", "true", "yes", "on")


def _judge_on_set() -> frozenset[str]:
    raw = os.environ.get(
        "ALFA_AI_JUDGE_ON",
        "high_risk,research,merge,freeform,run_command",
    )
    return frozenset(part.strip().lower() for part in raw.split(",") if part.strip())


def _parse_judge_response(text: str) -> AuditJudgeResult:
    raw = (text or "").strip()
    data: dict[str, Any] | None = None
    if raw:
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            match = _JSON_FENCE.search(raw)
            if match:
                try:
                    data = json.loads(match.group(1))
                except json.JSONDecodeError:
                    data = None
    if not isinstance(data, dict):
        return AuditJudgeResult(
            verdict="revise",
            confidence="low",
            issues=[
                AuditJudgeIssue(
                    severity="high",
                    claim="unparseable_judge_response",
                    reason=raw[:500],
                )
            ],
            missing_evidence=["valid judge JSON"],
            raw=raw[:4000],
        )
    verdict = str(data.get("verdict") or "revise").strip().lower()
    if verdict not in ("confirm", "revise", "reject"):
        verdict = "revise"
    issues_raw = data.get("issues") or []
    issues: list[AuditJudgeIssue] = []
    if isinstance(issues_raw, list):
        for item in issues_raw[:20]:
            if not isinstance(item, dict):
                continue
            issues.append(
                AuditJudgeIssue(
                    severity=str(item.get("severity") or "medium"),
                    claim=str(item.get("claim") or "")[:500],
                    reason=str(item.get("reason") or "")[:500],
                )
            )
    missing = data.get("missing_evidence") or []
    if not isinstance(missing, list):
        missing = []
    return AuditJudgeResult(
        verdict=verdict,  # type: ignore[arg-type]
        confidence=str(data.get("confidence") or "low"),
        issues=issues,
        missing_evidence=[str(x)[:500] for x in missing[:20]],
        safe_to_auto_apply=False,
        raw=raw[:4000],
    )


def _normalize_v1(base: str) -> str:
    b = base.rstrip("/")
    if b.endswith("/v1"):
        return b
    return b + "/v1"


def _stdlib_judge_completion(messages: list[dict[str, str]]) -> str:
    base = os.environ.get("ALFA_AI_JUDGE_API_BASE", "").strip()
    if not base:
        raise RuntimeError("ALFA_AI_JUDGE_API_BASE not set")
    model = os.environ.get("ALFA_AI_JUDGE_MODEL", "judge").strip() or "judge"
    remote = os.environ.get("ALFA_AI_JUDGE_REMOTE_MODEL", "").strip()
    if not remote:
        remote = model if model != "judge" else "deepseek-r1:14b"
    max_tok = int(os.environ.get("ALFA_AI_JUDGE_MAX_TOKENS", "1024") or "1024")
    key = os.environ.get("ALFA_AI_JUDGE_API_KEY", "ollama").strip() or "ollama"
    url = _normalize_v1(base) + "/chat/completions"
    body = json.dumps(
        {"model": remote, "messages": messages, "max_tokens": max_tok},
        ensure_ascii=True,
    ).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        payload = json.load(resp)
    choices = payload.get("choices") if isinstance(payload, dict) else None
    if not isinstance(choices, list) or not choices:
        return ""
    first = choices[0]
    if not isinstance(first, dict):
        return ""
    message = first.get("message")
    if not isinstance(message, dict):
        return ""
    return str(message.get("content") or "")


def _to_audit_result(judge_result: object) -> AuditJudgeResult:
    """Convert src.llm.judge.JudgeResult when running inside brain venv."""
    return AuditJudgeResult(
        verdict=getattr(judge_result, "verdict", "revise"),
        confidence=str(getattr(judge_result, "confidence", "low")),
        issues=[
            AuditJudgeIssue(
                severity=str(getattr(i, "severity", "")),
                claim=str(getattr(i, "claim", "")),
                reason=str(getattr(i, "reason", "")),
            )
            for i in getattr(judge_result, "issues", []) or []
        ],
        missing_evidence=list(getattr(judge_result, "missing_evidence", []) or []),
        skipped=bool(getattr(judge_result, "skipped", False)),
        skip_reason=str(getattr(judge_result, "skip_reason", "")),
        raw=str(getattr(judge_result, "raw", ""))[:4000],
        model=str(getattr(judge_result, "model", "")),
    )


def call_judge(
    *,
    subject: str,
    context: str = "research",
    claims: str = "",
    evidence: str = "",
) -> AuditJudgeResult:
    """Dual-check one audit finding. Fail closed when disabled."""
    if not _env_flag("ALFA_AI_JUDGE_ENABLED"):
        return AuditJudgeResult(
            verdict="confirm",
            confidence="low",
            enabled=False,
            skipped=True,
            skip_reason="ALFA_AI_JUDGE_ENABLED=0",
        )
    key = (context or "").strip().lower()
    on = _judge_on_set()
    if key not in on and "all" not in on:
        return AuditJudgeResult(
            verdict="confirm",
            confidence="low",
            enabled=True,
            skipped=True,
            skip_reason=f"context '{context}' not in ALFA_AI_JUDGE_ON",
        )

    try:
        from src.llm.judge import run_judge

        return _to_audit_result(
            run_judge(
                subject=subject,
                context=context,
                claims=claims,
                evidence=evidence,
            )
        )
    except ImportError:
        pass

    system = (
        "You are an independent verifier (judge) for ALFa AI. "
        "Respond with a single JSON object only, no markdown fences. Keys: "
        "verdict (confirm|revise|reject), confidence (high|medium|low), "
        "issues (array of {severity, claim, reason}), missing_evidence (string array), "
        "safe_to_auto_apply (always false). "
        "Reject if the proposal is unsafe or unsupported by evidence."
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
    try:
        text = _stdlib_judge_completion(messages)
    except (urllib.error.URLError, OSError, RuntimeError, json.JSONDecodeError) as exc:
        return AuditJudgeResult(
            verdict="revise",
            confidence="low",
            issues=[
                AuditJudgeIssue(
                    severity="high",
                    claim="judge_call_failed",
                    reason=str(exc)[:500],
                )
            ],
            missing_evidence=["successful judge model call"],
        )
    result = _parse_judge_response(text)
    result.model = os.environ.get("ALFA_AI_JUDGE_REMOTE_MODEL", "") or os.environ.get(
        "ALFA_AI_JUDGE_MODEL", ""
    )
    return result


def judge_finding(finding: AuditFinding) -> JudgedFinding:
    """Run independent judge on one audit finding (context=research)."""
    claims = (
        f"Severity: {finding.severity}\n"
        f"File: {finding.file_path}\n"
        f"Description: {finding.description}\n"
        f"Suggestion: {finding.suggestion}"
    )
    evidence = finding.raw_block[:4000]
    result = call_judge(
        subject=f"Audit finding {finding.finding_index} in run {finding.run_id}",
        context="research",
        claims=claims,
        evidence=evidence,
    )
    return JudgedFinding(finding=finding, judge=result)


def build_cursor_handoff(judged: list[JudgedFinding], *, date_label: str) -> str:
    """Cursor-ready paste block for operator second review."""
    counts = {"confirm": 0, "revise": 0, "reject": 0, "skipped": 0}
    lines: list[str] = []
    for item in judged:
        v = item.judge.verdict if not item.judge.skipped else "skipped"
        if v in counts:
            counts[v] += 1
        else:
            counts["skipped"] += 1
        lines.append(
            f"- [{v}] {item.finding.severity} {item.finding.file_path or '(no file)'}: "
            f"{item.finding.description[:160]}"
        )

    summary = (
        f"confirm={counts['confirm']} revise={counts['revise']} "
        f"reject={counts['reject']} skipped={counts['skipped']}"
    )
    bullet_block = "\n".join(lines) if lines else "(no findings to review)"
    return (
        f"Review judged audit findings for alfa-ai ({date_label}).\n"
        f"Summary: {summary}\n\n"
        "Instructions:\n"
        "1. Verify each file:line against the repo (hub clone at alfa-ai/ on hub).\n"
        "2. Recommend keep, dismiss, or fix for each item.\n"
        "3. Do not auto-commit; operator makes the final call.\n"
        "4. Prefer deterministic checks (grep, tests) over LLM opinion for code truth.\n\n"
        "Findings:\n"
        f"{bullet_block}\n"
    )


def _load_judged_fingerprints(path: Path) -> set[str]:
    if not path.is_file():
        return set()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return set()
    if isinstance(data, list):
        return {str(x) for x in data}
    return set()


def _append_judged_markdown(path: Path, item: JudgedFinding) -> None:
    f = item.finding
    j = item.judge
    section = (
        f"\n\n---\n\n## {f.fingerprint}\n"
        f"- run_id: {f.run_id}\n"
        f"- finding: {f.finding_index}\n"
        f"- severity: {f.severity}\n"
        f"- file: {f.file_path}\n"
        f"- judge_verdict: {j.verdict}\n"
        f"- judge_confidence: {j.confidence}\n"
        f"- judge_skipped: {j.skipped}\n"
        f"- judged_at: {item.judged_at}\n\n"
        f"{f.raw_block}\n"
    )
    if j.issues:
        section += "\n**Judge issues:**\n"
        for issue in j.issues:
            section += f"- [{issue.severity}] {issue.claim}: {issue.reason}\n"
    with path.open("a", encoding="utf-8") as handle:
        handle.write(section)


def _write_cursor_review(path: Path, handoff: str, judged: list[JudgedFinding], date_label: str) -> None:
    counts: dict[str, int] = {"confirm": 0, "revise": 0, "reject": 0, "skipped": 0}
    table_rows: list[str] = []
    for item in judged:
        j = item.judge
        verdict = "skipped" if j.skipped else j.verdict
        counts[verdict] = counts.get(verdict, 0) + 1
        table_rows.append(
            f"| {item.finding.fingerprint[:12]} | {item.finding.run_id[:8]} | "
            f"{item.finding.severity} | {verdict} | {item.finding.file_path[:60]} |"
        )

    body = (
        f"# Cursor review handoff -- {date_label}\n\n"
        f"Generated: {datetime.now(tz=UTC).isoformat()}\n\n"
        "## Summary\n\n"
        f"- confirm: {counts.get('confirm', 0)}\n"
        f"- revise: {counts.get('revise', 0)}\n"
        f"- reject: {counts.get('reject', 0)}\n"
        f"- skipped: {counts.get('skipped', 0)}\n\n"
        "## Findings table\n\n"
        "| ID | Run | Severity | Judge | File |\n"
        "|----|-----|----------|-------|------|\n"
        + ("\n".join(table_rows) if table_rows else "| (none) | | | | |")
        + "\n\n## Paste into Cursor\n\n```\n"
        + handoff
        + "\n```\n"
    )
    path.write_text(body, encoding="utf-8")


def load_env_file(path: str | Path) -> None:
    """Load KEY=VALUE pairs from deploy/.env into os.environ (no override)."""
    p = Path(path)
    if not p.is_file():
        return
    for line in p.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip("\r"))


def run_audit_judge(log_dir: Path, *, date_label: str | None = None) -> dict[str, Any]:
    """Judge new findings in findings-{date}.md; write judged + cursor handoff files."""
    log_dir.mkdir(parents=True, exist_ok=True)
    today = date_label or datetime.now(tz=UTC).strftime("%Y-%m-%d")
    findings_path = log_dir / f"findings-{today}.md"
    judged_md_path = log_dir / f"judged-findings-{today}.md"
    judged_jsonl_path = log_dir / "judged.jsonl"
    cursor_path = log_dir / f"cursor-review-{today}.md"
    state_path = log_dir / "judged-fingerprints.json"

    if not findings_path.is_file():
        return {
            "ok": True,
            "new_judged": 0,
            "message": f"no findings file: {findings_path}",
            "cursor_review": str(cursor_path),
        }

    all_findings = parse_findings_from_markdown(findings_path.read_text(encoding="utf-8"))
    already = _load_judged_fingerprints(state_path)
    pending = [f for f in all_findings if f.fingerprint not in already]

    new_judged: list[JudgedFinding] = []
    for finding in pending:
        judged_item = judge_finding(finding)
        new_judged.append(judged_item)
        _append_judged_markdown(judged_md_path, judged_item)
        with judged_jsonl_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(judged_item.to_record(), ensure_ascii=True) + "\n")
        already.add(finding.fingerprint)

    state_path.write_text(json.dumps(sorted(already), indent=2), encoding="utf-8")

    fp_set = {f.fingerprint for f in all_findings}
    today_judged = _load_judged_for_fingerprints(judged_jsonl_path, fp_set)
    handoff = build_cursor_handoff(today_judged, date_label=today)
    _write_cursor_review(cursor_path, handoff, today_judged, today)

    return {
        "ok": True,
        "new_judged": len(new_judged),
        "total_findings": len(all_findings),
        "cursor_review": str(cursor_path),
        "judged_markdown": str(judged_md_path),
        "judged_jsonl": str(judged_jsonl_path),
    }


def _load_judged_for_fingerprints(jsonl_path: Path, fingerprints: set[str]) -> list[JudgedFinding]:
    """Rebuild JudgedFinding list from jsonl for cursor handoff (findings in this export)."""
    if not jsonl_path.is_file() or not fingerprints:
        return []
    out: list[JudgedFinding] = []
    seen: set[str] = set()
    for line in jsonl_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        fp = str(rec.get("fingerprint") or "")
        if not fp or fp not in fingerprints or fp in seen:
            continue
        seen.add(fp)
        judged_at = str(rec.get("judged_at") or "")
        finding = AuditFinding(
            run_id=str(rec.get("run_id") or ""),
            finding_index=int(rec.get("finding_index") or 0),
            severity=str(rec.get("severity") or ""),
            file_path=str(rec.get("file") or ""),
            description=str(rec.get("description") or ""),
            suggestion=str(rec.get("suggestion") or ""),
            raw_block="",
        )
        issues = [
            AuditJudgeIssue(
                severity=str(i.get("severity") or ""),
                claim=str(i.get("claim") or ""),
                reason=str(i.get("reason") or ""),
            )
            for i in rec.get("judge_issues") or []
            if isinstance(i, dict)
        ]
        verdict = str(rec.get("judge_verdict") or "revise")
        if verdict not in ("confirm", "revise", "reject"):
            verdict = "revise"
        judge = AuditJudgeResult(
            verdict=verdict,  # type: ignore[arg-type]
            confidence=str(rec.get("judge_confidence") or "low"),
            issues=issues,
            missing_evidence=[str(x) for x in rec.get("judge_missing_evidence") or []],
            skipped=bool(rec.get("judge_skipped")),
            skip_reason=str(rec.get("judge_skip_reason") or ""),
            model=str(rec.get("judge_model") or ""),
        )
        out.append(JudgedFinding(finding=finding, judge=judge, judged_at=judged_at))
    return out
