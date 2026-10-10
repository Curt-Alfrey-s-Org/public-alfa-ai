from __future__ import annotations

import hashlib
import json
import uuid
from pathlib import Path

from src.agent.loop import AgentRunResult, run_agent
from src.agent.roles import ArtifactRef, RoleRequest, RoleResponse, ToolEvent
from src.agent.tools import create_file
from src.config import agent_max_steps, workspace_root
from src.runtime.artifacts import (
    audit_report_body,
    host_facts_report_body,
    check_work_report_body,
    corrective_actions_report_body,
    error_catalog_report_body,
    implementation_summary_body,
    research_report_body,
    review_report_body,
    sleep_curator_report_body,
)
from src.runtime.error_catalog import (
    append_entry,
    corrective_actions_markdown,
    load_entries,
    new_entry,
    write_rollup_json,
)
from src.runtime.verify import merge_agent_and_probe


def _artifact_path(run_id: str, task_id: str, filename: str) -> str:
    return str(Path(".alfa_ai") / "artifacts" / run_id / task_id / filename)


def _sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _skill_from_request(request: RoleRequest) -> str | None:
    explicit = request.constraints.get("skill") or request.inputs.get("skill")
    if isinstance(explicit, str) and explicit.strip():
        return explicit.strip()
    return None


def _research_only_from_request(request: RoleRequest) -> bool:
    flag = request.constraints.get("research_only") or request.inputs.get("research_only")
    return bool(flag)


def _normalize_agent_result(result: AgentRunResult | str) -> AgentRunResult:
    if isinstance(result, str):
        return AgentRunResult(text=result)
    return result


def _invoke_agent(
    request: RoleRequest,
    *,
    role: str,
    prompt: str,
    persona: str | None = None,
) -> AgentRunResult:
    skill = _skill_from_request(request)
    research_only = _research_only_from_request(request)
    raw = run_agent(
        prompt,
        max_steps=agent_max_steps(),
        role=role,  # type: ignore[arg-type]
        skill=skill,
        persona=persona,
        research_only=research_only and role == "researcher",
        use_agent_model=True,
        run_id=request.run_id,
    )
    return _normalize_agent_result(raw)


def _write_text_artifact(
    request: RoleRequest,
    *,
    filename: str,
    content: str,
    artifact_type: str,
    tool_events: list[ToolEvent] | None = None,
) -> RoleResponse:
    path = _artifact_path(request.run_id, request.task_id, filename)
    result = create_file(path, content)
    if not result.get("ok"):
        return RoleResponse(status="failed", summary=f"{request.role} failed: {result.get('error')}")
    artifact = ArtifactRef(
        artifact_id=str(uuid.uuid4()),
        artifact_type=artifact_type,
        path=path,
        sha256=_sha(content),
        metadata={"role": request.role},
    )
    return RoleResponse(
        status="success",
        summary=f"{request.role} completed.",
        artifacts=[artifact],
        tool_events=tool_events or [],
    )


def _upstream_artifact_lines(request: RoleRequest) -> str:
    artifacts = request.context.get("artifacts", [])
    if not isinstance(artifacts, list) or not artifacts:
        return ""
    lines = ["", "Upstream artifacts:"]
    for item in artifacts[:20]:
        if isinstance(item, dict):
            lines.append(f"- {item.get('artifact_type')} :: {item.get('path')}")
    return "\n".join(lines)


