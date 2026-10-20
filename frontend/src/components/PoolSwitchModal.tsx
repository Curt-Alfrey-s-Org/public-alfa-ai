import { useState } from "react";
import { api, ApiError } from "../api/client";

interface PoolSwitchModalProps {
  targetPool: "inference" | "pool35";
  targetLabel: string;
  token: string;
  requires2FA: boolean;
  onClose: () => void;
  onAccepted: () => void;
}

export default function PoolSwitchModal({
  targetPool,
  targetLabel,
  token,
  requires2FA,
  onClose,
  onAccepted,
}: PoolSwitchModalProps) {
  const [password, setPassword] = useState("");
  const [totpCode, setTotpCode] = useState("");
  const [error, setError] = useState("");
  const [submitting, setSubmitting] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError("");
    setSubmitting(true);
    try {
      await api.poolSwitch(token, {
        target: targetPool,
        password,
        totp_code: requires2FA ? totpCode : undefined,
      });
      onAccepted();
    } catch (err) {
      if (err instanceof ApiError) {
        setError(err.message || "Activation failed.");
      } else {
        setError("Activation failed.");
      }
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="pool-switch-title"
    >
      <div className="w-full max-w-md rounded-lg border border-slate-700 bg-slate-900 p-6 shadow-xl">
        <h2 id="pool-switch-title" className="text-lg font-semibold text-sky-400">
          Activate model
        </h2>
        <p className="mt-2 text-sm text-slate-400">
          Switch the inference pool to <strong className="text-slate-200">{targetLabel}</strong>.
          Confirm with your account password
          {requires2FA ? " and 2FA code" : ""}.
        </p>
        <form onSubmit={handleSubmit} className="mt-4 space-y-3">
          <div>
            <label htmlFor="pool-switch-password" className="block text-xs text-slate-400">
              Password
            </label>
            <input
              id="pool-switch-password"
              type="password"
              autoComplete="current-password"
              required
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="mt-1 w-full rounded border border-slate-700 bg-slate-800 px-3 py-2 text-sm text-slate-100"
            />
          </div>
          {requires2FA && (
            <div>
              <label htmlFor="pool-switch-totp" className="block text-xs text-slate-400">
                2FA code
              </label>
              <input
                id="pool-switch-totp"
                type="text"
                inputMode="numeric"
                autoComplete="one-time-code"
                required
                maxLength={8}
                value={totpCode}
                onChange={(e) => setTotpCode(e.target.value)}
                className="mt-1 w-full rounded border border-slate-700 bg-slate-800 px-3 py-2 text-sm text-slate-100"
              />
            </div>
          )}
          {error && (
            <p className="text-sm text-red-400" role="alert">
              {error}
            </p>
          )}
          <div className="flex justify-end gap-2 pt-2">
            <button
              type="button"
              onClick={onClose}
              disabled={submitting}
              className="rounded px-3 py-1.5 text-sm text-slate-400 hover:text-slate-200"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={submitting}
              className="rounded bg-sky-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-sky-500 disabled:opacity-50"
            >
              {submitting ? "Starting..." : "Activate"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
