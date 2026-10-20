import { useCallback, useEffect, useState } from "react";
import { useAuth } from "../../contexts/AuthContext";
import { ApiError } from "../../api/client";
import {
  DumpLastTickPanel,
  DumpStructuredDetail,
  isSolarDumpAction,
  type DumpStatusResponse,
} from "../../components/admin/DumpLoadAuditPanel";

interface AiAction {
  id: string;
  category: string;
  action_type: string;
  summary: string;
  detail: Record<string, unknown>;
  severity: string | null;
  incident_id: string | null;
  created_by: string;
  created_at: string;
}

interface AiSetting {
  key: string;
  value: string;
  description: string;
  editable_by_ai: boolean;
  updated_by: string;
  updated_at: string;
}

interface HostAction {
  id: string;
  action_key: string;
  host: string;
  params: Record<string, unknown>;
  status: string;
  summary: string;
  command_run: string | null;
  stdout: string | null;
  stderr: string | null;
  exit_code: number | null;
  proposed_by: string;
  reviewed_by: string | null;
  created_at: string;
  executed_at: string | null;
}

interface EditableHost {
  key: string;
  name: string;
  lan_ip: string;
  ssh_user: string;
  os_type: string;
  repo_dir: string;
  health_url: string;
  enabled: boolean;
  source: string;
}

interface CatalogAction {
  key: string;
  description: string;
  mutating: boolean;
  enabled?: boolean;
}

interface ActionPack {
  id: string;
  label: string;
  description: string;
  actions: string[];
  default_on: boolean;
  enabled: boolean;
  enabled_count: number;
  total_count: number;
}

interface ReadinessItem {
  id: string;
  ok: boolean;
  label: string;
}

interface HostActionsReadiness {
  env_enabled: boolean;
  ssh_key_present: boolean;
  ssh_key_path: string;
  ready: boolean;
  missions_ready?: boolean;
  checklist: ReadinessItem[];
}

interface PromptHistoryEntry {
  text: string | null;
  updated_by: string;
  updated_at: string;
}

interface AgentConfig {
  system_prompt_default: string;
  system_prompt_override: string | null;
  system_prompt_effective: string;
  prompt_history: PromptHistoryEntry[];
  hosts_editable: EditableHost[];
  catalog_actions: CatalogAction[];
  disabled_actions: string[];
  packs: ActionPack[];
  readiness: HostActionsReadiness;
  context_sections: Record<string, boolean>;
  context_section_labels: Record<string, string>;
  updated_by: string;
  updated_at: string;
}

const BASE = "/alfa-ai/api/admin";

const AI_ACTIONS_DOCS_URL =
  "https://github.com/example/alfa-ai/blob/main/docs/AI_ACTIONS.md";

// Short usage example per ai_settings key, shown under the description in the Settings sub-tab.
// Full explanation lives in docs/AI_ACTIONS.md "Per-setting reference" (kept in sync manually --
// this is presentational only, the settings themselves are defined server-side in ai_setting.py).
const SETTINGS_EXAMPLES: Record<string, string> = {
  ai_triage_enabled:
    "Example: set to false while deliberately firing test alerts, so you don't get triaged AI emails for expected noise.",
  ai_can_adjust_settings:
    "Example: set to false once notify_min_severity is tuned the way you want, so the AI stops auto-adjusting it after a noisy night.",
  notify_email:
    "Example: operator@example.com to route AI alerts to a shared inbox. Leave blank to use ALFA_AI_INCIDENT_NOTIFY_EMAIL from deploy/.env.",
  notify_min_severity:
    "Example: critical to only be emailed for outages; low during an active incident so every triaged alert reaches you.",
  notify_quiet_hours:
    "Example: 22:00-07:00 holds AI emails overnight. Alerts are still logged immediately, just emailed once the window ends.",
  notify_dedup_minutes:
    "Example: 30 means a repeat of the same alert within 30 minutes of the last email won't send a second one.",
  chat_thinking_label:
    "Example: Thinking...|Still thinking...|Almost there... cycles those phrases while the model reasons. Blank hides the indicator entirely.",
};

const TABS: { id: string; label: string }[] = [
  { id: "all", label: "All" },
  { id: "alert", label: "Alert triage" },
  { id: "notifications", label: "Notifications" },
  { id: "settings", label: "Settings" },
  { id: "config", label: "AI Config" },
  { id: "host", label: "Host actions" },
  { id: "dump", label: "Dump load" },
  { id: "incidents", label: "Incident AI" },
];

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

function actionTypeColor(t: string): string {
  switch (t) {
    case "notification_sent":
      return "text-emerald-400 bg-emerald-950/50 border-emerald-800";
    case "notification_skipped":
      return "text-slate-400 bg-slate-900 border-slate-700";
    case "alert_triaged":
      return "text-sky-400 bg-sky-950/50 border-sky-800";
    case "setting_changed":
      return "text-amber-400 bg-amber-950/50 border-amber-800";
    case "agent_config_changed":
      return "text-amber-400 bg-amber-950/50 border-amber-800";
    case "host_command_executed":
      return "text-cyan-400 bg-cyan-950/50 border-cyan-800";
    case "solar_dump_observed":
      return "text-lime-400 bg-lime-950/50 border-lime-800";
    case "solar_dump_recommended":
      return "text-amber-400 bg-amber-950/50 border-amber-800";
    case "solar_dump_actuated":
      return "text-emerald-400 bg-emerald-950/50 border-emerald-800";
    default:
      return "text-violet-400 bg-violet-950/50 border-violet-800";
  }
}

