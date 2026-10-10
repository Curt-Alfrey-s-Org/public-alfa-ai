import { useEffect, useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { api, ApiError } from "../api/client";
import { ALFA_AVATAR_SRC, ALFA_PANEL_BG, alfaCardStyle } from "../lib/alfaChatTheme";

type Status = "checking" | "ok" | "error";

/** docs/AUTH_ACCOUNT_LIFECYCLE.md: lands here from the emailed verification link. */
export default function VerifyEmail() {
  const [params] = useSearchParams();
  const token = params.get("token") ?? "";
  const [status, setStatus] = useState<Status>("checking");
  const [message, setMessage] = useState("Verifying your email…");

  useEffect(() => {
    if (!token) {
      setStatus("error");
      setMessage("This verification link is missing its token.");
      return;
    }
    let cancelled = false;
    api
      .verifyEmail(token)
      .then((res) => {
        if (cancelled) return;
        setStatus("ok");
        setMessage(res.message);
      })
      .catch((err) => {
        if (cancelled) return;
        setStatus("error");
        setMessage(err instanceof ApiError ? err.message : "Verification failed.");
      });
    return () => {
      cancelled = true;
    };
  }, [token]);

  return (
    <div
      className="flex min-h-screen items-center justify-center px-4"
      style={{ backgroundColor: ALFA_PANEL_BG }}
    >
      <div className="w-full max-w-sm">
        <div className="mb-8 flex flex-col items-center text-center">
          <img src={ALFA_AVATAR_SRC} alt="ALFa AI" className="mb-3 h-16 w-16 rounded-full object-cover" />
          <h1 className="text-3xl font-bold text-sky-400">ALFa AI</h1>
        </div>
        <div className="rounded-xl border p-6 text-center shadow-xl" style={alfaCardStyle}>
          <h2 className="mb-2 text-lg font-semibold text-slate-200">
            {status === "ok" ? "Email verified" : status === "error" ? "Verification problem" : "One moment…"}
          </h2>
          <p className={`text-sm ${status === "error" ? "text-red-400" : "text-slate-400"}`}>{message}</p>
          <div className="mt-4">
            <Link to="/login" className="text-sm text-sky-400 hover:text-sky-300">
              Go to sign in
            </Link>
          </div>
        </div>
      </div>
    </div>
  );
}
