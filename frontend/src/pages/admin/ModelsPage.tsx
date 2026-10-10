import { useCallback, useEffect, useState } from "react";
import { useAuth } from "../../contexts/AuthContext";
import { ApiError } from "../../api/client";

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

interface ModelInfo {
  name: string;
  type: string;
  path: string;
  size_bytes: number;
  size_gb: number;
  file_count: number;
}

interface DiskInfo {
  total_gb: number;
  free_gb: number;
  used_gb: number;
}

interface ModelsData {
  models: ModelInfo[];
  inference?: {
    endpoints: InferenceEndpoint[];
    summary: { total: number; online: number; offline: number };
  };
  models_dir: string;
  models_dir_exists: boolean;
  total_models_gb: number;
  disk: DiskInfo;
}

interface InferenceEndpoint {
  name: string;
  ok: boolean;
  engine?: string;
  latency_ms?: number;
  models?: string[];
  aliases?: string[];
  url?: string;
  error?: string;
  loading?: boolean;
  detail?: string;
}

interface DownloadItem {
  gid: string;
  status: string;
  filename: string;
  total_mb: number;
  completed_mb: number;
  progress_pct: number;
  speed_mbps: number;
}

interface DownloadsData {
  aria2_reachable: boolean;
  error?: string;
  active: DownloadItem[];
  waiting: DownloadItem[];
}

function ProgressBar({ pct, speed }: { pct: number; speed?: number }) {
  return (
    <div className="flex items-center gap-2">
      <div className="h-2 flex-1 rounded-full bg-slate-700">
        <div
          className="h-full rounded-full bg-sky-500 transition-all"
          style={{ width: `${Math.min(pct, 100)}%` }}
        />
      </div>
      <span className="text-xs text-slate-400 tabular-nums">{pct.toFixed(1)}%</span>
      {speed != null && speed > 0 && (
        <span className="text-xs text-slate-500">{speed.toFixed(1)} MB/s</span>
      )}
    </div>
  );
}