function severityColor(s: string | null): string {
  switch ((s || "").toLowerCase()) {
    case "critical":
      return "text-red-400 border-red-800";
    case "high":
      return "text-amber-400 border-amber-800";
    case "medium":
      return "text-sky-400 border-sky-800";
    case "low":
      return "text-slate-400 border-slate-700";
    default:
      return "text-slate-500 border-slate-700";
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

function formatPromptHistoryTimestamp(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString();
}

function promptHistoryPreview(text: string | null, maxLen = 80): string {
  if (!text || !text.trim()) return "default prompt";
  const oneLine = text.replace(/\s+/g, " ").trim();
  if (oneLine.length <= maxLen) return oneLine;
  return `${oneLine.slice(0, maxLen)}...`;
}

export default function AiActionsPage() {
  const { token } = useAuth();
  const [tab, setTab] = useState<string>("all");
  const [actions, setActions] = useState<AiAction[]>([]);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [settings, setSettings] = useState<AiSetting[]>([]);
  const [hostActions, setHostActions] = useState<HostAction[]>([]);
  const [selectedHostId, setSelectedHostId] = useState<string | null>(null);
  const [agentConfig, setAgentConfig] = useState<AgentConfig | null>(null);
  const [promptDraft, setPromptDraft] = useState("");
  const [hostDrafts, setHostDrafts] = useState<EditableHost[]>([]);
  const [actionEnabled, setActionEnabled] = useState<Record<string, boolean>>({});
  const [contextDrafts, setContextDrafts] = useState<Record<string, boolean>>({});
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [error, setError] = useState("");
  const [busy, setBusy] = useState("");
  const [dumpStatus, setDumpStatus] = useState<DumpStatusResponse | null>(null);

  const loadFeed = useCallback(async () => {
    if (!token) return;
    const feedCategory =
      tab === "host-actions-panel" ? "host" : tab === "config-panel" ? "settings" : tab;
    if (feedCategory === "host-actions-panel") return;
    try {
      const data = await apiFetch<{ actions: AiAction[] }>(
        `/ai-actions?category=${encodeURIComponent(feedCategory)}&limit=100`,
        token,
      );
      setActions(data.actions);
      setError("");
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to load AI actions");
    }
  }, [token, tab]);

  const loadSettings = useCallback(async () => {
    if (!token) return;
    try {
      const data = await apiFetch<{ settings: AiSetting[] }>("/ai-settings", token);
      setSettings(data.settings);
      setDrafts(Object.fromEntries(data.settings.map((s) => [s.key, s.value])));
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to load AI settings");
    }
  }, [token]);

  const loadHostActions = useCallback(async () => {
    if (!token) return;
    try {
      const data = await apiFetch<{ actions: HostAction[] }>("/host-actions?limit=100", token);
      setHostActions(data.actions);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to load host actions");
    }
  }, [token]);

  const loadAgentConfig = useCallback(async () => {
    if (!token) return;
    try {
      const data = await apiFetch<{ config: AgentConfig }>("/agent-config", token);
      const cfg = data.config;
      setAgentConfig(cfg);
      setPromptDraft(cfg.system_prompt_override ?? cfg.system_prompt_default);
      setHostDrafts(cfg.hosts_editable.map((h) => ({ ...h })));
      setActionEnabled(
        Object.fromEntries(cfg.catalog_actions.map((a) => [a.key, a.enabled !== false])),
      );
      setContextDrafts({ ...cfg.context_sections });
      setError("");
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to load AI config");
    }
  }, [token]);

  const loadDumpStatus = useCallback(async () => {
    if (!token) return;
    try {
      const data = await apiFetch<DumpStatusResponse>("/dump-status", token);
      setDumpStatus(data);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to load dump status");
    }
  }, [token]);

  useEffect(() => {
    if (tab === "host-actions-panel" || tab === "dump") return;
    loadFeed();
    const timer = setInterval(loadFeed, 30000);
    return () => clearInterval(timer);
  }, [loadFeed, tab]);

  useEffect(() => {
    if (tab !== "dump") return;
    loadDumpStatus();
    loadFeed();
    // UI poll only; server ticker uses ha_interval_seconds.
    const timer = setInterval(() => {
      loadDumpStatus();
      loadFeed();
    }, 10000);
    return () => clearInterval(timer);
  }, [tab, loadDumpStatus, loadFeed]);

  useEffect(() => {
    loadSettings();
  }, [loadSettings]);

  useEffect(() => {
    if (tab === "host-actions-panel") {
      loadHostActions();
      const timer = setInterval(loadHostActions, 15000);
      return () => clearInterval(timer);
    }
  }, [tab, loadHostActions]);

  useEffect(() => {
    if (tab === "config-panel") {
      loadAgentConfig();
    }
  }, [tab, loadAgentConfig]);

  const reviewHostAction = async (actionId: string, approve: boolean) => {
    if (!token) return;
    setBusy(actionId);
    setError("");
    try {
      const path = approve
        ? `/host-actions/${actionId}/approve`
        : `/host-actions/${actionId}/reject`;
      await apiFetch(path, token, { method: "POST" });
      await loadHostActions();
      await loadFeed();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Host action review failed");
    } finally {
      setBusy("");
    }
  };

  const saveSetting = async (key: string) => {
    if (!token) return;
    setBusy(key);
    setError("");
    try {
      await apiFetch("/ai-settings", token, {
        method: "POST",
        body: JSON.stringify({ key, value: drafts[key] ?? "" }),
      });
      await loadSettings();
      await loadFeed();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to save setting");
    } finally {
      setBusy("");
    }
  };

  const savePrompt = async () => {
    if (!token || !agentConfig) return;
    setBusy("prompt");
    setError("");
    try {
      const usingDefault = promptDraft.trim() === agentConfig.system_prompt_default.trim();
      await apiFetch("/agent-config/prompt", token, {
        method: "POST",
        body: JSON.stringify({ text: usingDefault ? null : promptDraft }),
      });
      await loadAgentConfig();
      await loadFeed();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to save system prompt");
    } finally {
      setBusy("");
    }
  };

  const restorePromptToDraft = (entry: PromptHistoryEntry) => {
    if (!agentConfig) return;
    const restored = (entry.text ?? "").trim();
    setPromptDraft(restored || agentConfig.system_prompt_default);
  };

  const resetPrompt = async () => {
    if (!token || !agentConfig) return;
    setPromptDraft(agentConfig.system_prompt_default);
    setBusy("prompt-reset");
    setError("");
    try {
      await apiFetch("/agent-config/prompt", token, {
        method: "POST",
        body: JSON.stringify({ text: null }),
      });
      await loadAgentConfig();
      await loadFeed();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to reset system prompt");
    } finally {
      setBusy("");
    }
  };

  const saveHosts = async () => {
    if (!token) return;
    setBusy("hosts");
    setError("");
    try {
      const payload = hostDrafts
        .filter((h) => h.key.trim())
        .map((h) => ({
        key: h.key,
        name: h.name,
        lan_ip: h.lan_ip,
        ssh_user: h.ssh_user,
        os_type: h.os_type,
        repo_dir: h.repo_dir,
        health_url: h.health_url || undefined,
        enabled: h.enabled,
      }));
      await apiFetch("/agent-config/hosts", token, {
        method: "POST",
        body: JSON.stringify({ hosts: payload }),
      });
      await loadAgentConfig();
      await loadFeed();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to save hosts");
    } finally {
      setBusy("");
    }
  };

  const saveActions = async () => {
    if (!token) return;
    setBusy("actions");
    setError("");
    try {
      const disabled = Object.entries(actionEnabled)
        .filter(([, enabled]) => !enabled)
        .map(([key]) => key);
      await apiFetch("/agent-config/actions", token, {
        method: "POST",
        body: JSON.stringify({ disabled_actions: disabled }),
      });
      await loadAgentConfig();
      await loadFeed();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to save action toggles");
    } finally {
      setBusy("");
    }
  };

  const togglePack = async (packId: string, enabled: boolean) => {
    if (!token) return;
    setBusy(`pack-${packId}`);
    setError("");
    try {
      await apiFetch("/agent-config/packs", token, {
        method: "POST",
        body: JSON.stringify({ pack_id: packId, enabled }),
      });
      await loadAgentConfig();
      await loadFeed();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to toggle pack");
    } finally {
      setBusy("");
    }
  };

  const saveContext = async () => {
    if (!token) return;
    setBusy("context");
    setError("");
    try {
      await apiFetch("/agent-config/context", token, {
        method: "POST",
        body: JSON.stringify({ context_sections: contextDrafts }),
      });
      await loadAgentConfig();
      await loadFeed();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to save context settings");
    } finally {
      setBusy("");
    }
  };

  const addHostRow = () => {
    setHostDrafts((rows) => [
      ...rows,
      {
        key: "",
        name: "",
        lan_ip: "",
        ssh_user: "",
        os_type: "linux",
        repo_dir: "",
        health_url: "",
        enabled: true,
        source: "override",
      },
    ]);
  };

  const updateHostRow = (index: number, patch: Partial<EditableHost>) => {
    setHostDrafts((rows) => rows.map((row, i) => (i === index ? { ...row, ...patch } : row)));
  };

  const removeHostRow = (index: number) => {
    setHostDrafts((rows) => rows.filter((_, i) => i !== index));
  };

  const selected = actions.find((a) => a.id === selectedId);
  const selectedHost = hostActions.find((h) => h.id === selectedHostId);

  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center justify-between border-b border-slate-800 p-4">
        <h2 className="text-lg font-semibold text-slate-200">AI Actions</h2>
        <div className="flex gap-1">
          {TABS.map((t) => (
            <button
              key={t.id}
              type="button"
              onClick={() => {
                setTab(
                  t.id === "host" ? "host-actions-panel" : t.id === "config" ? "config-panel" : t.id,
                );
                setSelectedId(null);
                setSelectedHostId(null);
              }}
              className={`rounded px-3 py-1 text-xs font-medium transition ${
                tab === t.id ||
                (t.id === "host" && tab === "host-actions-panel") ||
                (t.id === "config" && tab === "config-panel")
                  ? "bg-sky-600 text-white"
                  : "text-slate-400 hover:bg-slate-800 hover:text-slate-200"
              }`}
            >
              {t.label}
            </button>
          ))}
        </div>
      </div>
      {error && <p className="px-4 py-2 text-sm text-red-400">{error}</p>}

      {tab === "settings" ? (
        <div className="flex-1 overflow-y-auto p-4">
          <p className="mb-4 max-w-2xl text-xs text-slate-500">
            The AI may change keys marked "AI may edit" on its own (e.g. raise the notify threshold
            when it is too noisy). Every change is logged in this feed. Edit any value below to
            override or revert what the AI did. Each setting below has an example; see{" "}
            <a
              href={AI_ACTIONS_DOCS_URL}
              target="_blank"
              rel="noopener noreferrer"
              className="text-sky-400 hover:underline"
            >
              docs/AI_ACTIONS.md
            </a>{" "}
            for the full alert-triage/notification flow and every setting's effect.
          </p>
          <div className="space-y-3">
            {settings.map((s) => (
              <div
                key={s.key}
                className="rounded border border-slate-800 bg-slate-900/40 p-3"
              >
                <div className="flex items-center justify-between gap-2">
                  <span className="font-mono text-sm text-slate-200">{s.key}</span>
                  <span
                    className={`rounded border px-2 py-0.5 text-[10px] uppercase tracking-wide ${
                      s.editable_by_ai
                        ? "border-amber-800 text-amber-400"
                        : "border-slate-700 text-slate-500"
                    }`}
                  >
                    {s.editable_by_ai ? "AI may edit" : "You only"}
                  </span>
                </div>
                <p className="mt-1 text-xs text-slate-500">{s.description}</p>
                {SETTINGS_EXAMPLES[s.key] && (
                  <p className="mt-1 text-xs text-slate-400">{SETTINGS_EXAMPLES[s.key]}</p>
                )}
                <a
                  href={`${AI_ACTIONS_DOCS_URL}#${s.key}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="mt-1 inline-block text-xs text-sky-400 hover:underline"
                >
                  Learn more &rarr;
                </a>
                <div className="mt-2 flex items-center gap-2">
                  <input
                    value={drafts[s.key] ?? ""}
                    onChange={(e) => setDrafts((d) => ({ ...d, [s.key]: e.target.value }))}
                    className="flex-1 rounded border border-slate-700 bg-slate-950 px-2 py-1 text-xs text-slate-200"
                  />
                  <button
                    type="button"
                    disabled={busy === s.key || (drafts[s.key] ?? "") === s.value}
                    onClick={() => saveSetting(s.key)}
                    className="rounded bg-emerald-800 px-3 py-1 text-xs text-white hover:bg-emerald-700 disabled:opacity-50"
                  >
                    {busy === s.key ? "Saving..." : "Save"}
                  </button>
                </div>
                <p className="mt-1 text-[10px] text-slate-600">
                  Last set by {s.updated_by} - {timeAgo(s.updated_at)}
                </p>
              </div>
            ))}
          </div>
        </div>
      ) : tab === "config-panel" ? (
        <div className="flex-1 overflow-y-auto p-4">
          {!agentConfig ? (
            <p className="text-sm text-slate-500">Loading AI configuration...</p>
          ) : (
            <div className="mx-auto max-w-4xl space-y-8">
              <p className="text-xs text-slate-500">
                Changes apply immediately to Ask ALFa (no redeploy). Every save is logged in the AI
                Actions feed. SSH keys and ALFA_AI_HOST_ACTIONS_ENABLED remain env-level kill switches.
              </p>
              <p className="text-[10px] text-slate-600">
                Last config update by {agentConfig.updated_by} - {timeAgo(agentConfig.updated_at)}
              </p>

              <section className="rounded border border-slate-800 bg-slate-900/40 p-4">
                <h3 className="text-sm font-semibold text-slate-200">System prompt</h3>
                <p className="mt-1 text-xs text-slate-500">
                  Full freeform instructions for the admin Ask ALFa agent. Keep the JSON reply format
                  if you want setting changes and host proposals to parse correctly.
                </p>
                <textarea
                  value={promptDraft}
                  onChange={(e) => setPromptDraft(e.target.value)}
                  rows={14}
                  className="mt-3 w-full rounded border border-slate-700 bg-slate-950 px-3 py-2 font-mono text-xs text-slate-200"
                />
                <div className="mt-3 flex gap-2">
                  <button
                    type="button"
                    disabled={busy === "prompt"}
                    onClick={savePrompt}
                    className="rounded bg-emerald-800 px-3 py-1 text-xs text-white hover:bg-emerald-700 disabled:opacity-50"
                  >
                    {busy === "prompt" ? "Saving..." : "Save prompt"}
                  </button>
                  <button
                    type="button"
                    disabled={busy === "prompt-reset"}
                    onClick={resetPrompt}
                    className="rounded border border-slate-600 px-3 py-1 text-xs text-slate-300 hover:bg-slate-800 disabled:opacity-50"
                  >
                    Reset to default
                  </button>
                </div>
                <div className="mt-4 border-t border-slate-800 pt-4">
                  <h4 className="text-xs font-semibold text-slate-300">Prompt version history</h4>
                  <p className="mt-1 text-[10px] text-slate-600">
                    Newest first (up to 20 prior versions). Restore copies into the editor only;
                    click Save prompt to apply.
                  </p>
                  {(agentConfig.prompt_history?.length ?? 0) === 0 ? (
                    <p className="mt-2 text-xs text-slate-500">No previous versions.</p>
                  ) : (
                    <ul className="mt-2 max-h-48 space-y-2 overflow-y-auto">
                      {[...(agentConfig.prompt_history ?? [])]
                        .reverse()
                        .map((entry, index) => (
                          <li
                            key={`${entry.updated_at}-${index}`}
                            className="flex items-start justify-between gap-3 rounded border border-slate-800 bg-slate-950/40 px-3 py-2"
                          >
                            <div className="min-w-0 flex-1">
                              <p className="text-[10px] text-slate-500">
                                {formatPromptHistoryTimestamp(entry.updated_at)} by {entry.updated_by}
                              </p>
                              <p className="mt-0.5 truncate font-mono text-xs text-slate-400">
                                {promptHistoryPreview(entry.text)}
                              </p>
                            </div>
                            <button
                              type="button"
                              onClick={() => restorePromptToDraft(entry)}
                              className="shrink-0 rounded border border-slate-600 px-2 py-1 text-[10px] text-slate-300 hover:bg-slate-800"
                            >
                              Restore to draft
                            </button>
                          </li>
                        ))}
                    </ul>
                  )}
                </div>
              </section>

              <section className="rounded border border-slate-800 bg-slate-900/40 p-4">
                <h3 className="text-sm font-semibold text-slate-200">Host registry</h3>
                <p className="mt-1 text-xs text-slate-500">
                  Which cluster hosts Ask ALFa may target. New hosts require SSH pubkey already
                  installed on that host; this only registers credentials the API already has.
                </p>
                <div className="mt-3 space-y-3">
                  {hostDrafts.map((host, index) => (
                    <div
                      key={`${host.key}-${index}`}
                      className="rounded border border-slate-800 bg-slate-950/60 p-3"
                    >
                      <div className="mb-2 flex items-center justify-between gap-2">
                        <span className="text-[10px] uppercase tracking-wide text-slate-600">
                          {host.source || "override"}
                        </span>
                        <label className="flex items-center gap-2 text-xs text-slate-400">
                          <input
                            type="checkbox"
                            checked={host.enabled}
                            onChange={(e) => updateHostRow(index, { enabled: e.target.checked })}
                          />
                          Enabled
                        </label>
                      </div>
                      <div className="grid gap-2 sm:grid-cols-2">
                        <input
                          placeholder="key (e.g. 100)"
                          value={host.key}
                          onChange={(e) => updateHostRow(index, { key: e.target.value })}
                          className="rounded border border-slate-700 bg-slate-950 px-2 py-1 text-xs text-slate-200"
                        />
                        <input
                          placeholder="name"
                          value={host.name}
                          onChange={(e) => updateHostRow(index, { name: e.target.value })}
                          className="rounded border border-slate-700 bg-slate-950 px-2 py-1 text-xs text-slate-200"
                        />
                        <input
                          placeholder="lan_ip"
                          value={host.lan_ip}
                          onChange={(e) => updateHostRow(index, { lan_ip: e.target.value })}
                          className="rounded border border-slate-700 bg-slate-950 px-2 py-1 text-xs text-slate-200"
                        />
                        <input
                          placeholder="ssh_user"
                          value={host.ssh_user}
                          onChange={(e) => updateHostRow(index, { ssh_user: e.target.value })}
                          className="rounded border border-slate-700 bg-slate-950 px-2 py-1 text-xs text-slate-200"
                        />
                        <select
                          value={host.os_type}
                          onChange={(e) => updateHostRow(index, { os_type: e.target.value })}
                          className="rounded border border-slate-700 bg-slate-950 px-2 py-1 text-xs text-slate-200"
                        >
                          <option value="linux">linux</option>
                          <option value="windows">windows</option>
                        </select>
                        <input
                          placeholder="repo_dir"
                          value={host.repo_dir}
                          onChange={(e) => updateHostRow(index, { repo_dir: e.target.value })}
                          className="rounded border border-slate-700 bg-slate-950 px-2 py-1 text-xs text-slate-200"
                        />
                        <input
                          placeholder="health_url (optional)"
                          value={host.health_url}
                          onChange={(e) => updateHostRow(index, { health_url: e.target.value })}
                          className="sm:col-span-2 rounded border border-slate-700 bg-slate-950 px-2 py-1 text-xs text-slate-200"
                        />
                      </div>
                      {host.source === "override" && (
                        <button
                          type="button"
                          onClick={() => removeHostRow(index)}
                          className="mt-2 text-xs text-red-400 hover:text-red-300"
                        >
                          Remove row
                        </button>
                      )}
                    </div>
                  ))}
                </div>
                <div className="mt-3 flex gap-2">
                  <button
                    type="button"
                    onClick={addHostRow}
                    className="rounded border border-slate-600 px-3 py-1 text-xs text-slate-300 hover:bg-slate-800"
                  >
                    Add host
                  </button>
                  <button
                    type="button"
                    disabled={busy === "hosts"}
                    onClick={saveHosts}
                    className="rounded bg-emerald-800 px-3 py-1 text-xs text-white hover:bg-emerald-700 disabled:opacity-50"
                  >
                    {busy === "hosts" ? "Saving..." : "Save hosts"}
                  </button>
                </div>
              </section>

              <section className="rounded border border-slate-800 bg-slate-900/40 p-4">
                <h3 className="text-sm font-semibold text-slate-200">Host actions readiness</h3>
                <p className="mt-1 text-xs text-slate-500">
                  One-time infra only (env + SSH key). Soft packs are enabled automatically when
                  you Approve a request in Ask ALFa -- you do not need to pre-toggle them.
                </p>
                {agentConfig.readiness ? (
                  <ul className="mt-3 space-y-2">
                    {agentConfig.readiness.checklist.map((item) => (
                      <li
                        key={item.id}
                        className="flex items-start gap-2 rounded border border-slate-800 bg-slate-950/40 px-3 py-2 text-xs"
                      >
                        <span
                          className={
                            item.ok
                              ? "mt-0.5 text-emerald-400"
                              : "mt-0.5 text-amber-400"
                          }
                        >
                          {item.ok ? "OK" : "!"}
                        </span>
                        <span className="text-slate-300">{item.label}</span>
                      </li>
                    ))}
                  </ul>
                ) : (
                  <p className="mt-2 text-xs text-slate-500">Reload AI Config after deploy.</p>
                )}
                {agentConfig.readiness && !agentConfig.readiness.ready && (
                  <p className="mt-2 text-xs text-amber-400">
                    SSH host actions stay blocked until env + SSH key are both OK.
                    Missions enqueue still works when env is on (no SSH key required).
                  </p>
                )}
              </section>

              <section className="rounded border border-slate-800 bg-slate-900/40 p-4">
                <h3 className="text-sm font-semibold text-slate-200">Capability packs</h3>
                <p className="mt-1 text-xs text-slate-500">
                  Optional defaults / lockouts. Soft-disabled packs can still be proposed in chat;
                  Approve enables them for that request. Prefer Ask ALFa Approve over managing
                  these for routine work.
                </p>
                <div className="mt-3 space-y-3">
                  {(agentConfig.packs || []).map((pack) => (
                    <div
                      key={pack.id}
                      className="rounded border border-slate-800 bg-slate-950/40 p-3"
                    >
                      <div className="flex items-start justify-between gap-3">
                        <div>
                          <div className="flex items-center gap-2">
                            <span className="text-sm text-slate-200">{pack.label}</span>
                            <span className="font-mono text-[10px] text-slate-600">
                              {pack.enabled_count}/{pack.total_count}
                            </span>
                            {pack.default_on && (
                              <span className="rounded border border-slate-700 px-1 text-[10px] text-slate-500">
                                default on
                              </span>
                            )}
                          </div>
                          <p className="mt-1 text-xs text-slate-500">{pack.description}</p>
                          <p className="mt-1 font-mono text-[10px] text-slate-600">
                            {pack.actions.join(", ")}
                          </p>
                        </div>
                        <button
                          type="button"
                          disabled={busy === `pack-${pack.id}`}
                          onClick={() => togglePack(pack.id, !pack.enabled)}
                          className={
                            pack.enabled
                              ? "shrink-0 rounded bg-emerald-800 px-3 py-1 text-xs text-white hover:bg-emerald-700 disabled:opacity-50"
                              : "shrink-0 rounded border border-slate-600 px-3 py-1 text-xs text-slate-300 hover:bg-slate-800 disabled:opacity-50"
                          }
                        >
                          {busy === `pack-${pack.id}`
                            ? "..."
                            : pack.enabled
                              ? "On"
                              : "Off"}
                        </button>
                      </div>
                    </div>
                  ))}
                </div>
              </section>

              <section className="rounded border border-slate-800 bg-slate-900/40 p-4">
                <h3 className="text-sm font-semibold text-slate-200">Advanced: per-action</h3>
                <p className="mt-1 text-xs text-slate-500">
                  Prefer packs above. Use this only to leave one action off inside an enabled pack.
                </p>
                <div className="mt-3 max-h-64 space-y-2 overflow-y-auto">
                  {agentConfig.catalog_actions.map((action) => (
                    <label
                      key={action.key}
                      className="flex items-start gap-3 rounded border border-slate-800 bg-slate-950/40 p-3"
                    >
                      <input
                        type="checkbox"
                        checked={actionEnabled[action.key] !== false}
                        onChange={(e) =>
                          setActionEnabled((prev) => ({ ...prev, [action.key]: e.target.checked }))
                        }
                        className="mt-0.5"
                      />
                      <span>
                        <span className="font-mono text-xs text-slate-200">{action.key}</span>
                        {action.mutating && (
                          <span className="ml-2 rounded border border-amber-800 px-1 text-[10px] text-amber-400">
                            mutating
                          </span>
                        )}
                        <p className="mt-1 text-xs text-slate-500">{action.description}</p>
                      </span>
                    </label>
                  ))}
                </div>
                <button
                  type="button"
                  disabled={busy === "actions"}
                  onClick={saveActions}
                  className="mt-3 rounded bg-emerald-800 px-3 py-1 text-xs text-white hover:bg-emerald-700 disabled:opacity-50"
                >
                  {busy === "actions" ? "Saving..." : "Save per-action overrides"}
                </button>
              </section>

              <section className="rounded border border-slate-800 bg-slate-900/40 p-4">
                <h3 className="text-sm font-semibold text-slate-200">Context visibility</h3>
                <p className="mt-1 text-xs text-slate-500">
                  Unchecked sections are not fetched at all for Ask ALFa (not just hidden from the reply).
                </p>
                <div className="mt-3 space-y-2">
                  {Object.entries(agentConfig.context_section_labels).map(([key, label]) => (
                    <label
                      key={key}
                      className="flex items-center gap-3 rounded border border-slate-800 bg-slate-950/40 px-3 py-2"
                    >
                      <input
                        type="checkbox"
                        checked={contextDrafts[key] !== false}
                        onChange={(e) =>
                          setContextDrafts((prev) => ({ ...prev, [key]: e.target.checked }))
                        }
                      />
                      <span className="text-xs text-slate-300">{label}</span>
                      <span className="font-mono text-[10px] text-slate-600">{key}</span>
                    </label>
                  ))}
                </div>
                <button
                  type="button"
                  disabled={busy === "context"}
                  onClick={saveContext}
                  className="mt-3 rounded bg-emerald-800 px-3 py-1 text-xs text-white hover:bg-emerald-700 disabled:opacity-50"
                >
                  {busy === "context" ? "Saving..." : "Save context"}
                </button>
              </section>
            </div>
          )}
        </div>
      ) : tab === "host-actions-panel" ? (
        <div className="flex flex-1 overflow-hidden">
          <div className="flex w-1/2 flex-col border-r border-slate-800">
            <div className="flex items-center justify-between border-b border-slate-800 px-4 py-2">
              <span className="text-xs text-slate-500">Pending require Approve before run</span>
              <button
                type="button"
                onClick={loadHostActions}
                className="rounded border border-slate-700 px-3 py-1 text-xs text-slate-400 hover:text-slate-200"
              >
                Refresh
              </button>
            </div>
            <div className="flex-1 overflow-y-auto">
              {hostActions.length === 0 ? (
                <p className="p-6 text-sm text-slate-500">No host actions yet.</p>
              ) : (
                hostActions.map((h) => (
                  <button
                    key={h.id}
                    type="button"
                    onClick={() => setSelectedHostId(h.id)}
                    className={`block w-full border-b border-slate-800/80 px-4 py-3 text-left hover:bg-slate-900/60 ${
                      selectedHostId === h.id ? "bg-slate-900/80" : ""
                    }`}
                  >
                    <div className="flex items-center justify-between gap-2">
                      <span className="truncate font-medium text-slate-200">{h.summary}</span>
                      <span
                        className={`shrink-0 rounded border px-2 py-0.5 text-[10px] uppercase ${
                          h.status === "pending"
                            ? "border-amber-800 text-amber-400"
                            : h.status === "executed"
                              ? "border-emerald-800 text-emerald-400"
                              : h.status === "rejected"
                                ? "border-slate-700 text-slate-500"
                                : "border-red-800 text-red-400"
                        }`}
                      >
                        {h.status}
                      </span>
                    </div>
                    <p className="mt-1 text-[10px] text-slate-600">
                      by {h.proposed_by} - {timeAgo(h.created_at)}
                    </p>
                  </button>
                ))
              )}
            </div>
          </div>
          <div className="flex w-1/2 flex-col overflow-y-auto p-4">
            {!selectedHost ? (
              <p className="text-sm text-slate-500">Select a host action to review output.</p>
            ) : (
              <>
                <h3 className="text-base font-semibold text-slate-200">{selectedHost.summary}</h3>
                <p className="mt-1 text-xs text-slate-500">
                  {selectedHost.action_key} on host {selectedHost.host} - {selectedHost.status}
                </p>
                {selectedHost.status === "pending" && (
                  <div className="mt-4 flex gap-2">
                    <button
                      type="button"
                      disabled={busy === selectedHost.id}
                      onClick={() => reviewHostAction(selectedHost.id, true)}
                      className="rounded bg-emerald-700 px-3 py-1 text-xs text-white hover:bg-emerald-600 disabled:opacity-40"
                    >
                      {busy === selectedHost.id ? "Running..." : "Approve and run"}
                    </button>
                    <button
                      type="button"
                      disabled={busy === selectedHost.id}
                      onClick={() => reviewHostAction(selectedHost.id, false)}
                      className="rounded border border-slate-600 px-3 py-1 text-xs text-slate-300 hover:bg-slate-800 disabled:opacity-40"
                    >
                      Reject
                    </button>
                  </div>
                )}
                {selectedHost.command_run && (
                  <>
                    <h4 className="mb-2 mt-6 text-xs font-semibold uppercase text-slate-500">Command</h4>
                    <pre className="rounded border border-slate-800 bg-slate-950 p-3 text-[11px] text-slate-400">
                      {selectedHost.command_run}
                    </pre>
                  </>
                )}
                {selectedHost.stdout && (
                  <>
                    <h4 className="mb-2 mt-4 text-xs font-semibold uppercase text-slate-500">Stdout</h4>
                    <pre className="max-h-48 overflow-auto whitespace-pre-wrap rounded border border-slate-800 bg-slate-950 p-3 text-[11px] text-slate-400">
                      {selectedHost.stdout}
                    </pre>
                  </>
                )}
                {selectedHost.stderr && (
                  <>
                    <h4 className="mb-2 mt-4 text-xs font-semibold uppercase text-slate-500">Stderr</h4>
                    <pre className="max-h-32 overflow-auto whitespace-pre-wrap rounded border border-red-900/50 bg-slate-950 p-3 text-[11px] text-red-400/80">
                      {selectedHost.stderr}
                    </pre>
                  </>
                )}
              </>
            )}
          </div>
        </div>
      ) : (
        <div className="flex flex-1 flex-col overflow-hidden">
          {tab === "dump" && <DumpLastTickPanel status={dumpStatus} />}
          <div className="flex flex-1 overflow-hidden">
          <div className="flex w-1/2 flex-col border-r border-slate-800">
            <div className="flex items-center justify-end border-b border-slate-800 px-4 py-2">
              <button
                type="button"
                onClick={() => {
                  loadFeed();
                  if (tab === "dump") loadDumpStatus();
                }}
                className="rounded border border-slate-700 px-3 py-1 text-xs text-slate-400 hover:text-slate-200"
              >
                Refresh
              </button>
            </div>
            <div className="flex-1 overflow-y-auto">
              {actions.length === 0 ? (
                <p className="p-6 text-sm text-slate-500">No AI actions recorded yet.</p>
              ) : (
                actions.map((a) => (
                  <button
                    key={a.id}
                    type="button"
                    onClick={() => setSelectedId(a.id)}
                    className={`block w-full border-b border-slate-800/80 px-4 py-3 text-left hover:bg-slate-900/60 ${
                      selectedId === a.id ? "bg-slate-900/80" : ""
                    }`}
                  >
                    <div className="flex items-center justify-between gap-2">
                      <span className="truncate font-medium text-slate-200">{a.summary}</span>
                      <span
                        className={`shrink-0 rounded border px-2 py-0.5 text-[10px] uppercase tracking-wide ${actionTypeColor(a.action_type)}`}
                      >
                        {a.action_type.replace(/_/g, " ")}
                      </span>
                    </div>
                    <div className="mt-1 flex items-center gap-2 text-[10px] text-slate-600">
                      {a.severity && (
                        <span className={`rounded border px-1.5 py-0.5 uppercase ${severityColor(a.severity)}`}>
                          {a.severity}
                        </span>
                      )}
                      <span>by {a.created_by}</span>
                      <span>{timeAgo(a.created_at)}</span>
                    </div>
                  </button>
                ))
              )}
            </div>
          </div>
          <div className="flex w-1/2 flex-col overflow-y-auto p-4">
            {!selected ? (
              <p className="text-sm text-slate-500">Select an action to see details.</p>
            ) : (
              <>
                <h3 className="text-base font-semibold text-slate-200">{selected.summary}</h3>
                <div className="mt-2 flex flex-wrap items-center gap-2 text-xs">
                  <span className={`rounded border px-2 py-0.5 uppercase ${actionTypeColor(selected.action_type)}`}>
                    {selected.action_type.replace(/_/g, " ")}
                  </span>
                  {selected.severity && (
                    <span className={`rounded border px-2 py-0.5 uppercase ${severityColor(selected.severity)}`}>
                      {selected.severity}
                    </span>
                  )}
                  <span className="text-slate-500">by {selected.created_by}</span>
                  <span className="text-slate-600">{timeAgo(selected.created_at)}</span>
                </div>
                {selected.incident_id && (
                  <p className="mt-2 text-xs text-slate-500">Incident: {selected.incident_id}</p>
                )}
                {isSolarDumpAction(selected.action_type) ? (
                  <>
                    <div className="mt-6">
                      <DumpStructuredDetail
                        detail={selected.detail}
                        actionType={selected.action_type}
                      />
                    </div>
                    <h4 className="mb-2 mt-6 text-xs font-semibold uppercase tracking-wide text-slate-500">
                      Raw detail
                    </h4>
                    <pre className="max-h-96 overflow-auto whitespace-pre-wrap rounded border border-slate-800 bg-slate-950 p-3 text-[11px] text-slate-400">
                      {JSON.stringify(selected.detail, null, 2)}
                    </pre>
                  </>
                ) : (
                  <>
                    <h4 className="mb-2 mt-6 text-xs font-semibold uppercase tracking-wide text-slate-500">
                      Detail
                    </h4>
                    <pre className="max-h-96 overflow-auto whitespace-pre-wrap rounded border border-slate-800 bg-slate-950 p-3 text-[11px] text-slate-400">
                      {JSON.stringify(selected.detail, null, 2)}
                    </pre>
                  </>
                )}
              </>
            )}
          </div>
          </div>
        </div>
      )}
    </div>
  );
}
