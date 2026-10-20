import { useCallback, useEffect, useState } from "react";
import { useAuth } from "../../contexts/AuthContext";
import { ApiError } from "../../api/client";

interface AuditEvent {
  id: string;
  user_id: string | null;
  email: string | null;
  username: string | null;
  event_type: string;
  ip_address: string | null;
  success: boolean;
  details: string | null;
  created_at: string;
}

interface IpBlock {
  id: string;
  ip_address: string;
  reason: string;
  blocked_at: string;
  expires_at: string | null;
}

const BASE = "/alfa-ai/api/admin";

async function apiFetch<T>(path: string, token: string): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!res.ok) {
    const d = await res.json().catch(() => ({ detail: res.statusText }));
    throw new ApiError(d.detail ?? "Failed", res.status);
  }
  return res.json();
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

export default function AuditPage() {
  const { token } = useAuth();
  const [events, setEvents] = useState<AuditEvent[]>([]);
  const [blocks, setBlocks] = useState<IpBlock[]>([]);
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    if (!token) return;
    try {
      const [evtData, blkData] = await Promise.all([
        apiFetch<{ events: AuditEvent[] }>("/audit-log", token),
        apiFetch<{ blocks: IpBlock[] }>("/ip-blocks", token),
      ]);
      setEvents(evtData.events);
      setBlocks(blkData.blocks);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to load");
    }
  }, [token]);

  useEffect(() => { load(); }, [load]);

  return (
    <div className="h-full overflow-y-auto p-6">
      <div className="mb-6 flex items-center justify-between">
        <h2 className="text-lg font-semibold text-slate-200">Audit Log & IP Blocks</h2>
        <button
          onClick={load}
          className="rounded border border-slate-700 px-3 py-1 text-xs text-slate-400 hover:text-slate-200"
        >
          Refresh
        </button>
      </div>
      {error && (
        <div className="mb-4 rounded-lg border border-red-800/50 bg-red-950/30 px-4 py-2 text-sm text-red-400">
          {error}
        </div>
      )}

      {blocks.length > 0 && (
        <div className="mb-6">
          <h3 className="mb-2 text-sm font-medium text-red-400">
            Blocked IPs ({blocks.length})
          </h3>
          <div className="overflow-x-auto rounded-lg border border-red-800/30">
            <table className="w-full text-sm">
              <thead className="bg-red-950/30">
                <tr>
                  <th className="px-3 py-1.5 text-left text-slate-400">IP</th>
                  <th className="px-3 py-1.5 text-left text-slate-400">Reason</th>
                  <th className="px-3 py-1.5 text-left text-slate-400">Blocked</th>
                  <th className="px-3 py-1.5 text-left text-slate-400">Expires</th>
                </tr>
              </thead>
              <tbody>
                {blocks.map((b) => (
                  <tr key={b.id} className="border-t border-red-800/20">
                    <td className="px-3 py-1.5 font-mono text-red-300">{b.ip_address}</td>
                    <td className="px-3 py-1.5 text-slate-400">{b.reason}</td>
                    <td className="px-3 py-1.5 text-slate-500">{timeAgo(b.blocked_at)}</td>
                    <td className="px-3 py-1.5 text-slate-500">{b.expires_at ? new Date(b.expires_at).toLocaleDateString() : "never"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      <h3 className="mb-2 text-sm font-medium text-slate-300">
        Recent Events ({events.length})
      </h3>
      <div className="overflow-x-auto rounded-lg border border-slate-800">
        <table className="w-full text-sm">
          <thead className="bg-slate-800/50">
            <tr>
              <th className="px-3 py-1.5 text-left text-slate-400">Time</th>
              <th className="px-3 py-1.5 text-left text-slate-400">Event</th>
              <th className="px-3 py-1.5 text-left text-slate-400">User</th>
              <th className="px-3 py-1.5 text-left text-slate-400">IP</th>
              <th className="px-3 py-1.5 text-left text-slate-400">Status</th>
              <th className="px-3 py-1.5 text-left text-slate-400">Details</th>
            </tr>
          </thead>
          <tbody>
            {events.map((e) => (
              <tr key={e.id} className="border-t border-slate-800 hover:bg-slate-800/30">
                <td className="whitespace-nowrap px-3 py-1.5 text-slate-500">{timeAgo(e.created_at)}</td>
                <td className="px-3 py-1.5 font-mono text-xs text-slate-300">{e.event_type}</td>
                <td className="px-3 py-1.5 text-slate-400">{e.username ?? e.email ?? "—"}</td>
                <td className="px-3 py-1.5 font-mono text-xs text-slate-500">{e.ip_address ?? "—"}</td>
                <td className="px-3 py-1.5">
                  {e.success ? (
                    <span className="text-green-400">OK</span>
                  ) : (
                    <span className="text-red-400">FAIL</span>
                  )}
                </td>
                <td className="max-w-xs truncate px-3 py-1.5 text-xs text-slate-500">{e.details ?? ""}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
