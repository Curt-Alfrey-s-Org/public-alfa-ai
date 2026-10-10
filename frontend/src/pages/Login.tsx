import { FormEvent, useState } from "react";
import { Link } from "react-router-dom";
import { useAuth } from "../contexts/AuthContext";
import { api, ApiError, AUTH_EMAIL_NOT_VERIFIED, AUTH_INVALID_CREDENTIALS } from "../api/client";
import { ALFA_AVATAR_SRC, ALFA_PANEL_BG, alfaCardStyle } from "../lib/alfaChatTheme";

export default function Login() {
  const { login, verify2FA } = useAuth();
  const [loginId, setLoginId] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const [needs2FA, setNeeds2FA] = useState(false);
  const [tempToken, setTempToken] = useState("");
  const [code, setCode] = useState("");
  const [resendNote, setResendNote] = useState("");
  const [resending, setResending] = useState(false);

  async function handleLogin(e: FormEvent) {
    e.preventDefault();
    setError("");
    setResendNote("");
    setLoading(true);
    try {
      const result = await login(loginId, password);
      if ("requires2FA" in result) {
        setNeeds2FA(true);
        setTempToken(result.tempToken);
      }
    } catch (err) {
      setError(err instanceof ApiError ? err.message : AUTH_INVALID_CREDENTIALS);
    } finally {
      setLoading(false);
    }
  }

  async function handle2FA(e: FormEvent) {
    e.preventDefault();
    setError("");
    setLoading(true);
    try {
      await verify2FA(tempToken, code);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Verification failed");
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
          <p className="mt-1 text-sm text-slate-400">Sign in to continue</p>
        </div>

        <div className="rounded-xl border p-6 shadow-xl" style={alfaCardStyle}>
          {!needs2FA ? (
            <form onSubmit={handleLogin} className="space-y-4">
              <div>
                <label className="mb-1 block text-sm text-slate-300">
                  Email or username
                </label>
                <input
                  type="text"
                  required
                  autoComplete="username"
                  value={loginId}
                  onChange={(e) => setLoginId(e.target.value)}
                  className="w-full rounded-lg border border-slate-700 bg-slate-800 px-3 py-2 text-sm text-slate-100 placeholder-slate-500 focus:border-sky-500 focus:outline-none focus:ring-1 focus:ring-sky-500"
                  placeholder="operator@example.com or username"
                />
              </div>
              <div>
                <label className="mb-1 block text-sm text-slate-300">
                  Password
                </label>
                <input
                  type="password"
                  required
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  className="w-full rounded-lg border border-slate-700 bg-slate-800 px-3 py-2 text-sm text-slate-100 placeholder-slate-500 focus:border-sky-500 focus:outline-none focus:ring-1 focus:ring-sky-500"
                  placeholder="••••••••"
                />
              </div>
              {error && (
                <p className="text-sm text-red-400">{error}</p>
              )}
              {error === AUTH_EMAIL_NOT_VERIFIED && (
                <div className="space-y-2">
                  <button
                    type="button"
                    disabled={resending || !loginId.trim()}
                    onClick={async () => {
                      setResending(true);
                      setResendNote("");
                      try {
                        const res = await api.resendVerification(loginId.trim());
                        setResendNote(res.message);
                      } catch {
                        setResendNote("If that account exists and needs verification, a new link has been sent.");
                      } finally {
                        setResending(false);
                      }
                    }}
                    className="w-full text-sm text-sky-400 hover:text-sky-300 disabled:opacity-50"
                  >
                    {resending ? "Sending…" : "Resend verification email"}
                  </button>
                  {resendNote && <p className="text-xs text-slate-400">{resendNote}</p>}
                </div>
              )}
              <button
                type="submit"
                disabled={loading}
                className="w-full rounded-lg bg-sky-600 py-2 text-sm font-medium text-white transition hover:bg-sky-500 disabled:opacity-50"
              >
                {loading ? "Signing in…" : "Sign in"}
              </button>
            </form>
          ) : (
            <form onSubmit={handle2FA} className="space-y-4">
              <p className="text-sm text-slate-300">
                Enter the 6-digit code from your authenticator app.
              </p>
              <input
                type="text"
                inputMode="numeric"
                autoComplete="one-time-code"
                maxLength={6}
                required
                value={code}
                onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
                className="w-full rounded-lg border border-slate-700 bg-slate-800 px-3 py-2 text-center text-lg tracking-widest text-slate-100 focus:border-sky-500 focus:outline-none focus:ring-1 focus:ring-sky-500"
                placeholder="000000"
              />
              {error && (
                <p className="text-sm text-red-400">{error}</p>
              )}
              <button
                type="submit"
                disabled={loading}
                className="w-full rounded-lg bg-sky-600 py-2 text-sm font-medium text-white transition hover:bg-sky-500 disabled:opacity-50"
              >
                {loading ? "Verifying…" : "Verify"}
              </button>
              <button
                type="button"
                onClick={() => {
                  setNeeds2FA(false);
                  setCode("");
                  setError("");
                }}
                className="w-full text-sm text-slate-400 hover:text-slate-300"
              >
                Back to login
              </button>
            </form>
          )}

          <p className="mt-4 text-center text-sm text-slate-400">
            No account?{" "}
            <Link to="/register" className="text-sky-400 hover:text-sky-300">
              Create one
            </Link>
          </p>
          <div className="mt-3 text-center">
            <Link
              to="/guest"
              className="text-xs text-slate-500 transition hover:text-slate-300"
            >
              or try as guest (no account needed)
            </Link>
          </div>
        </div>
      </div>
    </div>
  );
}
