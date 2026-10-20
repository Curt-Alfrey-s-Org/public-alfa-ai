import { useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { useAuth } from "../contexts/AuthContext";
import { api, ApiError } from "../api/client";

export default function AccountPassword() {
  const { token } = useAuth();
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState("");
  const [ok, setOk] = useState("");

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError("");
    setOk("");
    if (!token) return;
    if (next.length < 8) {
      setError("New password must be at least 8 characters.");
      return;
    }
    if (next !== confirm) {
      setError("New password and confirmation do not match.");
      return;
    }
    try {
      await api.changePassword(token, current, next, confirm);
      setOk("Password updated. Use the new password next time you sign in.");
      setCurrent("");
      setNext("");
      setConfirm("");
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to change password");
    }
  }

  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-slate-950 px-4">
      <div className="w-full max-w-md rounded-xl border border-slate-800 bg-slate-900 p-6 shadow-xl">
        <h1 className="mb-1 text-lg font-semibold text-slate-200">Change password</h1>
        <p className="mb-4 text-sm text-slate-500">Update your account password.</p>
        {error && (
          <div className="mb-4 rounded-lg border border-red-800/50 bg-red-950/30 px-3 py-2 text-sm text-red-400">
            {error}
          </div>
        )}
        {ok && (
          <div className="mb-4 rounded-lg border border-green-800/50 bg-green-950/30 px-3 py-2 text-sm text-green-400">
            {ok}
          </div>
        )}
        <form onSubmit={handleSubmit} className="space-y-3">
          <div>
            <label className="mb-1 block text-xs text-slate-400">Current password</label>
            <input
              type="password"
              autoComplete="current-password"
              value={current}
              onChange={(e) => setCurrent(e.target.value)}
              className="w-full rounded-lg border border-slate-700 bg-slate-800 px-3 py-2 text-sm text-slate-200"
              required
            />
          </div>
          <div>
            <label className="mb-1 block text-xs text-slate-400">New password (8+ characters)</label>
            <input
              type="password"
              autoComplete="new-password"
              value={next}
              onChange={(e) => setNext(e.target.value)}
              className="w-full rounded-lg border border-slate-700 bg-slate-800 px-3 py-2 text-sm text-slate-200"
              required
              minLength={8}
            />
          </div>
          <div>
            <label className="mb-1 block text-xs text-slate-400">Confirm new password</label>
            <input
              type="password"
              autoComplete="new-password"
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
              className="w-full rounded-lg border border-slate-700 bg-slate-800 px-3 py-2 text-sm text-slate-200"
              required
              minLength={8}
            />
          </div>
          <button
            type="submit"
            className="w-full rounded-lg bg-sky-600 py-2 text-sm font-medium text-white hover:bg-sky-500"
          >
            Save
          </button>
        </form>
        <p className="mt-4 text-center text-sm">
          <Link to="/" className="text-sky-400 hover:text-sky-300">
            Back to chat
          </Link>
        </p>
      </div>
    </div>
  );
}