def _researcher(request: RoleRequest) -> RoleResponse:
    skill = _skill_from_request(request) or "audit-repo"
    research_only = _research_only_from_request(request)

    # Deterministic L0/L2 paths (no LLM required for skeleton + catalog ops)
    if skill == "error-cataloger":
        return _error_cataloger(request)
    if skill == "corrective-analyst":
        return _corrective_analyst(request)
    if skill == "sleep-curator":
        return _sleep_curator(request)
    if skill == "export-train-pack":
        return _export_train_pack(request)

    prompt = (
        f"Research goal: {request.goal}\n\n"
        "Constraints: cite sources; search the repo first; use official vendor docs "
        "via fetch_url when needed."
        f"{_upstream_artifact_lines(request)}"
    )
    if skill == "host-facts":
        prompt = (
            f"Host facts goal: {request.goal}\n\n"
            "Use host_processes, disk_mem, docker_ps, docker_logs, and log_grep "
            "(allowlisted paths only). Summarize process health, container status, "
            "resource pressure, and error log patterns. No mutating commands."
            f"{_upstream_artifact_lines(request)}"
        )
    agent_result = _invoke_agent(
        request,
        role="researcher",
        prompt=prompt,
        persona="reviewer" if skill == "review" else None,
    )
    if not agent_result.text.strip():
        return RoleResponse(status="failed", summary="researcher produced empty output")

    if skill == "review":
        content = review_report_body(request.goal, agent_result.text)
        filename = "review.md"
        artifact_type = "review_report"
    elif skill == "host-facts":
        content = host_facts_report_body(request.goal, agent_result.text)
        filename = "host-facts.md"
        artifact_type = "host_facts_report"
    elif skill == "audit-repo" or research_only:
        content = audit_report_body(request.goal, agent_result.text)
        filename = "audit-report.md"
        artifact_type = "audit_report"
    else:
        content = research_report_body(request.goal, agent_result.text)
        filename = "research.md"
        artifact_type = "research_note"

    return _write_text_artifact(
        request,
        filename=filename,
        content=content,
        artifact_type=artifact_type,
        tool_events=agent_result.tool_events,
    )


def _error_cataloger(request: RoleRequest) -> RoleResponse:
    """Load/append catalog; write report + ensure rollup exists."""
    goal = request.goal
    # Seed a mission-scoped note so operators see the export path
    entry = new_entry(
        source="operator",
        summary=f"Catalog pass: {goal[:200]}",
        severity="low",
        evidence=["skill=error-cataloger"],
        metadata={"run_id": request.run_id, "task_id": request.task_id},
    )
    append_entry(entry)
    entries = load_entries()
    rollup_path = write_rollup_json()
    body = (
        f"Catalog entries: {len(entries)}\n"
        f"Rollup: {rollup_path}\n\n"
        f"Goal: {goal}\n\n"
        "Top fingerprints:\n"
    )
    from src.runtime.error_catalog import rollup_by_fingerprint

    for item in rollup_by_fingerprint(entries)[:20]:
        body += f"- [{item.severity}] x{item.count} `{item.fingerprint}` {item.summary}\n"
    content = error_catalog_report_body(goal, body)
    return _write_text_artifact(
        request,
        filename="error-catalog.md",
        content=content,
        artifact_type="error_catalog",
    )


def _corrective_analyst(request: RoleRequest) -> RoleResponse:
    """Group errors by fingerprint into corrective_actions.md."""
    md = corrective_actions_markdown()
    # Allow agent expansion later; deterministic skeleton is always produced
    if request.goal.strip():
        md = f"{md}\n## Operator goal\n\n{request.goal.strip()}\n"
    content = corrective_actions_report_body(request.goal, md)
    return _write_text_artifact(
        request,
        filename="corrective_actions.md",
        content=content,
        artifact_type="corrective_actions",
    )


def _sleep_curator(request: RoleRequest) -> RoleResponse:
    """Night Tier A: compact memory, lessons, error rollup, preference export."""
    from src.runtime.sleep_curator import run_sleep_curator

    goal_l = (request.goal or "").lower()
    dry_run = "dry_run" in goal_l or "dry-run" in goal_l
    report = run_sleep_curator(dry_run=dry_run, require_enabled_flag=False)
    body = report.to_markdown()
    if request.goal.strip():
        body = f"{body}\n## Operator goal\n\n{request.goal.strip()}\n"
    content = sleep_curator_report_body(request.goal, body)
    response = _write_text_artifact(
        request,
        filename="sleep-curator-report.md",
        content=content,
        artifact_type="sleep_curator_report",
    )
    response.summary = (
        f"sleep-curator ok={report.ok} lessons={report.lessons_extracted} "
        f"errors={report.error_fingerprints} prefs={report.preference_pairs}"
    )
    response.metrics = {
        **response.metrics,
        "sleep_curator": report.to_dict(),
    }
    if not report.ok:
        response.status = "failed"
    return response


