import { useEffect, useState } from "react";
import { api, type PoolSwitchStatus } from "../api/client";

interface PoolStatusBannerProps {
  token: string;
  onReady: () => void;
}

export default function PoolStatusBanner({ token, onReady }: PoolStatusBannerProps) {
  const [status, setStatus] = useState<PoolSwitchStatus | null>(null);

  useEffect(() => {
    let cancelled = false;
    let readyNotified = false;

    async function poll() {
      try {
        const data = await api.poolStatus(token);
        if (cancelled) return;
        setStatus(data);
        if (data.phase === "ready" && !readyNotified) {
          readyNotified = true;
          onReady();
        }
        if (!data.switching && data.phase !== "ready" && data.phase !== "failed") {
          setStatus(null);
        }
      } catch {
        /* ignore transient poll errors */
      }
    }

    poll();
    const interval = setInterval(poll, 4000);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [token, onReady]);

  if (!status?.switching && status?.phase !== "failed") {
    return null;
  }

  const pct = status.estimated_pct ?? 0;
  const isReady = status.phase === "ready";
  const isFailed = status.phase === "failed";

  return (
    <div
      className={`border-b px-4 py-3 ${
        isFailed
          ? "border-red-900/50 bg-red-950/40"
          : isReady
            ? "border-emerald-900/50 bg-emerald-950/40"
            : "border-sky-900/50 bg-sky-950/40"
      }`}
      role="status"
      aria-live="polite"
    >
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="text-sm font-medium text-slate-200">
          {isFailed
            ? "Model switch failed"
            : isReady
              ? "Model ready"
              : `Switching to ${status.target_pool === "inference" ? "27B" : "35B"}...`}
        </span>
        {!isFailed && !isReady && status.estimated_label && (
          <span className="text-xs text-slate-400">~{pct}% (estimated)</span>
        )}
      </div>
      {!isFailed && (
        <div className="mt-2 h-2 overflow-hidden rounded-full bg-slate-800">
          <div
            className={`h-full transition-all duration-500 ${
              isReady ? "bg-emerald-500" : "bg-sky-500"
            }`}
            style={{ width: `${isReady ? 100 : pct}%` }}
          />
        </div>
      )}
      {status.phases && status.phases.length > 0 && (
        <ul className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-slate-500">
          {status.phases.map((p) => (
            <li
              key={p.id}
              className={p.done ? "text-emerald-400" : status.phase === p.id ? "text-sky-400" : undefined}
            >
              {p.label}
              {p.done ? " ✓" : status.phase === p.id ? " …" : ""}
            </li>
          ))}
        </ul>
      )}
      {isFailed && status.error && (
        <p className="mt-1 text-xs text-red-300">Try again or use the operator runbook.</p>
      )}
    </div>
  );
}
