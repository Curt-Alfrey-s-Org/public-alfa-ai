import { useCallback, useEffect, useState } from "react";
import { useAuth } from "../../contexts/AuthContext";
import { ApiError } from "../../api/client";

interface Incident {
  id: string;
  fingerprint: string;
  alertname: string;
  severity: string;
  status: string;
  labels: Record<string, string>;
  annotations: Record<string, string>;
  summary: string | null;
  opened_at: string;
  resolved_at: string | null;
  last_seen_at: string;
  updated_at: string;
}

interface IncidentEvent {
  id: string;
  event_type: string;
  payload: Record<string, unknown>;
  created_at: string;
}

interface AnalysisBriefing {
  evidence?: string[];
  ranked_causes?: string[];
  suggested_actions?: string[];
  blast_radius?: string;
  runbook_links?: string[];
  copy_for_verifier?: string;
}

interface RemediationProposal {
  id: string;
  incident_id: string;
  classification: string;
  root_cause: string;
  confidence: string;
  target_repo: string;
  target_path: string | null;
  proposed_change: string;
  rationale: string | null;
  briefing: AnalysisBriefing | null;
  status: string;
  pr_url: string | null;
  created_by: string | null;
  created_at: string;
}

const BASE = "/alfa-ai/api/admin";

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

function statusColor(status: string): string {
  switch (status) {
    case "resolved":
      return "text-emerald-400 bg-emerald-950/50 border-emerald-800";
    case "needs_human":
      return "text-amber-400 bg-amber-950/50 border-amber-800";
    case "investigating":
      return "text-sky-400 bg-sky-950/50 border-sky-800";
    case "received":
      return "text-violet-400 bg-violet-950/50 border-violet-800";
    default:
      return "text-slate-400 bg-slate-900 border-slate-700";
  }
}

function proposalStatusColor(status: string): string {
  switch (status) {
    case "applied":
      return "text-emerald-400 border-emerald-800";
    case "dismissed":
      return "text-slate-500 border-slate-700";
    default:
      return "text-sky-400 border-sky-700";
  }
}

function classificationLabel(c: string): string {
  switch (c) {
    case "alert_tuning":
      return "Alert tuning";
    case "code_fix":
      return "Code fix";
    case "ops_action":
      return "Ops action";
    default:
      return c;
  }
}

function timeAgo(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  return `${Math.floor(hrs / 24)}d ago`;
}

function runbookHref(link: string): string {
  if (link.startsWith("http://") || link.startsWith("https://")) return link;
  return `https://github.com/example/alfa-ai/blob/main/${link.replace(/^\//, "")}`;
}

function looksLikeUnifiedDiff(text: string): boolean {
  // Full-file proposals (YAML ---, markdown lists) are not patches.
  // Require a unified-diff header pair or hunk line.
  // https://www.gnu.org/software/diffutils/manual/html_node/Detailed-Unified.html
  const lines = text.split("\n");
  const hasGitHeader = lines.some((line) => line.startsWith("diff --git "));
  const hasOldFile = lines.some((line) => line.startsWith("--- "));
  const hasNewFile = lines.some((line) => line.startsWith("+++ "));
  const hasHunk = lines.some((line) => line.startsWith("@@ "));
  return hasGitHeader || (hasOldFile && hasNewFile) || hasHunk;
}

function diffLineClassName(line: string): string {
  if (line.startsWith("+") && !line.startsWith("+++")) {
    return "text-emerald-400";
  }
  if (line.startsWith("-") && !line.startsWith("---")) {
    return "text-rose-400";
  }
  return "text-slate-400";
}

function ProposedChangePreview({ text }: { text: string }) {
  if (!looksLikeUnifiedDiff(text)) {
    return (
      <pre className="max-h-48 overflow-auto whitespace-pre-wrap rounded border border-slate-800 bg-slate-950 p-2 text-[10px] text-slate-400">
        {text}
      </pre>
    );
  }
  const lines = text.split("\n");
  return (
    <pre className="max-h-48 overflow-auto whitespace-pre-wrap rounded border border-slate-800 bg-slate-950 p-2 text-[10px] font-mono">
      {lines.map((line, index) => (
        <span key={index} className={`block ${diffLineClassName(line)}`}>
          {line || " "}
        </span>
      ))}
    </pre>
  );
}

