import { useCallback, useEffect, useState, type FormEvent } from "react";
import { useAuth } from "../../contexts/AuthContext";
import { api, ApiError } from "../../api/client";

interface AdminUser {
  id: string;
  email: string;
  username: string;
  role: string;
  is_2fa_enabled: boolean;
  is_active: boolean;
  email_verified: boolean;
  approved: boolean;
  approved_by: string | null;
  approved_at: string | null;
  created_at: string;
}

const BASE = "/alfa-ai/api/admin";

async function apiFetch<T>(path: string, token: string, opts?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    ...opts,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...opts?.headers },
  });
  if (!res.ok) {
    const d = await res.json().catch(() => ({ detail: res.statusText }));
    const detail = d.detail;
    const message =
      typeof detail === "string"
        ? detail
        : Array.isArray(detail)
          ? detail.map((e: { msg?: string }) => e.msg ?? JSON.stringify(e)).join("; ")
          : "Request failed";
    throw new ApiError(message, res.status);
  }
  return res.json();
}

type OtherPw = { new_password: string; new_password_confirm: string };

const inputCls =
  "w-full min-w-0 rounded border border-slate-700 bg-slate-800 px-2 py-1.5 text-xs text-slate-200 placeholder-slate-500 focus:border-sky-500 focus:outline-none focus:ring-1 focus:ring-sky-500";

