import { useCallback, useEffect, useState } from "react";
import { useAuth } from "../../contexts/AuthContext";
import { ApiError } from "../../api/client";

/** Cluster health API (admin JWT). Brain-only JSON is GET /api/admin/health on the API host — different route. */
const BASE = "/alfa-ai/api/admin";

async function apiFetch<T>(path: string, token: string, opts?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    ...opts,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...opts?.headers },
  });
  if (!res.ok) {
    const d = await res.json().catch(() => ({ detail: res.statusText }));
    throw new ApiError(d.detail ?? "Request failed", res.status);
  }
  return res.json();
}

interface GpuInfo {
  index: number;
  name: string;
  vram_total_mb: number | null;
  vram_used_mb: number | null;
  vram_free_mb: number | null;
  gpu_util_pct: number | null;
  mem_util_pct: number | null;
  temp_c: number | null;
  power_draw_w: number | null;
  power_limit_w: number | null;
  fan_pct: number | null;
}

interface SystemInfo {
  hostname: string;
  cpu_count: number;
  cpu_used_pct: number | null;
  ram_total_mb: number;
  ram_used_mb: number;
  ram_used_pct: number | null;
  disk_total_gb: number;
  disk_used_gb: number;
  disk_used_pct: number;
  load_avg?: number[];
}

interface WorkerStats {
  worker_name: string;
  worker_role: string;
  nvidia_driver: string | null;
  gpus: GpuInfo[];
  system: SystemInfo;
  timestamp_iso: string;
}

interface WorkerData {
  id: string;
  name: string;
  ip_address: string;
  monitor_port: number;
  role: string;
  reachable: boolean;
  stats: WorkerStats | null;
  logs: string[] | null;
  logs_error?: string | null;
  error: string | null;
  hint?: string | null;
  attempted_urls?: { stats: string; logs: string };
  heartbeat?: { received_at?: string; worker_name?: string; role?: string } | null;
}

interface Alert {
  level: "error" | "warning";
  worker: string;
  message: string;
}

interface OperationalWarning {
  id: string;
  level: "error" | "warning";
  title: string;
  message: string;
  hint?: string;
}

interface PoolStats {
  ts?: number;
  active_pool?: string | null;
  inference_mode?: string;
  litellm_config?: string;
  configured_ctx_size?: number | null;
  coordinator?: {
    url?: string;
    reachable?: boolean;
    loading?: boolean;
    detail?: string;
    context_window?: number;
    context_train?: number;
    total_slots?: number;
    model_id?: string;
    model_path?: string;
    param_count?: number;
    is_sleeping?: boolean;
    health_latency_ms?: number;
    error?: string;
  };
  shards?: {
    pool?: string;
    ok?: boolean;
    count?: number;
    online?: number;
    shards?: { host: string; port: number; ok: boolean }[];
  };
  last_probe?: {
    source?: string;
    model?: string;
    pool?: string;
    completion_tokens?: number;
    elapsed_sec?: number;
    tok_per_sec?: number;
    decode_tok_per_sec?: number;
    wall_tok_per_sec?: number;
    ttft_sec?: number;
    ts?: number;
  } | null;
}

interface HealthData {
  brain?: {
    services: ServiceCheck[];
    ts?: number;
  };
  inference?: InferenceReport;
  pool_stats?: PoolStats;
  hosts?: HostReport[];
  summary: {
    total_workers: number;
    online: number;
    offline: number;
    total_gpus: number;
    heartbeat_only?: number;
  };
  workers: WorkerData[];
  alerts: Alert[];
  operational_warnings?: OperationalWarning[];
}

interface ServiceCheck {
  name: string;
  ok: boolean;
  url?: string;
  status_code?: number;
  error?: string;
  loading?: boolean;
  detail?: string;
  models?: string[];
  latency_ms?: number;
  engine?: string;
  aliases?: string[];
}

interface InferenceSummary {
  total: number;
  online: number;
  offline: number;
}

interface InferenceReport {
  endpoints: ServiceCheck[];
  summary: InferenceSummary;
  ts?: number;
}

interface HostCheck {
  name: string;
  ok: boolean;
  url?: string;
  status_code?: number;
  error?: string;
  latency_ms?: number;
  note?: string;
  skipped?: boolean;
  derived?: boolean;
}