export default function ModelsPage() {
  const { token } = useAuth();
  const [models, setModels] = useState<ModelsData | null>(null);
  const [downloads, setDownloads] = useState<DownloadsData | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [downloadModel, setDownloadModel] = useState("");
  const [downloadMsg, setDownloadMsg] = useState("");

  const loadModels = useCallback(async () => {
    if (!token) return;
    setLoading(true);
    setError("");
    try {
      const data = await apiFetch<ModelsData>("/models", token);
      setModels(data);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to load models");
    } finally {
      setLoading(false);
    }
  }, [token]);

  const loadDownloads = useCallback(async () => {
    if (!token) return;
    try {
      const data = await apiFetch<DownloadsData>("/models/downloads/status", token);
      setDownloads(data);
    } catch {
      setDownloads({ aria2_reachable: false, error: "Cannot reach API", active: [], waiting: [] });
    }
  }, [token]);

  useEffect(() => { loadModels(); }, [loadModels]);
  useEffect(() => { loadDownloads(); }, [loadDownloads]);

  useEffect(() => {
    const interval = setInterval(() => {
      loadModels();
      loadDownloads();
    }, 10000);
    return () => clearInterval(interval);
  }, [loadModels, loadDownloads]);

  async function triggerDownload() {
    if (!token || !downloadModel.trim()) return;
    setDownloadMsg("");
    try {
      const data = await apiFetch<{ message: string }>("/models/download", token, {
        method: "POST",
        body: JSON.stringify({ hf_model_id: downloadModel.trim() }),
      });
      setDownloadMsg(data.message);
      setDownloadModel("");
      loadDownloads();
    } catch (err) {
      setDownloadMsg(err instanceof ApiError ? err.message : "Download trigger failed");
    }
  }

  async function deleteModel(name: string, type: string) {
    if (!token || !confirm(`Delete model ${name}?`)) return;
    try {
      await apiFetch(`/models/${encodeURIComponent(name)}?model_type=${type}`, token, { method: "DELETE" });
      loadModels();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Delete failed");
    }
  }

  return (
    <div className="h-full overflow-y-auto p-6 space-y-6">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-semibold text-slate-200">Model Management</h2>
        <button
          onClick={() => { loadModels(); loadDownloads(); }}
          disabled={loading}
          className="rounded border border-slate-700 px-3 py-1 text-xs text-slate-400 hover:text-slate-200 disabled:opacity-50"
        >
          {loading ? "Loading..." : "Refresh"}
        </button>
      </div>

      {error && (
        <div className="rounded-lg border border-red-800/50 bg-red-950/30 px-4 py-2 text-sm text-red-400">{error}</div>
      )}

      {/* Storage summary */}
      {models && (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <div className="rounded-lg border border-slate-800 bg-slate-900 p-3 text-center">
            <div className="text-2xl font-bold text-slate-200">{models.models.length}</div>
            <div className="text-xs text-slate-500">Models</div>
          </div>
          <div className="rounded-lg border border-slate-800 bg-slate-900 p-3 text-center">
            <div className="text-2xl font-bold text-sky-400">{models.total_models_gb} GB</div>
            <div className="text-xs text-slate-500">Total Size</div>
          </div>
          {models.disk.free_gb != null && (
            <div className="rounded-lg border border-slate-800 bg-slate-900 p-3 text-center">
              <div className="text-2xl font-bold text-green-400">{models.disk.free_gb} GB</div>
              <div className="text-xs text-slate-500">Free Disk</div>
            </div>
          )}
          <div className="rounded-lg border border-slate-800 bg-slate-900 p-3 text-center">
            <div className={`text-2xl font-bold ${models.models_dir_exists ? "text-green-400" : "text-amber-400"}`}>
              {models.models_dir_exists ? "OK" : "N/A"}
            </div>
            <div className="text-xs text-slate-500">Hub mount</div>
          </div>
          {models.inference && (
            <div className="rounded-lg border border-slate-800 bg-slate-900 p-3 text-center">
              <div className={`text-2xl font-bold ${models.inference.summary.online > 0 ? "text-green-400" : "text-red-400"}`}>
                {models.inference.summary.online}/{models.inference.summary.total}
              </div>
              <div className="text-xs text-slate-500">Live endpoints</div>
            </div>
          )}
        </div>
      )}

      {/* Live inference routes (cpp beta) */}
      {models?.inference && models.inference.endpoints.length > 0 && (
        <div className="rounded-xl border border-slate-800 bg-slate-900 p-4 space-y-3">
          <h3 className="text-sm font-medium text-slate-300">Live inference routes</h3>
          <div className="space-y-2">
            {models.inference.endpoints.map((ep) => (
              <div
                key={ep.name}
                className={`flex flex-wrap items-start justify-between gap-2 rounded-lg border px-4 py-3 ${
                  ep.ok ? "border-slate-700 bg-slate-800/50" : "border-red-800/40 bg-red-950/15"
                }`}
              >
                <div className="space-y-1">
                  <div className="flex items-center gap-2">
                    <span className={`h-2 w-2 rounded-full ${ep.ok ? "bg-green-400" : ep.loading ? "bg-amber-400" : "bg-red-500"}`} />
                    <span className="font-medium text-slate-200">{ep.name}</span>
                    {ep.engine && (
                      <span className="rounded bg-slate-700 px-1.5 py-0.5 text-xs text-slate-400">{ep.engine}</span>
                    )}
                  </div>
                  {ep.aliases && ep.aliases.length > 0 && (
                    <div className="text-xs text-violet-400/90">aliases: {ep.aliases.join(", ")}</div>
                  )}
                  {ep.models && ep.models.length > 0 && (
                    <div className="text-xs text-sky-400/90">{ep.models.join(", ")}</div>
                  )}
                  {!ep.ok && ep.error && (
                    <div className="text-xs text-red-400/90 break-all">{ep.error}</div>
                  )}
                  {ep.loading && ep.detail && (
                    <div className="text-xs text-amber-300/90">{ep.detail}</div>
                  )}
                </div>
                {ep.ok && ep.latency_ms != null && (
                  <span className="text-sm tabular-nums text-sky-400">{ep.latency_ms} ms</span>
                )}
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Active downloads */}
      {downloads && (downloads.active.length > 0 || downloads.waiting.length > 0) && (
        <div className="rounded-xl border border-slate-800 bg-slate-900 p-4 space-y-3">
          <h3 className="text-sm font-medium text-slate-300">Active Downloads</h3>
          {downloads.active.map((d) => (
            <div key={d.gid} className="space-y-1">
              <div className="flex justify-between text-xs">
                <span className="text-slate-300">{d.filename}</span>
                <span className="text-slate-500">{d.completed_mb}/{d.total_mb} MB</span>
              </div>
              <ProgressBar pct={d.progress_pct} speed={d.speed_mbps} />
            </div>
          ))}
          {downloads.waiting.length > 0 && (
            <div className="text-xs text-slate-500">{downloads.waiting.length} file(s) waiting</div>
          )}
        </div>
      )}

      {downloads && !downloads.aria2_reachable && (
        <div className="rounded-lg border border-amber-800/50 bg-amber-950/20 px-4 py-2 text-sm text-amber-400">
          aria2 not reachable at hub. Run <code className="text-amber-300">scripts/setup_hub_hub.sh</code> on hub to enable download management.
          {downloads.error && <span className="ml-2 font-mono text-xs text-amber-300/70">{downloads.error}</span>}
        </div>
      )}

      {/* Download trigger */}
      <div className="rounded-xl border border-slate-800 bg-slate-900 p-4">
        <h3 className="mb-3 text-sm font-medium text-slate-300">Download Model</h3>
        <div className="flex gap-2">
          <input
            value={downloadModel}
            onChange={(e) => setDownloadModel(e.target.value)}
            placeholder="HuggingFace model ID (e.g. meta-llama/Llama-3.1-8B-Instruct)"
            className="flex-1 rounded border border-slate-700 bg-slate-800 px-3 py-1.5 text-sm text-slate-200 placeholder-slate-500"
            onKeyDown={(e) => e.key === "Enter" && triggerDownload()}
          />
          <button
            onClick={triggerDownload}
            disabled={!downloadModel.trim()}
            className="rounded bg-sky-600 px-4 py-1.5 text-sm text-white hover:bg-sky-500 disabled:opacity-50"
          >
            Download
          </button>
        </div>
        {downloadMsg && (
          <div className="mt-2 text-xs text-slate-400">{downloadMsg}</div>
        )}
      </div>

      {/* Installed models list */}
      {models && models.models.length > 0 && (
        <div className="rounded-xl border border-slate-800 bg-slate-900 p-4">
          <h3 className="mb-3 text-sm font-medium text-slate-300">Installed Models</h3>
          <div className="space-y-2">
            {models.models.map((m) => (
              <div
                key={m.path}
                className="flex items-center justify-between rounded-lg border border-slate-700 bg-slate-800/50 px-4 py-3"
              >
                <div className="space-y-1">
                  <div className="flex items-center gap-2">
                    <span className="font-medium text-slate-200">{m.name}</span>
                    <span className="rounded bg-slate-700 px-1.5 py-0.5 text-xs text-slate-400">{m.type}</span>
                  </div>
                  <div className="text-xs text-slate-500">
                    {m.size_gb} GB &middot; {m.file_count} file(s) &middot; <span className="font-mono">{m.path}</span>
                  </div>
                </div>
                <button
                  onClick={() => deleteModel(m.name, m.type)}
                  className="rounded border border-red-800/50 px-2 py-1 text-xs text-red-400 hover:text-red-300"
                >
                  Delete
                </button>
              </div>
            ))}
          </div>
        </div>
      )}

      {models && models.models.length === 0 && (
        <div className="rounded-xl border border-dashed border-slate-700 p-8 text-center text-sm text-slate-500">
          {models.models_dir_exists
            ? "No hub blobs indexed yet. Live routes above show what is online for chat. Use Download for new HF weights on hub."
            : `Hub not mounted at ${models.models_dir}. On hub run scripts/mount_nfs_models.sh and rebuild alfa-ai-api with the models volume.`}
        </div>
      )}
    </div>
  );
}
