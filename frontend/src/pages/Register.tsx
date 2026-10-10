import { FormEvent, useState } from "react";
import { Link } from "react-router-dom";
import { useAuth } from "../contexts/AuthContext";
import { ApiError, REGISTER_COOLDOWN_HINT } from "../api/client";
import { ALFA_AVATAR_SRC, ALFA_PANEL_BG, alfaCardStyle } from "../lib/alfaChatTheme";

export default function Register() {
  const { register } = useAuth();
  const [email, setEmail] = useState("");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError("");
    setSuccess("");
    if (password !== confirm) {
      setError("Passwords do not match");
      return;
    }
    setLoading(true);
    try {
      const message = await register(email, username, password);
      setSuccess(message);
    } catch (err) {
      if (err instanceof ApiError && err.status === 429) {
        setError(REGISTER_COOLDOWN_HINT);
      } else if (err instanceof ApiError && err.status === 409) {
        setError(
          "Registration could not be completed. If you already have an account, sign in. New accounts need email verification and admin approval before you can sign in.",
        );
      } else {
        setError(err instanceof ApiError ? err.message : "Registration failed");
      }
    } finally {
      setLoading(false);
    }
  }

  return (
    <div
      className="flex min-h-screen items-center justify-center px-4"
      style={{ backgroundColor: ALFA_PANEL_BG }}
    >
      <div className="w-full max-w-sm">
        <div className="mb-8 flex flex-col items-center text-center">
          <img src={ALFA_AVATAR_SRC} alt="ALFa AI" className="mb-3 h-16 w-16 rounded-full object-cover" />
          <h1 className="text-3xl font-bold text-sky-400">ALFa AI</h1>
          <p className="mt-1 text-sm text-slate-400">Create your account</p>
        </div>

        <div className="rounded-xl border p-6 shadow-xl" style={alfaCardStyle}>
          {success ? (
            <div className="space-y-4">
              <h2 className="text-lg font-semibold text-slate-200">Account created</h2>
              <p className="text-sm text-slate-300">{success}</p>
              <Link
                to="/login"
                className="block w-full rounded-lg bg-sky-600 py-2 text-center text-sm font-medium text-white transition hover:bg-sky-500"
              >
                Go to sign in
              </Link>
            </div>
          ) : (
            <form onSubmit={handleSubmit} className="space-y-4">
              <div>
                <label className="mb-1 block text-sm text-slate-300">Email</label>
                <input
                  type="email"
                  required
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  className="w-full rounded-lg border border-slate-700 bg-slate-800 px-3 py-2 text-sm text-slate-100 placeholder-slate-500 focus:border-sky-500 focus:outline-none focus:ring-1 focus:ring-sky-500"
                  placeholder="operator@example.com"
                />
              </div>
              <div>
                <label className="mb-1 block text-sm text-slate-300">
                  Username
                </label>
                <input
                  type="text"
                  required
                  minLength={3}
                  maxLength={30}
                  value={username}
                  onChange={(e) => setUsername(e.target.value)}
                  className="w-full rounded-lg border border-slate-700 bg-slate-800 px-3 py-2 text-sm text-slate-100 placeholder-slate-500 focus:border-sky-500 focus:outline-none focus:ring-1 focus:ring-sky-500"
                  placeholder="cooluser42"
                />
              </div>
              <div>
                <label className="mb-1 block text-sm text-slate-300">
                  Password
                </label>
                <input
                  type="password"
                  required
                  minLength={8}
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  className="w-full rounded-lg border border-slate-700 bg-slate-800 px-3 py-2 text-sm text-slate-100 placeholder-slate-500 focus:border-sky-500 focus:outline-none focus:ring-1 focus:ring-sky-500"
                  placeholder="••••••••"
                />
              </div>
              <div>
                <label className="mb-1 block text-sm text-slate-300">
                  Confirm password
                </label>
                <input
                  type="password"
                  required
                  minLength={8}
                  value={confirm}
                  onChange={(e) => setConfirm(e.target.value)}
                  className="w-full rounded-lg border border-slate-700 bg-slate-800 px-3 py-2 text-sm text-slate-100 placeholder-slate-500 focus:border-sky-500 focus:outline-none focus:ring-1 focus:ring-sky-500"
                  placeholder="••••••••"
                />
              </div>
              {error && <p className="text-sm text-red-400">{error}</p>}
              <button
                type="submit"
                disabled={loading}
                className="w-full rounded-lg bg-sky-600 py-2 text-sm font-medium text-white transition hover:bg-sky-500 disabled:opacity-50"
              >
                {loading ? "Creating account…" : "Create account"}
              </button>
            </form>
          )}

          <p className="mt-4 text-center text-sm text-slate-400">
            Already have an account?{" "}
            <Link to="/login" className="text-sky-400 hover:text-sky-300">
              Sign in
            </Link>
          </p>
          <div className="mt-3 text-center">
            <Link
              to="/guest"
              className="text-xs text-slate-500 transition hover:text-slate-300"
            >
              or try as guest first
            </Link>
          </div>
        </div>
      </div>
    </div>
  );
}