interface HostReport {
  key?: string;
  name?: string;
  lan_ip?: string;
  role?: string;
  reachable?: boolean;
  checks: HostCheck[];
}

interface RegisteredWorker {
  id: string;
  name: string;
  ip_address: string;
  monitor_port: number;
  role: string;
  status: string;
  last_seen: string | null;
  hardware_summary: string | null;
}

function Gauge({ value, max, label, color, unit }: { value: number | null; max?: number; label: string; color: string; unit?: string }) {
  const pct = value != null && max ? Math.min((value / max) * 100, 100) : (value ?? 0);
  const displayVal = value != null ? (max ? `${Math.round(value)}/${Math.round(max)}` : `${Math.round(value)}%`) : "—";
  return (
    <div className="flex flex-col gap-1">
      <div className="flex justify-between text-xs">
        <span className="text-slate-400">{label}</span>
        <span className="text-slate-300">{displayVal}{unit && ` ${unit}`}</span>
      </div>
      <div className="h-2 rounded-full bg-slate-700">
        <div
          className={`h-full rounded-full transition-all ${color}`}
          style={{ width: `${Math.min(pct, 100)}%` }}
        />
      </div>
    </div>
  );
}

function ServiceChip({ svc }: { svc: ServiceCheck }) {
  const loading = svc.loading;
  const ok = svc.ok;
  const dot = ok ? "bg-green-400" : loading ? "bg-amber-400 animate-pulse" : "bg-red-500";
  const label = loading ? "loading" : ok ? "ok" : "down";
  return (
    <div className="rounded-lg border border-slate-800 bg-slate-900 p-3 space-y-1">
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <span className={`h-2 w-2 rounded-full ${dot}`} />
          <span className="text-sm font-medium text-slate-200">{svc.name}</span>
          {svc.engine && (
            <span className="rounded bg-slate-800 px-1 py-0.5 text-[10px] uppercase text-slate-500">{svc.engine}</span>
          )}
        </div>
        <div className="flex items-center gap-2 text-xs text-slate-500">
          {svc.latency_ms != null && ok && (
            <span className="tabular-nums text-sky-400/90">{svc.latency_ms} ms</span>
          )}
          <span className="uppercase tracking-wide">{label}</span>
        </div>
      </div>
      {svc.aliases && svc.aliases.length > 0 && (
        <div className="text-xs text-violet-400/90">LiteLLM: {svc.aliases.join(", ")}</div>
      )}
      {svc.models && svc.models.length > 0 && (
        <div className="text-xs text-sky-400/90">models: {svc.models.join(", ")}</div>
      )}
      {loading && svc.detail && (
        <div className="text-xs text-amber-300/90">{svc.detail}</div>
      )}
      {!ok && !loading && svc.error && (
        <div className="text-xs text-red-400/90 break-all">{svc.error}</div>
      )}
      {svc.url && (
        <div className="font-mono text-[10px] text-slate-600 truncate" title={svc.url}>{svc.url}</div>
      )}
    </div>
  );
}

function formatTs(ts?: number): string {
  if (!ts) return "—";
  return new Date(ts * 1000).toLocaleString();
}

