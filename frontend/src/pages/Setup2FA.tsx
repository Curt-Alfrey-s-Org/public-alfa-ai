import { FormEvent, useCallback, useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { QRCodeSVG } from "qrcode.react";
import { useAuth } from "../contexts/AuthContext";
import { api, ApiError } from "../api/client";

export default function Setup2FA() {
  const { token } = useAuth();
  const navigate = useNavigate();
  const [secret, setSecret] = useState("");
  const [uri, setUri] = useState("");
  const [code, setCode] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const [success, setSuccess] = useState(false);
  const [showManual, setShowManual] = useState(false);

  const setup = useCallback(async () => {
    if (!token) return;
    try {
      const res = await api.setup2FA(token);
      setSecret(res.secret);
      setUri(res.provisioning_uri);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to setup 2FA");
    }
  }, [token]);

  useEffect(() => {
    setup();
  }, [setup]);

  async function handleEnable(e: FormEvent) {
    e.preventDefault();
    if (!token) return;
    setError("");
    setLoading(true);
    try {
      await api.enable2FA(token, code);
      setSuccess(true);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to enable 2FA");
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center px-4">
      <div className="w-full max-w-md">
        <div className="mb-8 text-center">
          <h1 className="text-2xl font-bold text-sky-400">
            Set Up Two-Factor Authentication
          </h1>
          <p className="mt-1 text-sm text-slate-400">
            Add an extra layer of security to your account
          </p>
        </div>

        <div className="rounded-xl border border-slate-800 bg-slate-900 p-6 shadow-xl">
          {success ? (
            <div className="space-y-4 text-center">
              <div className="text-3xl text-green-400">&#10003;</div>
              <p className="font-medium text-green-400">
                2FA enabled successfully!
              </p>
              <button
                onClick={() => navigate("/")}
                className="rounded-lg bg-sky-600 px-6 py-2 text-sm font-medium text-white hover:bg-sky-500"
              >
                Go to Chat
              </button>
            </div>
          ) : (
            <div className="space-y-5">
              <p className="text-sm text-slate-300">
                1. Scan this QR code with your authenticator app (Google
                Authenticator, Authy, etc.)
              </p>

              {uri && (
                <div className="flex justify-center">
                  <div className="rounded-xl bg-white p-4">
                    <QRCodeSVG
                      value={uri}
                      size={200}
                      level="M"
                      bgColor="#ffffff"
                      fgColor="#000000"
                    />
                  </div>
                </div>
              )}

              <div className="text-center">
                <button
                  type="button"
                  onClick={() => setShowManual(!showManual)}
                  className="text-xs text-slate-500 hover:text-slate-300"
                >
                  {showManual ? "Hide manual key" : "Can't scan? Enter key manually"}
                </button>
                {showManual && secret && (
                  <div className="mt-2 rounded-lg bg-slate-800 p-3">
                    <code className="break-all text-sm text-sky-300">
                      {secret}
                    </code>
                  </div>
                )}
              </div>

              <form onSubmit={handleEnable} className="space-y-4">
                <div>
                  <p className="mb-2 text-sm text-slate-300">
                    2. Enter the 6-digit code from your app:
                  </p>
                  <input
                    type="text"
                    inputMode="numeric"
                    autoComplete="one-time-code"
                    maxLength={6}
                    required
                    value={code}
                    onChange={(e) =>
                      setCode(e.target.value.replace(/\D/g, ""))
                    }
                    className="w-full rounded-lg border border-slate-700 bg-slate-800 px-3 py-2 text-center text-lg tracking-widest text-slate-100 focus:border-sky-500 focus:outline-none focus:ring-1 focus:ring-sky-500"
                    placeholder="000000"
                  />
                </div>
                {error && <p className="text-sm text-red-400">{error}</p>}
                <button
                  type="submit"
                  disabled={loading}
                  className="w-full rounded-lg bg-sky-600 py-2 text-sm font-medium text-white transition hover:bg-sky-500 disabled:opacity-50"
                >
                  {loading ? "Enabling…" : "Enable 2FA"}
                </button>
              </form>

              <button
                onClick={() => navigate("/")}
                className="w-full text-sm text-slate-400 hover:text-slate-300"
              >
                Skip for now
              </button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
