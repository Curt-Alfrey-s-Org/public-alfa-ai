"""check-work verdict parsing and optional safe verification probes.

Primary gate for code correctness (learning-loop L0 / WorkflowRunner).
LLM narrative is secondary; this module is deterministic.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Literal

from src.agent.tools import run_cmd

Verdict = Literal["PASS", "FAIL"]

_VERDICT_RE = re.compile(r"^VERDICT:\s*(PASS|FAIL)\s*$", re.MULTILINE | re.IGNORECASE)


@dataclass(slots=True)
class VerifyResult:
    verdict: Verdict | None
    summary: str
    probe_ok: bool | None = None
    probe_stdout: str = ""
    probe_stderr: str = ""
    returncode: int | None = None


def parse_verdict(text: str) -> Verdict | None:
    """Extract final VERDICT: PASS|FAIL line from check-work agent output."""
    if not text or not text.strip():
        return None
    matches = _VERDICT_RE.findall(text)
    if not matches:
        return None
    return matches[-1].upper()  # type: ignore[return-value]


def run_safe_probe(command: str = "python --version") -> VerifyResult:
    """Run a single allowlisted-style probe via existing run_cmd sandbox."""
    result = run_cmd(command)
    ok = bool(result.get("ok"))
    stdout = str(result.get("stdout") or "")
    stderr = str(result.get("stderr") or "")
    code = result.get("returncode")
    rc = int(code) if isinstance(code, int) else None
    if ok:
        return VerifyResult(
            verdict="PASS",
            summary=f"Probe ok: {command}",
            probe_ok=True,
            probe_stdout=stdout,
            probe_stderr=stderr,
            returncode=rc,
        )
    return VerifyResult(
        verdict="FAIL",
        summary=f"Probe failed: {command}",
        probe_ok=False,
        probe_stdout=stdout,
        probe_stderr=stderr,
        returncode=rc,
    )


def merge_agent_and_probe(
    agent_text: str,
    *,
    run_probe: bool = True,
    probe_command: str = "python --version",
) -> VerifyResult:
    """Combine agent VERDICT with optional deterministic probe.

    - If agent says FAIL → FAIL (probe still recorded).
    - If agent says PASS and probe fails → FAIL.
    - If agent says PASS and probe ok (or skipped) → PASS.
    - If agent has no verdict → use probe only when run_probe, else None.
    """
    agent_verdict = parse_verdict(agent_text)
    probe: VerifyResult | None = None
    if run_probe:
        probe = run_safe_probe(probe_command)

    if agent_verdict == "FAIL":
        return VerifyResult(
            verdict="FAIL",
            summary=_compose_summary(agent_text, agent_verdict, probe),
            probe_ok=probe.probe_ok if probe else None,
            probe_stdout=probe.probe_stdout if probe else "",
            probe_stderr=probe.probe_stderr if probe else "",
            returncode=probe.returncode if probe else None,
        )

    if probe is not None and probe.verdict == "FAIL":
        return VerifyResult(
            verdict="FAIL",
            summary=_compose_summary(agent_text, agent_verdict, probe),
            probe_ok=False,
            probe_stdout=probe.probe_stdout,
            probe_stderr=probe.probe_stderr,
            returncode=probe.returncode,
        )

    if agent_verdict == "PASS":
        return VerifyResult(
            verdict="PASS",
            summary=_compose_summary(agent_text, agent_verdict, probe),
            probe_ok=probe.probe_ok if probe else None,
            probe_stdout=probe.probe_stdout if probe else "",
            probe_stderr=probe.probe_stderr if probe else "",
            returncode=probe.returncode if probe else None,
        )

    if probe is not None and probe.verdict is not None:
        return VerifyResult(
            verdict=probe.verdict,
            summary=_compose_summary(agent_text, agent_verdict, probe),
            probe_ok=probe.probe_ok,
            probe_stdout=probe.probe_stdout,
            probe_stderr=probe.probe_stderr,
            returncode=probe.returncode,
        )

    return VerifyResult(
        verdict=None,
        summary=agent_text.strip() or "No VERDICT line and probe skipped.",
    )


def _compose_summary(
    agent_text: str,
    agent_verdict: Verdict | None,
    probe: VerifyResult | None,
) -> str:
    parts: list[str] = []
    if agent_text.strip():
        parts.append(agent_text.strip())
    if agent_verdict:
        parts.append(f"Agent verdict: {agent_verdict}")
    if probe is not None:
        parts.append(f"Probe: {'ok' if probe.probe_ok else 'failed'}")
        if probe.probe_stdout.strip():
            parts.append(f"stdout: {probe.probe_stdout.strip()[:500]}")
        if probe.probe_stderr.strip():
            parts.append(f"stderr: {probe.probe_stderr.strip()[:500]}")
    final = "\n\n".join(parts).strip()
    verdict = agent_verdict
    if probe is not None and probe.verdict == "FAIL":
        verdict = "FAIL"
    elif agent_verdict == "FAIL":
        verdict = "FAIL"
    elif agent_verdict == "PASS" and (probe is None or probe.verdict != "FAIL"):
        verdict = "PASS"
    elif probe is not None:
        verdict = probe.verdict
    if verdict and f"VERDICT: {verdict}" not in final:
        final = f"{final}\n\nVERDICT: {verdict}"
    return final
