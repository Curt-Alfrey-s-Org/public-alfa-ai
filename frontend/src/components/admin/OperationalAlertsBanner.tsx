import { useCallback, useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";

const BASE = "/alfa-ai/api/admin";
const POLL_MS = 30_000;
const DISMISS_KEY = "alfa_ai_dismissed_operational_warnings";

export interface OperationalWarning {
  id: string;
  level: "error" | "warning";
  title: string;
  message: string;
  hint?: string;
}

interface OperationalWarningsResponse {
  warnings: OperationalWarning[];
  ts?: number;
}

function loadDismissed(): Set<string> {
  try {
    const raw = sessionStorage.getItem(DISMISS_KEY);
    if (!raw) return new Set();
    const parsed = JSON.parse(raw) as string[];
    return new Set(parsed);
  } catch {
    return new Set();
  }
}

function saveDismissed(ids: Set<string>) {
  sessionStorage.setItem(DISMISS_KEY, JSON.stringify([...ids]));
}

interface OperationalAlertsBannerProps {
  token: string;
}

export default function OperationalAlertsBanner({ token }: OperationalAlertsBannerProps) {
  const [warnings, setWarnings] = useState<OperationalWarning[]>([]);
  const [dismissed, setDismissed] = useState<Set<string>>(loadDismissed);
  const [modalOpen, setModalOpen] = useState(false);

  const fetchWarnings = useCallback(async () => {
    try {
      const res = await fetch(`${BASE}/operational-warnings`, {
        headers: { Authorization: `Bearer ${token}` },
      });
      if (!res.ok) return;
      const data = (await res.json()) as OperationalWarningsResponse;
      setWarnings(data.warnings ?? []);
    } catch {
      /* ignore transient poll errors */
    }
  }, [token]);

  useEffect(() => {
    let cancelled = false;
    async function poll() {
      if (cancelled) return;
      await fetchWarnings();
    }
    poll();
    const interval = setInterval(poll, POLL_MS);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [fetchWarnings]);

  const activeWarnings = useMemo(
    () => warnings.filter((w) => !dismissed.has(w.id)),
    [warnings, dismissed],
  );

  const criticalWarnings = useMemo(
    () => activeWarnings.filter((w) => w.level === "error"),
    [activeWarnings],
  );

  useEffect(() => {
    if (criticalWarnings.length > 0) {
      setModalOpen(true);
    } else {
      setModalOpen(false);
    }
  }, [criticalWarnings.length, criticalWarnings.map((w) => w.id).join(",")]);

  const dismissAll = () => {
    const next = new Set(dismissed);
    for (const w of activeWarnings) {
      next.add(w.id);
    }
    setDismissed(next);
    saveDismissed(next);
    setModalOpen(false);
  };

  if (activeWarnings.length === 0) {
    return null;
  }

  return (
    <>
      <div
        className="border-b border-amber-900/50 bg-amber-950/50 px-4 py-2"
        role="status"
        aria-live="polite"
      >
        <div className="flex flex-wrap items-start justify-between gap-2">
          <div className="min-w-0 flex-1 space-y-1">
            {activeWarnings.map((w) => (
              <div key={w.id} className="text-sm">
                <span
                  className={
                    w.level === "error"
                      ? "font-medium text-red-300"
                      : "font-medium text-amber-300"
                  }
                >
                  {w.title}
                </span>
                <span className="text-slate-400"> — {w.message}</span>
              </div>
            ))}
          </div>
          <div className="flex shrink-0 gap-2">
            <Link
              to="/admin/health"
              className="rounded border border-slate-600 px-2 py-1 text-xs text-slate-300 hover:bg-slate-800"
            >
              Health
            </Link>
            <button
              type="button"
              onClick={dismissAll}
              className="rounded border border-slate-600 px-2 py-1 text-xs text-slate-400 hover:bg-slate-800"
            >
              Dismiss
            </button>
          </div>
        </div>
      </div>

      {modalOpen && criticalWarnings.length > 0 && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
          role="dialog"
          aria-modal="true"
          aria-labelledby="operational-alert-title"
        >
          <div className="max-h-[85vh] w-full max-w-lg overflow-y-auto rounded-lg border border-red-900/60 bg-slate-900 p-5 shadow-xl">
            <h2 id="operational-alert-title" className="text-lg font-semibold text-red-300">
              Action required
            </h2>
            <p className="mt-1 text-sm text-slate-400">
              These issues affect monitoring and admin sessions. Fix them before they cause
              silent outages.
            </p>
            <div className="mt-4 space-y-4">
              {criticalWarnings.map((w) => (
                <div
                  key={w.id}
                  className="rounded border border-red-900/40 bg-red-950/30 p-3"
                >
                  <p className="font-medium text-red-200">{w.title}</p>
                  <p className="mt-1 text-sm text-slate-300">{w.message}</p>
                  {w.hint && (
                    <p className="mt-2 text-xs text-slate-400">
                      <span className="font-medium text-slate-300">Fix: </span>
                      {w.hint}
                    </p>
                  )}
                </div>
              ))}
            </div>
            <div className="mt-5 flex flex-wrap justify-end gap-2">
              <Link
                to="/admin/health"
                className="rounded-lg border border-slate-600 px-3 py-1.5 text-sm text-slate-300 hover:bg-slate-800"
                onClick={() => setModalOpen(false)}
              >
                Open Health
              </Link>
              <button
                type="button"
                onClick={dismissAll}
                className="rounded-lg bg-red-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-600"
              >
                Dismiss for this session
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