export default function IncidentsPage() {
  const { token } = useAuth();
  const [incidents, setIncidents] = useState<Incident[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [events, setEvents] = useState<IncidentEvent[]>([]);
  const [proposals, setProposals] = useState<RemediationProposal[]>([]);
  const [filter, setFilter] = useState<string>("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState("");
  const [confirmApply, setConfirmApply] = useState(false);
  const [forceLowConfidence, setForceLowConfidence] = useState(false);

  const loadList = useCallback(async () => {
    if (!token) return;
    try {
      const qs = filter ? `?status=${encodeURIComponent(filter)}` : "";
      const data = await apiFetch<{ incidents: Incident[] }>(`/incidents${qs}`, token);
      setIncidents(data.incidents);
      setError("");
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to load incidents");
    }
  }, [token, filter]);

  const loadDetail = useCallback(
    async (id: string) => {
      if (!token) return;
      try {
        const data = await apiFetch<{
          incident: Incident;
          events: IncidentEvent[];
          proposals: RemediationProposal[];
        }>(`/incidents/${id}`, token);
        setEvents(data.events);
        setProposals(data.proposals || []);
        setConfirmApply(false);
        setForceLowConfidence(false);
        setError("");
      } catch (err) {
        setError(err instanceof ApiError ? err.message : "Failed to load incident detail");
      }
    },
    [token],
  );

  useEffect(() => {
    loadList();
    const timer = setInterval(loadList, 30000);
    return () => clearInterval(timer);
  }, [loadList]);

  useEffect(() => {
    if (selectedId) loadDetail(selectedId);
  }, [selectedId, loadDetail]);

  const selected = incidents.find((i) => i.id === selectedId);
  const activeProposal = proposals.find((p) => p.status === "proposed") ?? proposals[0];
  const briefing = activeProposal?.briefing;
  const isLowConfidence = activeProposal?.confidence === "low";
  const runbookUrl =
    selected?.annotations.runbook_url ||
    selected?.labels.runbook_url ||
    selected?.annotations.runbook;

  const runAnalyze = async () => {
    if (!token || !selectedId) return;
    setBusy("analyze");
    setError("");
    try {
      const data = await apiFetch<{ proposal: RemediationProposal }>(
        `/incidents/${selectedId}/analyze`,
        token,
        { method: "POST", body: "{}" },
      );
      setProposals((prev) => [data.proposal, ...prev.filter((p) => p.id !== data.proposal.id)]);
      await loadDetail(selectedId);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Analysis failed");
    } finally {
      setBusy("");
    }
  };

  const runApply = async () => {
    if (!token || !selectedId || !activeProposal || !confirmApply) return;
    if (isLowConfidence && !forceLowConfidence) return;
    setBusy("apply");
    setError("");
    try {
      const data = await apiFetch<{ pr_url?: string; message?: string }>(
        `/incidents/${selectedId}/apply`,
        token,
        {
          method: "POST",
          body: JSON.stringify({
            proposal_id: activeProposal.id,
            confirm: true,
            force: isLowConfidence ? forceLowConfidence : false,
          }),
        },
      );
      await loadDetail(selectedId);
      if (data.pr_url) {
        window.open(data.pr_url, "_blank", "noopener,noreferrer");
      }
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Apply failed");
    } finally {
      setBusy("");
      setConfirmApply(false);
      setForceLowConfidence(false);
    }
  };

  const runDismiss = async () => {
    if (!token || !selectedId || !activeProposal) return;
    setBusy("dismiss");
    setError("");
    try {
      await apiFetch(`/incidents/${selectedId}/dismiss`, token, {
        method: "POST",
        body: JSON.stringify({ proposal_id: activeProposal.id, confirm: false }),
      });
      await loadDetail(selectedId);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Dismiss failed");
    } finally {
      setBusy("");
    }
  };

  const sendFeedback = async (helpful: boolean) => {
    if (!token || !selectedId || !activeProposal) return;
    setBusy("feedback");
    try {
      await apiFetch(`/incidents/${selectedId}/proposals/${activeProposal.id}/feedback`, token, {
        method: "POST",
        body: JSON.stringify({ helpful }),
      });
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Feedback failed");
    } finally {
      setBusy("");
    }
  };

  const exportPostmortem = async () => {
    if (!token || !selectedId) return;
    setBusy("postmortem");
    try {
      const data = await apiFetch<{ markdown: string }>(`/incidents/${selectedId}/postmortem`, token);
      const blob = new Blob([data.markdown], { type: "text/markdown" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `postmortem-${selected?.alertname || selectedId}.md`;
      a.click();
      URL.revokeObjectURL(url);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Postmortem export failed");
    } finally {
      setBusy("");
    }
  };

  const copyVerifierBlock = async () => {
    const text = briefing?.copy_for_verifier;
    if (!text) return;
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      setError("Could not copy verifier block to clipboard");
    }
  };

  return (
    <div className="flex h-full">
      <div className="flex w-1/2 flex-col border-r border-slate-800">
        <div className="flex items-center justify-between border-b border-slate-800 p-4">
          <h2 className="text-lg font-semibold text-slate-200">Monitoring</h2>
          <div className="flex gap-2">
            <select
              value={filter}
              onChange={(e) => setFilter(e.target.value)}
              className="rounded border border-slate-700 bg-slate-900 px-2 py-1 text-xs text-slate-300"
            >
              <option value="">All</option>
              <option value="received">Received</option>
              <option value="investigating">Investigating</option>
              <option value="needs_human">Needs human</option>
              <option value="resolved">Resolved</option>
            </select>
            <button
              type="button"
              onClick={loadList}
              className="rounded border border-slate-700 px-3 py-1 text-xs text-slate-400 hover:text-slate-200"
            >
              Refresh
            </button>
          </div>
        </div>
        {error && <p className="px-4 py-2 text-sm text-red-400">{error}</p>}
        <div className="flex-1 overflow-y-auto">
          {incidents.length === 0 ? (
            <p className="p-6 text-sm text-slate-500">No incidents recorded yet.</p>
          ) : (
            incidents.map((inc) => (
              <button
                key={inc.id}
                type="button"
                onClick={() => setSelectedId(inc.id)}
                className={`block w-full border-b border-slate-800/80 px-4 py-3 text-left hover:bg-slate-900/60 ${
                  selectedId === inc.id ? "bg-slate-900/80" : ""
                }`}
              >
                <div className="flex items-center justify-between gap-2">
                  <span className="font-medium text-slate-200">{inc.alertname}</span>
                  <span
                    className={`rounded border px-2 py-0.5 text-[10px] uppercase tracking-wide ${statusColor(inc.status)}`}
                  >
                    {inc.status.replace("_", " ")}
                  </span>
                </div>
                <p className="mt-1 truncate text-xs text-slate-500">
                  {inc.summary || inc.annotations.summary || "No summary"}
                </p>
                <p className="mt-1 text-[10px] text-slate-600">{timeAgo(inc.opened_at)}</p>
              </button>
            ))
          )}
        </div>
      </div>
      <div className="flex w-1/2 flex-col overflow-y-auto p-4">
        {!selected ? (
          <p className="text-sm text-slate-500">Select an incident to review alerts and AI proposals.</p>
        ) : (
          <>
            <div className="flex items-start justify-between gap-2">
              <div>
                <h3 className="text-base font-semibold text-slate-200">{selected.alertname}</h3>
                <p className="mt-1 text-xs text-slate-500">Severity: {selected.severity}</p>
              </div>
              <button
                type="button"
                disabled={busy === "postmortem"}
                onClick={exportPostmortem}
                className="rounded border border-slate-700 px-2 py-1 text-[10px] text-slate-400 hover:text-slate-200"
              >
                Export postmortem
              </button>
            </div>
            {runbookUrl && (
              <a
                href={runbookHref(String(runbookUrl))}
                target="_blank"
                rel="noopener noreferrer"
                className="mt-2 inline-block text-xs text-sky-400 hover:underline"
              >
                Runbook
              </a>
            )}
            {selected.summary && (
              <p className="mt-3 rounded border border-slate-800 bg-slate-900/50 p-3 text-sm text-slate-300">
                {selected.summary}
              </p>
            )}

            <div className="mt-6 rounded border border-slate-800 bg-slate-900/40 p-3">
              <div className="mb-2 flex items-center justify-between">
                <h4 className="text-xs font-semibold uppercase tracking-wide text-slate-500">
                  alfa-ai analysis
                </h4>
                <button
                  type="button"
                  disabled={busy === "analyze"}
                  onClick={runAnalyze}
                  className="rounded bg-sky-700 px-3 py-1 text-xs text-white hover:bg-sky-600 disabled:opacity-50"
                >
                  {busy === "analyze" ? "Analyzing..." : "Analyze with alfa-ai"}
                </button>
              </div>
              {!activeProposal ? (
                <p className="text-xs text-slate-500">No proposal yet. Run analysis to get a suggestion.</p>
              ) : (
                <div className="space-y-3 text-xs">
                  <div className="flex flex-wrap gap-2">
                    <span className="rounded border border-slate-700 px-2 py-0.5 text-slate-300">
                      {classificationLabel(activeProposal.classification)}
                    </span>
                    <span
                      className={`rounded border px-2 py-0.5 uppercase ${proposalStatusColor(activeProposal.status)}`}
                    >
                      {activeProposal.status}
                    </span>
                    <span className="text-slate-500">confidence: {activeProposal.confidence}</span>
                  </div>
                  <p className="text-slate-300">
                    <span className="font-medium text-slate-400">Root cause: </span>
                    {activeProposal.root_cause}
                  </p>
                  {activeProposal.rationale && (
                    <p className="text-slate-400">{activeProposal.rationale}</p>
                  )}
                  {briefing && (
                    <div className="space-y-2 rounded border border-slate-800 bg-slate-950/60 p-2">
                      {briefing.evidence && briefing.evidence.length > 0 && (
                        <div>
                          <p className="font-medium text-slate-500">Evidence</p>
                          <ul className="list-inside list-disc text-slate-400">
                            {briefing.evidence.map((item) => (
                              <li key={item}>{item}</li>
                            ))}
                          </ul>
                        </div>
                      )}
                      {briefing.ranked_causes && briefing.ranked_causes.length > 0 && (
                        <div>
                          <p className="font-medium text-slate-500">Ranked causes</p>
                          <ul className="list-inside list-decimal text-slate-400">
                            {briefing.ranked_causes.map((item) => (
                              <li key={item}>{item}</li>
                            ))}
                          </ul>
                        </div>
                      )}
                      {briefing.blast_radius && (
                        <p className="text-slate-400">
                          <span className="font-medium text-slate-500">Blast radius: </span>
                          {briefing.blast_radius}
                        </p>
                      )}
                      {briefing.runbook_links && briefing.runbook_links.length > 0 && (
                        <div className="flex flex-wrap gap-2">
                          {briefing.runbook_links.map((link) => (
                            <a
                              key={link}
                              href={runbookHref(link)}
                              target="_blank"
                              rel="noopener noreferrer"
                              className="text-sky-400 hover:underline"
                            >
                              {link.split("/").pop() || link}
                            </a>
                          ))}
                        </div>
                      )}
                      {briefing.copy_for_verifier && (
                        <button
                          type="button"
                          onClick={copyVerifierBlock}
                          className="rounded border border-slate-700 px-2 py-1 text-[10px] text-slate-400 hover:text-slate-200"
                        >
                          Copy for verifier model
                        </button>
                      )}
                    </div>
                  )}
                  {activeProposal.target_path ? (
                    <p className="font-medium text-slate-300">
                      {activeProposal.target_repo} / {activeProposal.target_path}
                    </p>
                  ) : (
                    activeProposal.target_repo && (
                      <p className="text-slate-500">Target repo: {activeProposal.target_repo}</p>
                    )
                  )}
                  <div>
                    <p className="mb-1 text-[10px] font-medium uppercase tracking-wide text-slate-500">
                      Proposed change (preview)
                    </p>
                    <ProposedChangePreview text={activeProposal.proposed_change} />
                  </div>
                  {activeProposal.pr_url && (
                    <a
                      href={activeProposal.pr_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="text-sky-400 hover:underline"
                    >
                      View pull request
                    </a>
                  )}
                  <div className="flex gap-2 border-t border-slate-800 pt-2">
                    <button
                      type="button"
                      disabled={busy === "feedback"}
                      onClick={() => sendFeedback(true)}
                      className="rounded border border-slate-700 px-2 py-1 text-slate-400 hover:text-emerald-400"
                    >
                      Helpful
                    </button>
                    <button
                      type="button"
                      disabled={busy === "feedback"}
                      onClick={() => sendFeedback(false)}
                      className="rounded border border-slate-700 px-2 py-1 text-slate-400 hover:text-amber-400"
                    >
                      Not helpful
                    </button>
                  </div>
                  {activeProposal.status === "proposed" && (
                    <div className="flex flex-col gap-2 border-t border-slate-800 pt-3">
                      {isLowConfidence && (
                        <p className="text-amber-400">
                          Low confidence: verify with a stronger model or operator review before applying.
                        </p>
                      )}
                      <label className="flex items-center gap-2 text-slate-400">
                        <input
                          type="checkbox"
                          checked={confirmApply}
                          onChange={(e) => setConfirmApply(e.target.checked)}
                        />
                        I confirm Go ahead (opens PR or records ops steps)
                      </label>
                      {isLowConfidence && (
                        <label className="flex items-center gap-2 text-slate-400">
                          <input
                            type="checkbox"
                            checked={forceLowConfidence}
                            onChange={(e) => setForceLowConfidence(e.target.checked)}
                          />
                          I verified this low-confidence proposal (force apply)
                        </label>
                      )}
                      <div className="flex gap-2">
                        <button
                          type="button"
                          disabled={
                            !confirmApply ||
                            busy === "apply" ||
                            (isLowConfidence && !forceLowConfidence)
                          }
                          onClick={runApply}
                          className="rounded bg-emerald-800 px-3 py-1 text-white hover:bg-emerald-700 disabled:opacity-50"
                        >
                          {busy === "apply" ? "Applying..." : "Go ahead"}
                        </button>
                        <button
                          type="button"
                          disabled={busy === "dismiss"}
                          onClick={runDismiss}
                          className="rounded border border-slate-700 px-3 py-1 text-slate-400 hover:text-slate-200"
                        >
                          Dismiss
                        </button>
                      </div>
                    </div>
                  )}
                </div>
              )}
            </div>

            <h4 className="mb-2 mt-6 text-xs font-semibold uppercase tracking-wide text-slate-500">
              Timeline
            </h4>
            <ul className="space-y-2">
              {events.map((ev) => (
                <li
                  key={ev.id}
                  className="rounded border border-slate-800 bg-slate-900/40 px-3 py-2 text-xs"
                >
                  <div className="flex justify-between text-slate-400">
                    <span className="font-medium text-slate-300">{ev.event_type}</span>
                    <span>{timeAgo(ev.created_at)}</span>
                  </div>
                  {Object.keys(ev.payload).length > 0 && (
                    <pre className="mt-2 max-h-40 overflow-auto whitespace-pre-wrap text-[10px] text-slate-500">
                      {JSON.stringify(ev.payload, null, 2)}
                    </pre>
                  )}
                </li>
              ))}
            </ul>
          </>
        )}
      </div>
    </div>
  );
}
