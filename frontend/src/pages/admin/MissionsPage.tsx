import { useCallback, useEffect, useRef, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { useAuth } from "../../contexts/AuthContext";
import { ApiError } from "../../api/client";

const BASE = "/alfa-ai/api/admin/missions";

interface FleetEntry {
  id: string;
  label: string;
  kind: string;
  skill: string;
  process_name: string;
  description: string;
  heartbeat_status: string;
  last_heartbeat_at: string | null;
  last_action: string | null;
  heartbeat_age_sec: number | null;
  active_run_count: number;
  done_run_count: number;
  host_id?: string;
  enabled?: boolean;
}

interface MissionRun {
  run_id: string;
  goal: string;
  status: string;
  skill: string;
  target_host?: string;
  research_only: boolean;
  created_at: string;
  updated_at: string;
}

interface MissionTask {
  task_id: string;
  run_id: string;
  role: string;
  title: string;
  status: string;
  metadata: Record<string, unknown>;
}

interface MissionArtifact {
  artifact_id: string;
  path: string;
  artifact_type: string;
}

interface Usefulness {
  tool_event_count: number;
  artifact_count: number;
  finding_count: number;
  likely_idle_burn: boolean;
  idle_burn_tool_threshold: number;
}

interface ArtifactsSummary {
  date: string;
  finding_count: number;
  inbox_count?: number;
  by_severity?: Record<string, number>;
  judged_count: number;
  log_dir_accessible: boolean;
  paths: {
    findings_md: string | null;
    judged_md: string | null;
    judged_jsonl: string | null;
    cursor_review_md: string | null;
  };
  last_export_at: string | null;
  last_judge_at: string | null;
}

interface FindingItem {
  id: string;
  source: string;
  run_id: string;
  finding_index: number;
  severity: string;
  file: string;
  description: string;
  suggestion: string;
  would_take_action: string;
  would_auto_apply: boolean;
  judge_verdict: string | null;
  judge_confidence: string | null;
  judge_skipped: boolean | null;
}

interface FindingsInbox {
  ok: boolean;
  date: string;
  count: number;
  structured_count: number;
  by_severity: Record<string, number>;
  findings: FindingItem[];
  note: string;
  log_dir_accessible: boolean;
}

interface WorkerStatus {
  status: string;
  detail: string;
  active_run_count: number;
}

interface LearningLoopStatus {
  ok: boolean;
  flywheel?: { enabled?: boolean; latest?: { ok?: boolean } | null };
  train_export?: {
    schema_version?: string | null;
    counts?: Record<string, number>;
    scan_pass?: { ok?: boolean } | null;
  };
  feedback?: { inbox_rows?: number; preference_pairs?: number };
  lora?: { count?: number };
}

interface ToolEvent {
  type: string;
  at?: string;
  [key: string]: unknown;
}

async function apiFetch<T>(path: string, token: string, opts?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    ...opts,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      ...opts?.headers,
    },
  });
  if (!res.ok) {
    const d = await res.json().catch(() => ({ detail: res.statusText }));
    throw new ApiError(d.detail ?? "Failed", res.status);
  }
  return res.json();
}

function heartbeatColor(status: string): string {
  switch (status) {
    case "alive":
      return "text-emerald-400 bg-emerald-950/50 border-emerald-800";
    case "idle":
      return "text-sky-400 bg-sky-950/50 border-sky-800";
    case "stale":
      return "text-amber-400 bg-amber-950/50 border-amber-800";
    default:
      return "text-slate-400 bg-slate-900 border-slate-700";
  }
}

function runStatusColor(status: string): string {
  switch (status) {
    case "done":
      return "text-emerald-400 bg-emerald-950/50 border-emerald-800";
    case "running":
      return "text-sky-400 bg-sky-950/50 border-sky-800";
    case "failed":
      return "text-red-400 bg-red-950/50 border-red-800";
    case "pending":
      return "text-violet-400 bg-violet-950/50 border-violet-800";
    default:
      return "text-slate-400 bg-slate-900 border-slate-700";
  }
}

function severityColor(severity: string): string {
  switch ((severity || "").toLowerCase()) {
    case "critical":
    case "high":
    case "bug":
      return "text-red-300 bg-red-950/50 border-red-800";
    case "medium":
    case "suggestion":
      return "text-amber-300 bg-amber-950/50 border-amber-800";
    case "low":
    case "nit":
      return "text-sky-300 bg-sky-950/50 border-sky-800";
    default:
      return "text-slate-400 bg-slate-900 border-slate-700";
  }
}