def _export_train_pack(request: RoleRequest) -> RoleResponse:
    """Stage L3 pack for alfa-train (no GPU train)."""
    from src.runtime.train_export import export_train_pack

    report = export_train_pack(run_preference_export=True)
    body = (
        f"# Train pack export\n\n"
        f"- **OK:** {report.ok}\n"
        f"- **Dir:** `{report.export_dir}`\n"
        f"- **Hub hint:** `{report.hub_hint}`\n"
        f"- **Counts:** {report.counts}\n"
        f"- **Notes:** {'; '.join(report.notes) or 'none'}\n"
    )
    if request.goal.strip():
        body += f"\n## Operator goal\n\n{request.goal.strip()}\n"
    content = sleep_curator_report_body(request.goal, body)
    response = _write_text_artifact(
        request,
        filename="train-export-report.md",
        content=content,
        artifact_type="train_export_report",
    )
    response.summary = (
        f"train-export ok={report.ok} dir={report.export_dir} "
        f"dpo={report.counts.get('dpo_rows', 0)}"
    )
    response.metrics = {**response.metrics, "train_export": report.to_dict()}
    if not report.ok:
        response.status = "failed"
    return response


def _coder(request: RoleRequest) -> RoleResponse:
    prompt = (
        f"Implementation goal: {request.goal}\n\n"
        "Use read_file, grep_repo, and glob_files to understand the codebase. "
        "Apply changes with edit_file (preferred) or create_file for new files. "
        "List every changed file in the final answer."
        f"{_upstream_artifact_lines(request)}"
    )
    agent_result = _invoke_agent(
        request,
        role="coder",
        prompt=prompt,
        persona="implementer",
    )
    if not agent_result.text.strip():
        return RoleResponse(status="failed", summary="coder produced empty output")

    content = implementation_summary_body(request.goal, agent_result.text)
    return _write_text_artifact(
        request,
        filename="implementation-summary.md",
        content=content,
        artifact_type="code_patch",
        tool_events=agent_result.tool_events,
    )


def _debugger(request: RoleRequest) -> RoleResponse:
    skill = _skill_from_request(request)
    workflow_step = request.constraints.get("workflow_step")

    # Workflow / explicit check-work: agent skill + deterministic probe
    if skill == "check-work" or workflow_step == "check_work":
        prompt = (
            f"Verification goal: {request.goal}\n\n"
            "Confirm the stated goal was addressed using repo evidence. "
            "Run safe verification when appropriate. "
            "End with exactly VERDICT: PASS or VERDICT: FAIL on its own line."
            f"{_upstream_artifact_lines(request)}"
        )
        agent_result = _invoke_agent(
            request,
            role="debugger",
            prompt=prompt,
            persona=None,
        )
        merged = merge_agent_and_probe(agent_result.text, run_probe=True)
        summary = merged.summary
        content = check_work_report_body(request.goal, summary)
        response = _write_text_artifact(
            request,
            filename="check-work.md",
            content=content,
            artifact_type="check_work_report",
            tool_events=agent_result.tool_events,
        )
        # Surface VERDICT in RoleResponse.summary for orchestrator parse_verdict
        if merged.verdict:
            response.summary = summary
            response.metrics = {
                **response.metrics,
                "verdict": merged.verdict,
                "probe_ok": merged.probe_ok,
            }
        return response

    # Agent debugger: read-only diagnosis (check-work handled above)
    prompt = (
        f"Debug goal: {request.goal}\n\n"
        "Inspect the repo and upstream artifacts. Identify the most likely failure "
        "and a concrete fix. Do not mutate files unless mutate is enabled."
        f"{_upstream_artifact_lines(request)}"
    )
    agent_result = _invoke_agent(
        request,
        role="debugger",
        prompt=prompt,
        persona=None,
    )
    if not agent_result.text.strip():
        return RoleResponse(status="failed", summary="debugger produced empty output")
    payload = {
        "goal": request.goal,
        "analysis": agent_result.text,
    }
    content = json.dumps(payload, ensure_ascii=True, indent=2)
    return _write_text_artifact(
        request,
        filename="debug-report.json",
        content=content,
        artifact_type="debug_report",
        tool_events=agent_result.tool_events,
    )