export default function UsersPage() {
  const { token, user: self } = useAuth();
  const [users, setUsers] = useState<AdminUser[]>([]);
  const [error, setError] = useState("");
  const [okMsg, setOkMsg] = useState("");

  const [ownCurrent, setOwnCurrent] = useState("");
  const [ownNew, setOwnNew] = useState("");
  const [ownConfirm, setOwnConfirm] = useState("");
  const [ownSubmitting, setOwnSubmitting] = useState(false);

  const [otherPw, setOtherPw] = useState<Record<string, OtherPw>>({});
  const [otherSubmitting, setOtherSubmitting] = useState<string | null>(null);

  const [createEmail, setCreateEmail] = useState("");
  const [createUsername, setCreateUsername] = useState("");
  const [createPassword, setCreatePassword] = useState("");
  const [createConfirm, setCreateConfirm] = useState("");
  const [createSubmitting, setCreateSubmitting] = useState(false);
  const [rowBusy, setRowBusy] = useState<string | null>(null);

  const getOther = (id: string): OtherPw =>
    otherPw[id] ?? { new_password: "", new_password_confirm: "" };

  const setOtherField = (id: string, field: keyof OtherPw, value: string) => {
    setOtherPw((prev) => {
      const cur = prev[id] ?? { new_password: "", new_password_confirm: "" };
      return { ...prev, [id]: { ...cur, [field]: value } };
    });
  };

  const clearOtherPw = (id: string) => {
    setOtherPw((prev) => ({ ...prev, [id]: { new_password: "", new_password_confirm: "" } }));
  };

  const load = useCallback(async () => {
    if (!token) return;
    try {
      const data = await apiFetch<{ users: AdminUser[] }>("/users", token);
      setUsers(data.users);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to load users");
    }
  }, [token]);

  useEffect(() => {
    load();
  }, [load]);

  async function changeRole(userId: string, role: string) {
    if (!token) return;
    try {
      await apiFetch(`/users/${userId}/role`, token, {
        method: "PATCH",
        body: JSON.stringify({ role }),
      });
      load();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to update role");
    }
  }

  async function toggleActive(userId: string, active: boolean) {
    if (!token) return;
    try {
      await apiFetch(`/users/${userId}/active`, token, {
        method: "PATCH",
        body: JSON.stringify({ active }),
      });
      load();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to update status");
    }
  }

  async function setApproved(userId: string, approved: boolean, emailVerified: boolean) {
    if (!token) return;
    setError("");
    setOkMsg("");
    try {
      await apiFetch(`/users/${userId}/approve`, token, {
        method: "PATCH",
        body: JSON.stringify({ approved }),
      });
      if (approved && !emailVerified) {
        setOkMsg("Approved. They still cannot sign in until email is verified — use Mark verified or Resend verification.");
      } else {
        setOkMsg(approved ? "Account approved." : "Approval revoked.");
      }
      load();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to update approval");
    }
  }

  async function markEmailVerified(userId: string) {
    if (!token) return;
    setError("");
    setOkMsg("");
    setRowBusy(userId);
    try {
      await apiFetch(`/users/${userId}/email-verified`, token, {
        method: "PATCH",
        body: JSON.stringify({ verified: true }),
      });
      setOkMsg("Email marked verified (SMTP bypass). They still need Approve before they can sign in unless already approved.");
      load();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to mark email verified");
    } finally {
      setRowBusy(null);
    }
  }

  async function resendVerification(userId: string) {
    if (!token) return;
    setError("");
    setOkMsg("");
    setRowBusy(userId);
    try {
      const res = await apiFetch<{ ok: boolean; sent?: boolean; message?: string }>(
        `/users/${userId}/resend-verification`,
        token,
        { method: "POST" },
      );
      setOkMsg(res.message || "Verification email requested.");
      load();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to resend verification");
    } finally {
      setRowBusy(null);
    }
  }

  async function onCreateUser(e: FormEvent) {
    e.preventDefault();
    if (!token) return;
    setError("");
    setOkMsg("");
    if (createPassword !== createConfirm) {
      setError("Password and confirmation do not match.");
      return;
    }
    setCreateSubmitting(true);
    try {
      const res = await apiFetch<{ ok: boolean; message?: string }>("/users", token, {
        method: "POST",
        body: JSON.stringify({
          email: createEmail.trim(),
          username: createUsername.trim(),
          password: createPassword,
          password_confirm: createConfirm,
        }),
      });
      setCreateEmail("");
      setCreateUsername("");
      setCreatePassword("");
      setCreateConfirm("");
      setOkMsg(res.message || "User created. They can sign in now.");
      load();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to create user");
    } finally {
      setCreateSubmitting(false);
    }
  }

  async function onChangeOwnPassword(e: FormEvent) {
    e.preventDefault();
    if (!token) return;
    setError("");
    setOkMsg("");
    if (ownNew.length < 8) {
      setError("New password must be at least 8 characters.");
      return;
    }
    if (ownNew !== ownConfirm) {
      setError("New password and confirmation do not match.");
      return;
    }
    setOwnSubmitting(true);
    try {
      await api.changePassword(token, ownCurrent, ownNew, ownConfirm);
      setOwnCurrent("");
      setOwnNew("");
      setOwnConfirm("");
      setOkMsg("Your password was updated. 2FA was reset for your account—re-enable if needed.");
      load();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to change password");
    } finally {
      setOwnSubmitting(false);
    }
  }

  async function adminSetOtherUserPassword(userId: string) {
    if (!token) return;
    const row = getOther(userId);
    const np = row.new_password.trim();
    const nc = row.new_password_confirm.trim();
    setError("");
    setOkMsg("");
    if (np.length < 8) {
      setError("New password must be at least 8 characters.");
      return;
    }
    if (np !== nc) {
      setError("New password and confirmation do not match.");
      return;
    }
    setOtherSubmitting(userId);
    try {
      await apiFetch(`/users/${userId}/password`, token, {
        method: "PATCH",
        body: JSON.stringify({ new_password: np, new_password_confirm: nc }),
      });
      clearOtherPw(userId);
      setOkMsg("Password updated for that user (2FA cleared for that account).");
      load();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to set password");
    } finally {
      setOtherSubmitting(null);
    }
  }

  return (
    <div className="h-full overflow-y-auto p-6">
      <h2 className="mb-4 text-lg font-semibold text-slate-200">User Management</h2>
      {error && (
        <div className="mb-4 rounded-lg border border-red-800/50 bg-red-950/30 px-4 py-2 text-sm text-red-400">
          {error}
        </div>
      )}
      {okMsg && (
        <div className="mb-4 rounded-lg border border-green-800/50 bg-green-950/30 px-4 py-2 text-sm text-green-400">
          {okMsg}
        </div>
      )}

      <section
        className="mb-8 max-w-md rounded-xl border border-slate-800 bg-slate-900/50 p-5 shadow-lg"
        aria-labelledby="own-password-heading"
      >
        <h3 id="own-password-heading" className="mb-1 text-sm font-semibold text-slate-200">
          Change your password
        </h3>
        <p className="mb-4 text-xs text-slate-500">
          Enter your current password, then a new one twice so we can verify they match.
        </p>
        <form onSubmit={onChangeOwnPassword} className="space-y-3">
          <div>
            <label className="mb-1 block text-xs text-slate-400" htmlFor="own-current">
              Current password
            </label>
            <input
              id="own-current"
              type="password"
              autoComplete="current-password"
              value={ownCurrent}
              onChange={(e) => setOwnCurrent(e.target.value)}
              className={inputCls}
              required
            />
          </div>
          <div>
            <label className="mb-1 block text-xs text-slate-400" htmlFor="own-new">
              New password
            </label>
            <input
              id="own-new"
              type="password"
              autoComplete="new-password"
              value={ownNew}
              onChange={(e) => setOwnNew(e.target.value)}
              className={inputCls}
              required
              minLength={8}
              placeholder="8+ characters"
            />
          </div>
          <div>
            <label className="mb-1 block text-xs text-slate-400" htmlFor="own-confirm">
              Confirm new password
            </label>
            <input
              id="own-confirm"
              type="password"
              autoComplete="new-password"
              value={ownConfirm}
              onChange={(e) => setOwnConfirm(e.target.value)}
              className={inputCls}
              required
              minLength={8}
            />
          </div>
          <button
            type="submit"
            disabled={ownSubmitting}
            className="w-full rounded-lg bg-sky-600 py-2 text-sm font-medium text-white transition hover:bg-sky-500 disabled:opacity-50"
          >
            {ownSubmitting ? "Saving…" : "Update your password"}
          </button>
        </form>
      </section>

      <section
        className="mb-8 max-w-md rounded-xl border border-slate-800 bg-slate-900/50 p-5 shadow-lg"
        aria-labelledby="create-user-heading"
      >
        <h3 id="create-user-heading" className="mb-1 text-sm font-semibold text-slate-200">
          Create user
        </h3>
        <p className="mb-4 text-xs text-slate-500">
          Creates an account that can sign in immediately (email verified and approved).
          Does not send a verification email.
        </p>
        <form onSubmit={onCreateUser} className="space-y-3">
          <div>
            <label className="mb-1 block text-xs text-slate-400" htmlFor="create-email">
              Email
            </label>
            <input
              id="create-email"
              type="email"
              required
              value={createEmail}
              onChange={(e) => setCreateEmail(e.target.value)}
              className={inputCls}
              placeholder="operator@example.com"
            />
          </div>
          <div>
            <label className="mb-1 block text-xs text-slate-400" htmlFor="create-username">
              Username
            </label>
            <input
              id="create-username"
              type="text"
              required
              minLength={3}
              maxLength={30}
              value={createUsername}
              onChange={(e) => setCreateUsername(e.target.value)}
              className={inputCls}
              placeholder="username"
            />
          </div>
          <div>
            <label className="mb-1 block text-xs text-slate-400" htmlFor="create-password">
              Password
            </label>
            <input
              id="create-password"
              type="password"
              required
              minLength={8}
              autoComplete="new-password"
              value={createPassword}
              onChange={(e) => setCreatePassword(e.target.value)}
              className={inputCls}
              placeholder="8+ characters"
            />
          </div>
          <div>
            <label className="mb-1 block text-xs text-slate-400" htmlFor="create-confirm">
              Confirm password
            </label>
            <input
              id="create-confirm"
              type="password"
              required
              minLength={8}
              autoComplete="new-password"
              value={createConfirm}
              onChange={(e) => setCreateConfirm(e.target.value)}
              className={inputCls}
            />
          </div>
          <button
            type="submit"
            disabled={createSubmitting}
            className="w-full rounded-lg bg-sky-600 py-2 text-sm font-medium text-white transition hover:bg-sky-500 disabled:opacity-50"
          >
            {createSubmitting ? "Creating…" : "Create user"}
          </button>
        </form>
      </section>

      <div className="overflow-x-auto rounded-lg border border-slate-800">
        <table className="w-full text-sm">
          <thead className="bg-slate-800/50">
            <tr>
              <th className="px-4 py-2 text-left text-slate-400">Username</th>
              <th className="px-4 py-2 text-left text-slate-400">Email</th>
              <th className="px-4 py-2 text-left text-slate-400">Role</th>
              <th className="px-4 py-2 text-left text-slate-400">2FA</th>
              <th className="px-4 py-2 text-left text-slate-400">Email Verified</th>
              <th className="px-4 py-2 text-left text-slate-400">Approval</th>
              <th className="px-4 py-2 text-left text-slate-400">Status</th>
              <th className="px-4 py-2 text-left text-slate-400 min-w-[240px]">Password</th>
              <th className="px-4 py-2 text-left text-slate-400">Actions</th>
            </tr>
          </thead>
          <tbody>
            {users.map((u) => {
              const isSelf = u.id === self?.id;
              return (
                <tr key={u.id} className="border-t border-slate-800 hover:bg-slate-800/30">
                  <td className="px-4 py-2 text-slate-200">{u.username}</td>
                  <td className="px-4 py-2 text-slate-400">{u.email}</td>
                  <td className="px-4 py-2">
                    <select
                      value={u.role}
                      onChange={(e) => changeRole(u.id, e.target.value)}
                      className="rounded border border-slate-700 bg-slate-800 px-2 py-0.5 text-xs text-slate-200"
                    >
                      <option value="guest">guest</option>
                      <option value="user">user</option>
                      <option value="admin">admin</option>
                    </select>
                  </td>
                  <td className="px-4 py-2">
                    {u.is_2fa_enabled ? (
                      <span className="text-green-400">enabled</span>
                    ) : (
                      <span className="text-slate-600">off</span>
                    )}
                  </td>
                  <td className="px-4 py-2">
                    {u.email_verified ? (
                      <span className="text-green-400">verified</span>
                    ) : (
                      <div className="flex flex-col items-start gap-1.5">
                        <span className="text-amber-400">unverified</span>
                        <button
                          type="button"
                          disabled={rowBusy === u.id}
                          onClick={() => resendVerification(u.id)}
                          className="rounded border border-sky-800 px-2 py-0.5 text-xs text-sky-400 hover:bg-sky-950 disabled:opacity-50"
                        >
                          Resend verification
                        </button>
                        <button
                          type="button"
                          disabled={rowBusy === u.id}
                          onClick={() => markEmailVerified(u.id)}
                          className="rounded border border-amber-700 px-2 py-0.5 text-xs text-amber-400 hover:bg-amber-950 disabled:opacity-50"
                        >
                          Mark verified
                        </button>
                      </div>
                    )}
                  </td>
                  <td className="px-4 py-2">
                    {u.approved ? (
                      <span className="text-green-400">approved</span>
                    ) : (
                      <button
                        type="button"
                        onClick={() => setApproved(u.id, true, u.email_verified)}
                        className="rounded border border-amber-700 px-2 py-0.5 text-xs text-amber-400 hover:bg-amber-950"
                        title={!u.email_verified ? "User has not verified their email yet" : undefined}
                      >
                        Approve
                      </button>
                    )}
                  </td>
                  <td className="px-4 py-2">
                    {u.is_active ? (
                      <span className="text-green-400">active</span>
                    ) : (
                      <span className="text-red-400">deactivated</span>
                    )}
                  </td>
                  <td className="px-4 py-2 align-top">
                    {isSelf ? (
                      <p className="max-w-xs text-xs text-slate-500">
                        Use <span className="text-slate-400">Change your password</span> above (requires your
                        current password).
                      </p>
                    ) : (
                      <div className="flex max-w-[min(280px,40vw)] flex-col gap-2">
                        <div>
                          <span className="mb-0.5 block text-[10px] uppercase tracking-wide text-slate-500">
                            New password
                          </span>
                          <input
                            type="password"
                            autoComplete="new-password"
                            value={getOther(u.id).new_password}
                            onChange={(e) => setOtherField(u.id, "new_password", e.target.value)}
                            className={inputCls}
                            placeholder="8+ characters"
                            disabled={otherSubmitting === u.id}
                          />
                        </div>
                        <div>
                          <span className="mb-0.5 block text-[10px] uppercase tracking-wide text-slate-500">
                            Confirm
                          </span>
                          <input
                            type="password"
                            autoComplete="new-password"
                            value={getOther(u.id).new_password_confirm}
                            onChange={(e) => setOtherField(u.id, "new_password_confirm", e.target.value)}
                            className={inputCls}
                            placeholder="Re-enter new password"
                            disabled={otherSubmitting === u.id}
                          />
                        </div>
                        <button
                          type="button"
                          onClick={() => adminSetOtherUserPassword(u.id)}
                          disabled={otherSubmitting === u.id}
                          className="rounded border border-sky-800 py-1.5 text-xs text-sky-400 hover:bg-sky-950 disabled:opacity-50"
                        >
                          {otherSubmitting === u.id ? "Setting…" : "Set password"}
                        </button>
                      </div>
                    )}
                  </td>
                  <td className="px-4 py-2 align-top">
                    <button
                      type="button"
                      onClick={() => toggleActive(u.id, !u.is_active)}
                      className={`rounded px-2 py-0.5 text-xs ${
                        u.is_active
                          ? "border border-red-800 text-red-400 hover:bg-red-950"
                          : "border border-green-800 text-green-400 hover:bg-green-950"
                      }`}
                    >
                      {u.is_active ? "Deactivate" : "Activate"}
                    </button>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