function formatParamCount(n?: number): string {
  if (n == null) return "—";
  if (n >= 1e9) return `${(n / 1e9).toFixed(1)}B`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(0)}M`;
  return String(n);
}

function PoolStatsPanel({ stats }: { stats: PoolStats }) {
  const coord = stats.coordinator;
  const shards = stats.shards;
  const probe = stats.last_probe;
  const ctxRuntime = coord?.context_window ?? stats.configured_ctx_size;
  const ctxTrain = coord?.context_train;

  return (
    <div className="rounded-xl border border-violet-900/40 bg-violet-950/10 p-4 space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-sm font-medium text-slate-200">Inference performance</h3>
        {stats.active_pool && (
          <span className="rounded bg-violet-900/50 px-2 py-0.5 text-xs font-medium uppercase tracking-wide text-violet-300">
            {stats.active_pool}
          </span>
        )}
      </div>
      <p className="text-xs text-slate-500">
        Pool config and GPU shard count for benchmarking. **Decode tok/s** (response speed) updates after keep-warm or{" "}
        <code className="text-slate-400">scripts/benchmark-inference-litellm.sh</code> (streaming; excludes prefill).
      </p>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
        <div className="rounded-lg border border-slate-800 bg-slate-900 p-3 text-center">
          <div className="text-xl font-bold tabular-nums text-sky-400">
            {ctxRuntime != null ? ctxRuntime.toLocaleString() : "—"}
          </div>
          <div className="text-xs text-slate-500">Context window (runtime)</div>
        </div>
        <div className="rounded-lg border border-slate-800 bg-slate-900 p-3 text-center">
          <div className="text-xl font-bold tabular-nums text-slate-300">
            {ctxTrain != null ? ctxTrain.toLocaleString() : "—"}
          </div>
          <div className="text-xs text-slate-500">Model train ctx</div>
        </div>
        <div className="rounded-lg border border-slate-800 bg-slate-900 p-3 text-center">
          <div className={`text-xl font-bold tabular-nums ${(shards?.online ?? 0) === (shards?.count ?? 0) && (shards?.count ?? 0) > 0 ? "text-green-400" : "text-amber-400"}`}>
            {shards?.online ?? 0}/{shards?.count ?? 0}
          </div>
          <div className="text-xs text-slate-500">GPU shards online</div>
        </div>
        <div className="rounded-lg border border-slate-800 bg-slate-900 p-3 text-center">
          <div className="text-xl font-bold tabular-nums text-slate-300">
            {coord?.total_slots ?? "—"}
          </div>
          <div className="text-xs text-slate-500">Parallel slots</div>
        </div>
        <div className="rounded-lg border border-slate-800 bg-slate-900 p-3 text-center">
          <div className={`text-xl font-bold tabular-nums ${probe?.tok_per_sec && probe.tok_per_sec > 1 ? "text-green-400" : probe ? "text-amber-400" : "text-slate-600"}`}>
            {probe?.tok_per_sec != null ? probe.tok_per_sec.toFixed(1) : "—"}
          </div>
          <div className="text-xs text-slate-500">Decode tok/s (last probe)</div>
        </div>
        <div className="rounded-lg border border-slate-800 bg-slate-900 p-3 text-center">
          <div className={`text-xl font-bold ${coord?.reachable ? "text-green-400" : coord?.loading ? "text-amber-400" : "text-red-400"}`}>
            {coord?.reachable ? "OK" : coord?.loading ? "LOAD" : "DOWN"}
          </div>
          <div className="text-xs text-slate-500">Coordinator</div>
        </div>
      </div>

      <div className="grid gap-3 lg:grid-cols-2">
        <div className="space-y-1 text-xs text-slate-400">
          <div><span className="text-slate-500">LiteLLM config:</span> {stats.litellm_config ?? "—"}</div>
          <div><span className="text-slate-500">Inference mode:</span> {stats.inference_mode ?? "—"}</div>
          {coord?.model_id && (
            <div><span className="text-slate-500">Model:</span> <span className="font-mono text-sky-400/90">{coord.model_id}</span></div>
          )}
          {coord?.param_count != null && (
            <div><span className="text-slate-500">Parameters:</span> {formatParamCount(coord.param_count)}</div>
          )}
          {coord?.url && (
            <div className="truncate font-mono text-[10px] text-slate-600" title={coord.url}>{coord.url}</div>
          )}
          {coord?.error && !coord.reachable && (
            <div className="text-red-400/90 break-all">{coord.error}</div>
          )}
        </div>
        <div className="space-y-1 text-xs text-slate-400">
          {probe ? (
            <>
              <div>
                <span className="text-slate-500">Last probe:</span>{" "}
                {(probe.decode_tok_per_sec ?? probe.tok_per_sec)?.toFixed(2)} decode tok/s
                {probe.wall_tok_per_sec != null && probe.wall_tok_per_sec !== probe.decode_tok_per_sec
                  ? ` (wall ${probe.wall_tok_per_sec.toFixed(2)})`
                  : ""}{" "}
                ({probe.completion_tokens} tok in {probe.elapsed_sec}s
                {probe.ttft_sec != null ? `, ttft ${probe.ttft_sec}s` : ""})
              </div>
              <div><span className="text-slate-500">Source:</span> {probe.source} · model {probe.model}</div>
              <div><span className="text-slate-500">When:</span> {formatTs(probe.ts)}</div>
            </>
          ) : (
            <div className="text-slate-500">No throughput probe yet. Run keep-warm cron or benchmark script.</div>
          )}
          {probe && probe.tok_per_sec != null && probe.tok_per_sec <= 1 && (
            <div className="text-amber-300/90">
              Low tok/s often means cold load or missing GPU shards — verify all shards show OK below.
            </div>
          )}
        </div>
      </div>

      {shards?.shards && shards.shards.length > 0 && (
        <div>
          <div className="mb-2 text-xs font-medium text-slate-500">RPC GPU shards ({stats.active_pool ?? shards.pool})</div>
          <div className="flex flex-wrap gap-2">
            {shards.shards.map((s) => (
              <span
                key={`${s.host}:${s.port}`}
                className={`rounded border px-2 py-1 font-mono text-xs ${
                  s.ok ? "border-green-800/50 bg-green-950/30 text-green-300" : "border-red-800/50 bg-red-950/30 text-red-300"
                }`}
              >
                {s.host}:{s.port} {s.ok ? "OK" : "DOWN"}
              </span>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

function HostCard({ host }: { host: HostReport }) {
  const okCount = host.checks.filter((c) => c.ok).length;
  return (
    <div className={`rounded-xl border p-4 space-y-2 ${
      host.reachable ? "border-slate-700 bg-slate-900" : "border-red-800/40 bg-red-950/15"
    }`}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <span className="font-medium text-slate-200">{host.name}</span>
          {host.lan_ip && (
            <span className="ml-2 font-mono text-xs text-slate-500">{host.lan_ip}</span>
          )}
        </div>
        <span className="text-xs text-slate-500">{okCount}/{host.checks.length} checks ok</span>
      </div>
      {host.role && <p className="text-xs text-slate-500">{host.role}</p>}
      <div className="grid gap-1 sm:grid-cols-2">
        {host.checks.map((c) => (
          <div key={c.name} className="flex items-start gap-2 text-xs">
            <span className={`mt-1 h-1.5 w-1.5 shrink-0 rounded-full ${
              c.ok ? "bg-green-400" : c.skipped ? "bg-amber-500" : "bg-red-500"
            }`} />
            <div className="min-w-0">
              <span className="text-slate-300">{c.name}</span>
              {c.ok && c.latency_ms != null && (
                <span className="ml-2 tabular-nums text-sky-500/80">{c.latency_ms} ms</span>
              )}
              {!c.ok && c.error && (
                <div className="text-red-400/80 break-all">{c.error}</div>
              )}
              {c.note && (
                <div className={c.ok ? "text-slate-500" : "text-amber-400/80"}>{c.note}</div>
              )}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function GpuCard({ gpu }: { gpu: GpuInfo }) {
  const tempColor = (gpu.temp_c ?? 0) > 80 ? "bg-red-500" : (gpu.temp_c ?? 0) > 65 ? "bg-amber-500" : "bg-green-500";
  return (
    <div className="rounded-lg border border-slate-700 bg-slate-800/50 p-3 space-y-2">
      <div className="flex items-center justify-between">
        <span className="text-sm font-medium text-slate-200">{gpu.name}</span>
        <span className="text-xs text-slate-500">GPU {gpu.index}</span>
      </div>
      <Gauge value={gpu.vram_used_mb} max={gpu.vram_total_mb ?? undefined} label="VRAM" color="bg-sky-500" unit="MB" />
      <Gauge value={gpu.gpu_util_pct} label="GPU Load" color="bg-emerald-500" />
      <div className="flex gap-4 text-xs text-slate-400">
        <span className="flex items-center gap-1">
          <span className={`inline-block h-2 w-2 rounded-full ${tempColor}`} />
          {gpu.temp_c != null ? `${gpu.temp_c}°C` : "—"}
        </span>
        {gpu.power_draw_w != null && (
          <span>{gpu.power_draw_w}W / {gpu.power_limit_w ?? "?"}W</span>
        )}
        {gpu.fan_pct != null && <span>Fan {gpu.fan_pct}%</span>}
      </div>
    </div>
  );
}

function WorkerCard({ worker, onShowLogs }: { worker: WorkerData; onShowLogs: (w: WorkerData) => void }) {
  const online = worker.reachable;
  const hb = worker.heartbeat;
  const hbOnly = !online && !!hb;
  const statusDot =
    online ? "bg-green-400" : hbOnly ? "bg-amber-400" : "bg-red-500";

  return (
    <div className={`rounded-xl border p-4 space-y-3 ${
      online ? "border-slate-700 bg-slate-900" : hbOnly ? "border-amber-800/50 bg-amber-950/15" : "border-red-800/50 bg-red-950/20"
    }`}>
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <span className={`h-2.5 w-2.5 rounded-full ${statusDot}`} />
          <span className="font-medium text-slate-200">{worker.name}</span>
          <span className="rounded bg-slate-800 px-1.5 py-0.5 text-xs text-slate-500">{worker.role}</span>
        </div>
        <div className="flex items-center gap-2">
          <span className="font-mono text-xs text-slate-500">{worker.ip_address}:{worker.monitor_port}</span>
          <button
            onClick={() => onShowLogs(worker)}
            className="rounded border border-slate-700 px-2 py-0.5 text-xs text-slate-400 hover:text-slate-200"
          >
            Logs
          </button>
        </div>
      </div>

      {hbOnly && (
        <div className="rounded border border-amber-800/40 bg-amber-950/30 px-3 py-2 text-xs text-amber-200/90">
          <span className="font-medium">Heartbeat OK</span>
          {hb?.received_at && (
            <span className="ml-2 font-mono text-amber-100/80">{hb.received_at}</span>
          )}
          <p className="mt-1 text-amber-200/70">
            Worker is signaling the brain, but worker-monitor is not reachable from the API host — check LAN/firewall to{" "}
            {worker.ip_address}:{worker.monitor_port}.
          </p>
        </div>
      )}

      {!online && !hbOnly && (
        <div className="space-y-2 rounded border border-red-800/40 bg-red-950/40 px-3 py-3 text-sm">
          <div className="font-medium text-red-300">Unreachable from API</div>
          {worker.error && (
            <pre className="whitespace-pre-wrap break-all font-mono text-xs text-red-200/90">{worker.error}</pre>
          )}
          {worker.hint && (
            <p className="text-xs leading-relaxed text-amber-200/90">{worker.hint}</p>
          )}
          {worker.attempted_urls && (
            <div className="space-y-1 font-mono text-[11px] text-slate-500">
              <div>GET {worker.attempted_urls.stats}</div>
              <div>GET {worker.attempted_urls.logs}</div>
            </div>
          )}
          <p className="text-xs text-slate-500">
            Remote worker logs appear in the Logs dialog only after the worker-monitor agent responds.
          </p>
        </div>
      )}

      {online && worker.stats && (
        <>
          {/* System row */}
          <div className="grid grid-cols-3 gap-3">
            <Gauge value={worker.stats.system.cpu_used_pct} label="CPU" color="bg-violet-500" />
            <Gauge value={worker.stats.system.ram_used_mb} max={worker.stats.system.ram_total_mb} label="RAM" color="bg-blue-500" unit="MB" />
            <Gauge value={worker.stats.system.disk_used_pct} label="Disk" color="bg-slate-500" />
          </div>

          {/* GPUs */}
          {worker.stats.gpus.length > 0 && (
            <div className="grid gap-2" style={{ gridTemplateColumns: `repeat(${Math.min(worker.stats.gpus.length, 3)}, 1fr)` }}>
              {worker.stats.gpus.map((gpu) => (
                <GpuCard key={gpu.index} gpu={gpu} />
              ))}
            </div>
          )}

          {/* Footer */}
          <div className="flex gap-4 text-xs text-slate-500">
            {worker.stats.nvidia_driver && <span>Driver: {worker.stats.nvidia_driver}</span>}
            {worker.stats.system.load_avg && <span>Load: {worker.stats.system.load_avg.join(" ")}</span>}
          </div>
        </>
      )}
    </div>
  );
}

export default function HealthPage() {
  const { token } = useAuth();
  const [health, setHealth] = useState<HealthData | null>(null);
  const [workers, setWorkers] = useState<RegisteredWorker[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [logWorker, setLogWorker] = useState<WorkerData | null>(null);

  // Add worker form
  const [addName, setAddName] = useState("");
  const [addIp, setAddIp] = useState("");
  const [addPort, setAddPort] = useState("31331");
  const [addRole, setAddRole] = useState("gpu-worker");

  const loadWorkers = useCallback(async () => {
    if (!token) return;
    try {
      const data = await apiFetch<{ workers: RegisteredWorker[] }>("/workers", token);
      setWorkers(data.workers);
    } catch { /* ignore */ }
  }, [token]);

  const pollHealth = useCallback(async () => {
    if (!token) return;
    setLoading(true);
    setError("");
    try {
      const data = await apiFetch<HealthData>("/health", token);
      setHealth(data);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to poll cluster");
    } finally {
      setLoading(false);
    }
  }, [token]);

  useEffect(() => { loadWorkers(); }, [loadWorkers]);
  useEffect(() => { pollHealth(); }, [pollHealth]);

  // Auto-refresh every 15s
  useEffect(() => {
    const interval = setInterval(pollHealth, 15000);
    return () => clearInterval(interval);
  }, [pollHealth]);

  async function addWorker() {
    if (!token || !addName.trim() || !addIp.trim()) return;
    try {
      await apiFetch("/workers", token, {
        method: "POST",
        body: JSON.stringify({ name: addName.trim(), ip_address: addIp.trim(), monitor_port: parseInt(addPort) || 31331, role: addRole }),
      });
      setAddName(""); setAddIp("");
      loadWorkers();
      pollHealth();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to add worker");
    }
  }

  async function removeWorker(id: string) {
    if (!token) return;
    try {
      await apiFetch(`/workers/${id}`, token, { method: "DELETE" });
      loadWorkers();
      pollHealth();
    } catch { /* ignore */ }
  }

  return (
    <div className="h-full overflow-y-auto p-6 space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-semibold text-slate-200">Cluster Health</h2>
        <button
          onClick={pollHealth}
          disabled={loading}
          className="rounded border border-slate-700 px-3 py-1 text-xs text-slate-400 hover:text-slate-200 disabled:opacity-50"
        >
          {loading ? "Polling…" : "Refresh"}
        </button>
      </div>

      {error && (
        <div className="rounded-lg border border-red-800/50 bg-red-950/30 px-4 py-2 text-sm text-red-400">{error}</div>
      )}

      <div className="rounded-xl border border-slate-800 bg-slate-950/40 p-4 text-xs leading-relaxed text-slate-400">
        <p className="mb-2 font-medium text-slate-300">What this page checks</p>
        <p className="mb-2">
          Probes run <strong className="text-slate-400">from the brain API container</strong> (outbound) against
          LiteLLM, the llama.cpp coordinator, Ollama fleet hosts, and RPC shards. Latency is HTTP round-trip to each
          endpoint&apos;s health/tags path — not tokens/sec.
        </p>
        <p>
          Optional worker-monitor cards below are for gaming hosts with Dockge agents. Register workers only when
          worker-monitor is running on those hosts. Heartbeats merge when the worker name matches the registry.
        </p>
      </div>

      {health?.pool_stats && (
        <PoolStatsPanel stats={health.pool_stats} />
      )}

      {/* Inference stack (Phase G cpp / Ollama pool) */}
      {health?.inference && (
        <div className="space-y-2">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h3 className="text-sm font-medium text-slate-300">Inference stack (llama.cpp / Ollama / LiteLLM)</h3>
            <span className="text-xs text-slate-500">
              {health.inference.summary.online}/{health.inference.summary.total} online
            </span>
          </div>
          <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
            {health.inference.endpoints.map((svc) => (
              <ServiceChip key={svc.name} svc={svc} />
            ))}
          </div>
        </div>
      )}

      {/* Summary cards */}
      {health && (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
          <div className="rounded-lg border border-slate-800 bg-slate-900 p-3 text-center">
            <div className="text-2xl font-bold text-slate-200">{health.summary.total_workers}</div>
            <div className="text-xs text-slate-500">Workers</div>
          </div>
          <div className="rounded-lg border border-slate-800 bg-slate-900 p-3 text-center">
            <div className="text-2xl font-bold text-green-400">{health.summary.online}</div>
            <div className="text-xs text-slate-500">Online</div>
          </div>
          <div className="rounded-lg border border-slate-800 bg-slate-900 p-3 text-center">
            <div className={`text-2xl font-bold ${health.summary.offline > 0 ? "text-red-400" : "text-slate-600"}`}>{health.summary.offline}</div>
            <div className="text-xs text-slate-500">Offline (monitor)</div>
          </div>
          <div className="rounded-lg border border-slate-800 bg-slate-900 p-3 text-center">
            <div className={`text-2xl font-bold ${(health.summary.heartbeat_only ?? 0) > 0 ? "text-amber-400" : "text-slate-600"}`}>
              {health.summary.heartbeat_only ?? 0}
            </div>
            <div className="text-xs text-slate-500">Heartbeat only</div>
          </div>
          <div className="rounded-lg border border-slate-800 bg-slate-900 p-3 text-center">
            <div className="text-2xl font-bold text-sky-400">{health.summary.total_gpus}</div>
            <div className="text-xs text-slate-500">GPUs</div>
          </div>
        </div>
      )}

      {health?.brain?.services && health.brain.services.length > 0 && (
        <div className="space-y-2">
          <h3 className="text-sm font-medium text-slate-300">Brain dependencies (Postgres, Redis, …)</h3>
          <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
            {health.brain.services.map((svc) => (
              <ServiceChip key={svc.name} svc={svc} />
            ))}
          </div>
        </div>
      )}

      {health?.hosts && health.hosts.length > 0 && (
        <div className="space-y-2">
          <h3 className="text-sm font-medium text-slate-300">Infrastructure hosts</h3>
          {health.hosts.map((host) => (
            <HostCard key={host.key || host.name} host={host} />
          ))}
        </div>
      )}

      {/* Operational warnings (JWT secret, Prometheus scrape) */}
      {health && (health.operational_warnings?.length ?? 0) > 0 && (
        <div className="space-y-1">
          <h3 className="text-sm font-medium text-red-400">
            Operational ({health.operational_warnings!.length})
          </h3>
          {health.operational_warnings!.map((w) => (
            <div
              key={w.id}
              className={`rounded px-3 py-2 text-sm ${
                w.level === "error"
                  ? "border border-red-800/50 bg-red-950/30 text-red-300"
                  : "border border-amber-800/50 bg-amber-950/30 text-amber-300"
              }`}
            >
              <p className="font-medium">{w.title}</p>
              <p className="mt-0.5">{w.message}</p>
              {w.hint && <p className="mt-1 text-xs text-slate-400">{w.hint}</p>}
            </div>
          ))}
        </div>
      )}

      {/* Alerts */}
      {health && health.alerts.length > 0 && (
        <div className="space-y-1">
          <h3 className="text-sm font-medium text-red-400">Alerts ({health.alerts.length})</h3>
          {health.alerts.map((a, i) => (
            <div key={i} className={`rounded px-3 py-1.5 text-sm ${
              a.level === "error" ? "border border-red-800/50 bg-red-950/30 text-red-400" : "border border-amber-800/50 bg-amber-950/30 text-amber-400"
            }`}>
              <span className="font-medium">{a.worker}:</span> {a.message}
            </div>
          ))}
        </div>
      )}

      {/* Worker cards */}
      {health && health.workers.length > 0 && (
        <div className="space-y-3">
          <h3 className="text-sm font-medium text-slate-300">Workers</h3>
          {health.workers.map((w) => (
            <WorkerCard key={w.id} worker={w} onShowLogs={setLogWorker} />
          ))}
        </div>
      )}

      {/* Add worker */}
      <div className="rounded-xl border border-slate-800 bg-slate-900 p-4">
        <h3 className="mb-3 text-sm font-medium text-slate-300">Register Worker</h3>
        <div className="flex flex-wrap gap-2">
          <input
            value={addName}
            onChange={(e) => setAddName(e.target.value)}
            placeholder="Name (e.g. hub)"
            className="rounded border border-slate-700 bg-slate-800 px-2 py-1 text-sm text-slate-200 placeholder-slate-500"
          />
          <input
            value={addIp}
            onChange={(e) => setAddIp(e.target.value)}
            placeholder="IP (e.g. orchestrator)"
            className="rounded border border-slate-700 bg-slate-800 px-2 py-1 text-sm text-slate-200 placeholder-slate-500"
          />
          <input
            value={addPort}
            onChange={(e) => setAddPort(e.target.value)}
            placeholder="Port"
            className="w-20 rounded border border-slate-700 bg-slate-800 px-2 py-1 text-sm text-slate-200"
          />
          <select
            value={addRole}
            onChange={(e) => setAddRole(e.target.value)}
            className="rounded border border-slate-700 bg-slate-800 px-2 py-1 text-sm text-slate-200"
          >
            <option value="gpu-worker">GPU Worker</option>
            <option value="cpu-worker">CPU Worker</option>
            <option value="gateway">Gateway</option>
          </select>
          <button
            onClick={addWorker}
            className="rounded bg-sky-600 px-3 py-1 text-sm text-white hover:bg-sky-500"
          >
            Add
          </button>
        </div>

        {/* Registered workers list */}
        {workers.length > 0 && (
          <div className="mt-3 space-y-1">
            {workers.map((w) => (
              <div key={w.id} className="flex items-center gap-3 text-xs text-slate-400">
                <span className={`h-1.5 w-1.5 rounded-full ${w.status === "online" ? "bg-green-400" : w.status === "offline" ? "bg-red-500" : "bg-slate-600"}`} />
                <span className="text-slate-300">{w.name}</span>
                <span className="font-mono">{w.ip_address}:{w.monitor_port}</span>
                <span>{w.role}</span>
                {w.hardware_summary && <span className="text-slate-500">{w.hardware_summary}</span>}
                <button onClick={() => removeWorker(w.id)} className="text-red-500 hover:text-red-300">remove</button>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Log modal */}
      {logWorker && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60" onClick={() => setLogWorker(null)}>
          <div className="max-h-[80vh] w-full max-w-3xl overflow-hidden rounded-xl border border-slate-700 bg-slate-900" onClick={(e) => e.stopPropagation()}>
            <div className="flex items-center justify-between border-b border-slate-800 px-4 py-3">
              <span className="font-medium text-slate-200">{logWorker.name} — Logs</span>
              <button onClick={() => setLogWorker(null)} className="text-slate-400 hover:text-slate-200">Close</button>
            </div>
            <div className="max-h-[70vh] space-y-3 overflow-y-auto p-4">
              {!logWorker.reachable && (
                <div className="space-y-2 rounded border border-amber-800/40 bg-amber-950/20 px-3 py-2 text-sm text-amber-200/90">
                  <div className="font-medium">Worker monitor not reachable</div>
                  {logWorker.error && (
                    <pre className="whitespace-pre-wrap break-all font-mono text-xs text-amber-100/80">{logWorker.error}</pre>
                  )}
                  {logWorker.hint && <p className="text-xs leading-relaxed">{logWorker.hint}</p>}
                  {logWorker.logs_error && (
                    <p className="font-mono text-xs text-slate-400">Logs fetch: {logWorker.logs_error}</p>
                  )}
                  <p className="text-xs text-slate-500">
                    The UI cannot show container logs until <code className="text-slate-400">http://{logWorker.ip_address}:{logWorker.monitor_port}/logs</code>{" "}
                    responds (worker-monitor sidecar with Docker socket). On the worker host, run:{" "}
                    <code className="text-slate-400">docker logs worker-monitor --tail 80</code>
                  </p>
                </div>
              )}
              {logWorker.reachable && logWorker.logs_error && (
                <p className="text-sm text-amber-400/90">Could not fetch logs: {logWorker.logs_error}</p>
              )}
              {logWorker.logs && logWorker.logs.length > 0 ? (
                <pre className="whitespace-pre-wrap font-mono text-xs text-slate-400">
                  {logWorker.logs.join("\n")}
                </pre>
              ) : logWorker.reachable ? (
                <p className="text-sm text-slate-500">No log lines returned (empty docker logs or worker-monitor missing).</p>
              ) : null}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