def _doc_maker(request: RoleRequest) -> RoleResponse:
    prompt = (
        f"Documentation goal: {request.goal}\n\n"
        "Read upstream artifacts and relevant repo files. Produce operator-facing docs. "
        "Put the full markdown in the final answer."
        f"{_upstream_artifact_lines(request)}"
    )
    agent_result = _invoke_agent(
        request,
        role="doc_maker",
        prompt=prompt,
        persona="reviewer",
    )
    if not agent_result.text.strip():
        return RoleResponse(status="failed", summary="doc_maker produced empty output")
    content = agent_result.text if agent_result.text.startswith("#") else (
        f"# Generated Documentation\n\nGoal: {request.goal}\n\n{agent_result.text}\n"
    )
    return _write_text_artifact(
        request,
        filename="README.generated.md",
        content=content if content.endswith("\n") else content + "\n",
        artifact_type="doc_page",
        tool_events=agent_result.tool_events,
    )


def _artifact_dir(run_id: str, task_id: str) -> str:
    return str(Path(".alfa_ai") / "artifacts" / run_id / task_id)


def _register_files_as_artifacts(
    request: RoleRequest,
    *,
    output_dir: Path,
    artifact_type: str,
    tool_events: list[ToolEvent] | None = None,
) -> RoleResponse:
    artifacts: list[ArtifactRef] = []
    if output_dir.is_dir():
        for item in sorted(output_dir.rglob("*")):
            if not item.is_file():
                continue
            try:
                rel = str(item.relative_to(workspace_root()))
            except ValueError:
                continue
            content = item.read_text(encoding="utf-8")
            artifacts.append(
                ArtifactRef(
                    artifact_id=str(uuid.uuid4()),
                    artifact_type=artifact_type,
                    path=rel,
                    sha256=_sha(content),
                    metadata={"role": request.role, "filename": item.name},
                )
            )
    if artifacts:
        return RoleResponse(
            status="success",
            summary=f"{request.role} completed with {len(artifacts)} output file(s).",
            artifacts=artifacts,
            tool_events=tool_events or [],
        )
    return RoleResponse(
        status="failed",
        summary=f"{request.role} produced no output files.",
        tool_events=tool_events or [],
    )


def _contracts(request: RoleRequest) -> RoleResponse:
    input_dir = f"runs/{request.run_id}/input"
    output_rel = _artifact_dir(request.run_id, request.task_id)
    output_dir = workspace_root() / output_rel
    output_dir.mkdir(parents=True, exist_ok=True)

    prompt = (
        f"Contract work goal: {request.goal}\n\n"
        f"Input documents folder (read every file): {input_dir}/\n"
        f"Output folder (write deliverables here): {output_rel}/\n\n"
        "Produce at least one markdown deliverable in the output folder."
        f"{_upstream_artifact_lines(request)}"
    )
    agent_result = _invoke_agent(
        request,
        role="contracts",
        prompt=prompt,
    )
    if not agent_result.text.strip() and not output_dir.is_dir():
        return RoleResponse(status="failed", summary="contracts produced empty output")

    response = _register_files_as_artifacts(
        request,
        output_dir=output_dir,
        artifact_type="contract_deliverable",
        tool_events=agent_result.tool_events,
    )
    if response.status == "success":
        return response

    if agent_result.text.strip():
        fallback_path = _artifact_path(request.run_id, request.task_id, "analysis.md")
        body = agent_result.text.strip() + "\n"
        result = create_file(fallback_path, body)
        if result.get("ok"):
            artifact = ArtifactRef(
                artifact_id=str(uuid.uuid4()),
                artifact_type="contract_deliverable",
                path=fallback_path,
                sha256=_sha(body),
                metadata={"role": "contracts", "filename": "analysis.md"},
            )
            return RoleResponse(
                status="success",
                summary="contracts completed (fallback analysis.md).",
                artifacts=[artifact],
                tool_events=agent_result.tool_events,
            )
        return RoleResponse(
            status="failed",
            summary=f"contracts failed: {result.get('error')}",
            tool_events=agent_result.tool_events,
        )

    return response


def execute_role(request: RoleRequest) -> RoleResponse:
    if request.role == "researcher":
        return _researcher(request)
    if request.role == "coder":
        return _coder(request)
    if request.role == "debugger":
        return _debugger(request)
    if request.role == "doc_maker":
        return _doc_maker(request)
    if request.role == "contracts":
        return _contracts(request)
    return RoleResponse(status="failed", summary=f"Unknown role: {request.role}")