function timeAgo(iso: string | null): string {
  if (!iso) return "never";
  const diff = Date.now() - new Date(iso).getTime();
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  return `${Math.floor(hrs / 24)}d ago`;
}

function truncateGoal(goal: string, max = 72): string {
  if (goal.length <= max) return goal;
  return `${goal.slice(0, max - 1)}...`;
}

export default function MissionsPage() {
  const { token } = useAuth();
  const [searchParams] = useSearchParams();
  const deepLinkRunId = searchParams.get("run");
  const [fleet, setFleet] = useState<FleetEntry[]>([]);
  const [runs, setRuns] = useState<MissionRun[]>([]);
  const [selectedRunId, setSelectedRunId] = useState<string | null>(null);
  const [runDetail, setRunDetail] = useState<{
    run: MissionRun;
    tasks: MissionTask[];
    artifacts: MissionArtifact[];
    usefulness: Usefulness;
    skill: string;
  } | null>(null);
  const [summary, setSummary] = useState<ArtifactsSummary | null>(null);
  const [findingsInbox, setFindingsInbox] = useState<FindingsInbox | null>(null);
  const [worker, setWorker] = useState<WorkerStatus | null>(null);
  const [learningLoop, setLearningLoop] = useState<LearningLoopStatus | null>(null);
  const [statusFilter, setStatusFilter] = useState("");
  const [toolEvents, setToolEvents] = useState<ToolEvent[]>([]);
  const [error, setError] = useState("");
  const eventSourceRef = useRef<EventSource | null>(null);

  const loadFleet = useCallback(async () => {
    if (!token) return;
    try {
      const data = await apiFetch<{ fleet: FleetEntry[] }>("/fleet", token);
      setFleet(data.fleet);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to load fleet");
    }
  }, [token]);

  const loadRuns = useCallback(async () => {
    if (!token) return;
    try {
      const data = await apiFetch<{ runs: MissionRun[] }>("/runs?limit=80", token);
      setRuns(data.runs);
      setError("");
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to load runs");
    }
  }, [token]);

  const loadSummary = useCallback(async () => {
    if (!token) return;
    try {
      const data = await apiFetch<ArtifactsSummary>("/artifacts/summary", token);
      setSummary(data);
    } catch {
      /* optional panel */
    }
  }, [token]);

  const loadFindings = useCallback(async () => {
    if (!token) return;
    try {
      const data = await apiFetch<FindingsInbox>("/findings", token);
      setFindingsInbox(data);
    } catch {
      /* optional panel */
    }
  }, [token]);

  const loadWorker = useCallback(async () => {
    if (!token) return;
    try {
      const data = await apiFetch<WorkerStatus>("/worker", token);
      setWorker(data);
    } catch {
      /* optional */
    }
  }, [token]);

  const loadLearningLoop = useCallback(async () => {
    if (!token) return;
    try {
      const res = await fetch("/alfa-ai/api/admin/learning-loop/status", {
        headers: { Authorization: `Bearer ${token}` },
      });
      if (!res.ok) return;
      setLearningLoop((await res.json()) as LearningLoopStatus);
    } catch {
      /* optional until brain image has the route */
    }
  }, [token]);

  const loadRunDetail = useCallback(
    async (runId: string) => {
      if (!token) return;
      try {
        const data = await apiFetch<{
          run: MissionRun;
          tasks: MissionTask[];
          artifacts: MissionArtifact[];
          usefulness: Usefulness;
          skill: string;
        }>(`/runs/${encodeURIComponent(runId)}`, token);
        setRunDetail(data);
        setError("");
      } catch (err) {
        setError(err instanceof ApiError ? err.message : "Failed to load run detail");
      }
    },
    [token],
  );

  const stopEventStream = useCallback(() => {
    if (eventSourceRef.current) {
      eventSourceRef.current.close();
      eventSourceRef.current = null;
    }
  }, []);

  const startEventStream = useCallback(
    (runId: string) => {
      stopEventStream();
      if (!token || !runId) return;
      setToolEvents([]);
      const qs = `?access_token=${encodeURIComponent(token)}`;
      const es = new EventSource(
        `${BASE}/runs/${encodeURIComponent(runId)}/events${qs}`,
      );
      eventSourceRef.current = es;
      es.onmessage = (msg) => {
        try {
          const ev = JSON.parse(msg.data) as ToolEvent;
          setToolEvents((prev) => [...prev, ev]);
          if (ev.type === "run_complete" || ev.type === "task_done") {
            loadRuns();
            loadRunDetail(runId);
          }
        } catch {
          /* ignore */
        }
      };
      es.onerror = () => stopEventStream();
    },
    [token, stopEventStream, loadRuns, loadRunDetail],
  );

  useEffect(() => {
    if (deepLinkRunId) {
      setSelectedRunId(deepLinkRunId);
    }
  }, [deepLinkRunId]);

  useEffect(() => {
    loadFleet();
    loadRuns();
    loadSummary();
    loadFindings();
    loadWorker();
    loadLearningLoop();
    const timer = setInterval(() => {
      loadFleet();
      loadRuns();
      loadSummary();
      loadFindings();
      loadWorker();
      loadLearningLoop();
    }, 15000);
    return () => clearInterval(timer);
  }, [loadFleet, loadRuns, loadSummary, loadFindings, loadWorker, loadLearningLoop]);

  useEffect(() => {
    if (selectedRunId) {
      loadRunDetail(selectedRunId);
      startEventStream(selectedRunId);
    } else {
      setRunDetail(null);
      stopEventStream();
    }
    return () => stopEventStream();
  }, [selectedRunId, loadRunDetail, startEventStream, stopEventStream]);

  const filteredRuns = statusFilter
    ? runs.filter((r) => r.status === statusFilter)
    : runs;

  const selectedRun = runs.find((r) => r.run_id === selectedRunId);

  return (
    <div className="flex h-full flex-col">
      <div className="border-b border-sky-900/60 bg-sky-950/20 px-4 py-2 text-xs text-sky-200">
        Chat-first control: open Ask ALFa and try{" "}
        <span className="font-medium">Fleet status</span>,{" "}
        <span className="font-medium">Audit host 105</span>, or{" "}
        <span className="font-medium">Pause audit feeder</span>. Approve enqueues read-only
        missions or toggles the feeder; select a run below for live tool output.
      </div>
      <div className="border-b border-slate-800 p-4">
        <div className="mb-3 flex items-center justify-between">
          <div>
            <h2 className="text-lg font-semibold text-slate-200">Missions</h2>
            <p className="text-xs text-slate-500">
              Agent fleet oversight (read-only). Worker:{" "}
              <span className="text-slate-400">{worker?.status ?? "..."}</span>
              {worker?.detail ? ` - ${worker.detail}` : ""}
            </p>
            {learningLoop?.ok ? (
              <p className="mt-1 text-[11px] text-slate-500">
                Learning loop: flywheel {learningLoop.flywheel?.enabled ? "on" : "off"}
                {learningLoop.train_export?.schema_version
                  ? ` · pack v${learningLoop.train_export.schema_version}`
                  : " · no pack"}
                {` · feedback ${learningLoop.feedback?.inbox_rows ?? 0}`}
                {` · LoRA ${learningLoop.lora?.count ?? 0}`}
              </p>
            ) : null}
          </div>
          <button
            type="button"
            onClick={() => {
              loadFleet();
              loadRuns();
              loadSummary();
              loadFindings();
              loadWorker();
              loadLearningLoop();
            }}
            className="rounded border border-slate-700 px-3 py-1 text-xs text-slate-400 hover:text-slate-200"
          >
            Refresh
          </button>
        </div>
        <div className="grid grid-cols-2 gap-2 md:grid-cols-4 xl:grid-cols-8">
          {fleet.map((entry) => (
            <div
              key={entry.id}
              className="rounded-lg border border-slate-800 bg-slate-900/40 p-2"
            >
              <div className="flex items-center justify-between gap-1">
                <span className="truncate text-xs font-medium text-slate-200">
                  {entry.label}
                </span>
                <span
                  className={`shrink-0 rounded border px-1.5 py-0.5 text-[9px] uppercase ${heartbeatColor(entry.heartbeat_status)}`}
                >
                  {entry.kind === "skill"
                    ? entry.active_run_count > 0
                      ? "active"
                      : entry.heartbeat_status
                    : entry.kind === "worker_host" && entry.enabled === false
                      ? "stub"
                      : entry.heartbeat_status}
                </span>
              </div>
              <p className="mt-1 text-[10px] text-slate-500">
                {entry.kind === "skill"
                  ? `${entry.active_run_count} active / ${entry.done_run_count} done`
                  : entry.kind === "worker_host"
                    ? entry.host_id
                      ? `host .${entry.host_id} - ${timeAgo(entry.last_heartbeat_at)}`
                      : timeAgo(entry.last_heartbeat_at)
                    : timeAgo(entry.last_heartbeat_at)}
              </p>
            </div>
          ))}
        </div>
      </div>

      {error && <p className="px-4 py-2 text-sm text-red-400">{error}</p>}

      <div className="flex min-h-0 flex-1">
        <div className="flex w-2/5 flex-col border-r border-slate-800">
          <div className="flex items-center justify-between border-b border-slate-800 px-4 py-2">
            <h3 className="text-sm font-medium text-slate-300">Runs</h3>
            <select
              value={statusFilter}
              onChange={(e) => setStatusFilter(e.target.value)}
              className="rounded border border-slate-700 bg-slate-900 px-2 py-1 text-xs text-slate-300"
            >
              <option value="">All</option>
              <option value="pending">Pending</option>
              <option value="running">Running</option>
              <option value="done">Done</option>
              <option value="failed">Failed</option>
            </select>
          </div>
          <div className="flex-1 overflow-y-auto">
            {filteredRuns.length === 0 ? (
              <p className="p-6 text-sm text-slate-500">No orchestrator runs yet.</p>
            ) : (
              filteredRuns.map((run) => (
                <button
                  key={run.run_id}
                  type="button"
                  onClick={() => setSelectedRunId(run.run_id)}
                  className={`block w-full border-b border-slate-800/80 px-4 py-3 text-left hover:bg-slate-900/60 ${
                    selectedRunId === run.run_id ? "bg-slate-900/80" : ""
                  }`}
                >
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-xs font-medium text-slate-300">
                      {run.skill || "mission"}
                      {run.target_host && run.target_host !== "111"
                        ? ` @.${run.target_host}`
                        : ""}
                    </span>
                    <span
                      className={`rounded border px-2 py-0.5 text-[10px] uppercase ${runStatusColor(run.status)}`}
                    >
                      {run.status}
                    </span>
                  </div>
                  <p className="mt-1 truncate text-xs text-slate-500">
                    {truncateGoal(run.goal)}
                  </p>
                  <p className="mt-0.5 text-[10px] text-slate-600">
                    {timeAgo(run.created_at)}
                  </p>
                </button>
              ))
            )}
          </div>
        </div>

        <div className="flex min-w-0 flex-1 flex-col overflow-y-auto p-4">
          {!selectedRun || !runDetail ? (
            <p className="text-sm text-slate-500">
              {deepLinkRunId
                ? `Loading run ${deepLinkRunId.slice(0, 8)}... (live tool events appear here).`
                : "Select a run from the left list to view tasks and live tool output."}
            </p>
          ) : (
            <>
              <div className="mb-4">
                <div className="flex flex-wrap items-center gap-2">
                  <h3 className="text-base font-semibold text-slate-200">
                    {runDetail.skill || selectedRun.skill || "Run"}
                  </h3>
                  <span
                    className={`rounded border px-2 py-0.5 text-[10px] uppercase ${runStatusColor(selectedRun.status)}`}
                  >
                    {selectedRun.status}
                  </span>
                  {runDetail.usefulness.likely_idle_burn && (
                    <span className="rounded border border-amber-800 bg-amber-950/50 px-2 py-0.5 text-[10px] text-amber-400">
                      Likely idle burn
                    </span>
                  )}
                </div>
                <p className="mt-2 text-sm text-slate-400">{selectedRun.goal}</p>
                <p className="mt-1 font-mono text-[10px] text-slate-600">
                  {selectedRun.run_id}
                </p>
                <div className="mt-3 flex flex-wrap gap-3 text-xs text-slate-500">
                  <span>Tools: {runDetail.usefulness.tool_event_count}</span>
                  <span>Artifacts: {runDetail.usefulness.artifact_count}</span>
                  <span>Findings: {runDetail.usefulness.finding_count}</span>
                  <span>Updated: {timeAgo(selectedRun.updated_at)}</span>
                </div>
              </div>

              <div className="mb-4">
                <h4 className="mb-2 text-xs font-medium uppercase tracking-wide text-slate-500">
                  Tasks
                </h4>
                <ul className="space-y-1">
                  {runDetail.tasks.map((t) => (
                    <li
                      key={t.task_id}
                      className="flex items-center justify-between rounded border border-slate-800 px-2 py-1 text-xs"
                    >
                      <span className="text-slate-300">
                        {t.role}: {t.title}
                      </span>
                      <span className="text-slate-500">{t.status}</span>
                    </li>
                  ))}
                </ul>
              </div>

              {runDetail.artifacts.length > 0 && (
                <div className="mb-4">
                  <h4 className="mb-2 text-xs font-medium uppercase tracking-wide text-slate-500">
                    Artifacts
                  </h4>
                  <ul className="space-y-1 font-mono text-[10px] text-slate-400">
                    {runDetail.artifacts.map((a) => (
                      <li key={a.artifact_id}>{a.path || a.artifact_type}</li>
                    ))}
                  </ul>
                </div>
              )}

              <div>
                <h4 className="mb-2 text-xs font-medium uppercase tracking-wide text-slate-500">
                  Live tool events
                </h4>
                {toolEvents.length === 0 ? (
                  <p className="text-xs text-slate-600">No events yet (SSE connected when run selected).</p>
                ) : (
                  <ul className="max-h-48 space-y-1 overflow-y-auto font-mono text-[10px] text-slate-400">
                    {toolEvents.slice(-40).map((ev, i) => (
                      <li key={`${ev.type}-${i}`}>
                        [{ev.at ?? "?"}] {ev.type}
                        {typeof ev.tool === "string" ? ` ${ev.tool}` : ""}
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            </>
          )}
        </div>
      </div>

      <div className="border-t border-slate-800 bg-slate-900/20 px-4 py-3">
        <div className="mb-2 flex flex-wrap items-baseline justify-between gap-2">
          <h3 className="text-xs font-medium uppercase tracking-wide text-slate-500">
            Findings by severity (propose-only)
          </h3>
          {findingsInbox && (
            <p className="text-[10px] text-slate-600">
              {findingsInbox.count} issue(s)
              {findingsInbox.structured_count === 0 && findingsInbox.count > 0
                ? " — pipeline gaps (no structured Finding blocks yet)"
                : ""}
              {" · "}
              {findingsInbox.note}
            </p>
          )}
        </div>
        {!findingsInbox ? (
          <p className="text-xs text-slate-600">Loading findings...</p>
        ) : findingsInbox.findings.length === 0 ? (
          <p className="text-xs text-slate-600">
            No findings for {findingsInbox.date}. After audits emit ### Finding blocks,
            they appear here sorted by severity with a Would take action.
          </p>
        ) : (
          <ul className="max-h-64 space-y-2 overflow-y-auto">
            {findingsInbox.findings.map((f) => (
              <li
                key={f.id}
                className="rounded border border-slate-800 bg-slate-950/40 px-3 py-2"
              >
                <div className="flex flex-wrap items-center gap-2">
                  <span
                    className={`rounded border px-1.5 py-0.5 text-[10px] uppercase ${severityColor(f.severity)}`}
                  >
                    {f.severity}
                  </span>
                  {f.source === "pipeline_gap" && (
                    <span className="rounded border border-slate-700 px-1.5 py-0.5 text-[10px] text-slate-500">
                      pipeline
                    </span>
                  )}
                  {f.judge_verdict && (
                    <span className="text-[10px] text-slate-500">
                      judge: {f.judge_verdict}
                    </span>
                  )}
                  {f.run_id && (
                    <button
                      type="button"
                      onClick={() => setSelectedRunId(f.run_id)}
                      className="font-mono text-[10px] text-sky-500 hover:text-sky-300"
                    >
                      {f.run_id.slice(0, 8)}...
                    </button>
                  )}
                </div>
                <p className="mt-1 text-xs text-slate-300">{f.description}</p>
                {f.file && (
                  <p className="mt-0.5 font-mono text-[10px] text-slate-600">{f.file}</p>
                )}
                <p className="mt-2 text-xs text-slate-400">
                  <span className="font-medium text-slate-500">Would take: </span>
                  {f.would_take_action}
                </p>
                <p className="mt-0.5 text-[10px] text-slate-600">
                  Auto-apply: {f.would_auto_apply ? "yes" : "no (L1 human gate)"}
                </p>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="border-t border-slate-800 bg-slate-900/30 px-4 py-3">
        <h3 className="text-xs font-medium uppercase tracking-wide text-slate-500">
          Hub artifacts (today)
        </h3>
        {summary ? (
          <div className="mt-2 flex flex-wrap gap-4 text-xs text-slate-400">
            <span>Structured Finding blocks: {summary.finding_count}</span>
            <span>Inbox rows: {summary.inbox_count ?? findingsInbox?.count ?? 0}</span>
            <span>Judged lines: {summary.judged_count}</span>
            <span>Export: {timeAgo(summary.last_export_at)}</span>
            <span>Judge: {timeAgo(summary.last_judge_at)}</span>
            {summary.paths.cursor_review_md && (
              <span className="font-mono text-[10px] text-slate-500">
                {summary.paths.cursor_review_md}
              </span>
            )}
            {!summary.log_dir_accessible && (
              <span className="text-amber-400">Log dir not mounted in API container</span>
            )}
          </div>
        ) : (
          <p className="mt-1 text-xs text-slate-600">Loading artifact summary...</p>
        )}
      </div>
    </div>
  );
}
