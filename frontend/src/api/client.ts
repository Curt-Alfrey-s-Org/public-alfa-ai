const BASE = "/alfa-ai/api";

export const AUTH_INVALID_CREDENTIALS = "Invalid email, username, or password";
/** Must match src/api/public_errors.py EMAIL_NOT_VERIFIED_MSG (lifecycle login gate). */
export const AUTH_EMAIL_NOT_VERIFIED =
  "Please verify your email address first. Check your inbox for the confirmation link.";
/** Must match src/api/public_errors.py ACCOUNT_PENDING_APPROVAL_MSG. */
export const AUTH_PENDING_APPROVAL =
  "Your account is pending admin approval. Please contact the administrator.";
export const PUBLIC_CHAT_ERROR =
  "The assistant is temporarily unavailable. Please try again later.";
export const PUBLIC_RATE_LIMIT =
  "Too many requests. Please wait a moment and try again.";
export const REGISTER_COOLDOWN_HINT =
  "Please wait a couple of minutes before trying again. If you already submitted this form, your account may already exist. Wait for an administrator to verify and approve it before signing in.";

const INTERNAL_ERROR_PATTERN =
  /192\.168\.||wireguard|hub|\hub|\orchestrator|\apps|\inference|llama\.cpp|petals|rpc-server|brain|coordinator/i;

/** Sanitize API errors shown on public/guest chat surfaces. */
export function sanitizePublicError(
  detail: unknown,
  status: number,
  fallback = PUBLIC_CHAT_ERROR,
): string {
  if (status === 429) {
    return PUBLIC_RATE_LIMIT;
  }
  if (status >= 500) {
    return fallback;
  }
  const text = formatApiErrorDetail(detail, fallback);
  if (INTERNAL_ERROR_PATTERN.test(text)) {
    return fallback;
  }
  if (text.toLowerCase().includes("guest limit")) {
    return text;
  }
  if (status >= 400 && status < 500 && text.length <= 160) {
    return text;
  }
  return fallback;
}

interface RequestOptions {
  method?: string;
  body?: unknown;
  token?: string | null;
}

/** Normalize FastAPI ``detail`` (string, object, or validation array) for display. */
export function formatApiErrorDetail(detail: unknown, fallback = "Request failed"): string {
  if (detail == null || detail === "") {
    return fallback;
  }
  if (typeof detail === "string") {
    return detail;
  }
  if (Array.isArray(detail)) {
    const parts = detail
      .map((item) => {
        if (typeof item === "string") {
          return item;
        }
        if (item && typeof item === "object") {
          const msg = (item as { msg?: unknown }).msg;
          if (typeof msg === "string") {
            return msg;
          }
        }
        return "";
      })
      .filter(Boolean);
    return parts.length > 0 ? parts.join("; ") : fallback;
  }
  if (typeof detail === "object") {
    const msg = (detail as { msg?: unknown }).msg;
    if (typeof msg === "string") {
      return msg;
    }
  }
  return fallback;
}

function loginFailureMessage(status: number, detail: unknown): string {
  if (status === 429) {
    return PUBLIC_RATE_LIMIT;
  }
  const text = formatApiErrorDetail(detail, AUTH_INVALID_CREDENTIALS);
  if (status === 401) {
    if (text === AUTH_EMAIL_NOT_VERIFIED || text === AUTH_PENDING_APPROVAL) {
      return text;
    }
    return AUTH_INVALID_CREDENTIALS;
  }
  if (status === 403 || status === 422) {
    return AUTH_INVALID_CREDENTIALS;
  }
  return "Login failed";
}

async function request<T>(path: string, opts: RequestOptions = {}): Promise<T> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };
  if (opts.token) {
    headers["Authorization"] = `Bearer ${opts.token}`;
  }

  const res = await fetch(`${BASE}${path}`, {
    method: opts.method ?? "GET",
    headers,
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });

  if (!res.ok) {
    const data = await res.json().catch(() => ({ detail: res.statusText }));
    if (path === "/auth/login") {
      throw new ApiError(loginFailureMessage(res.status, data.detail), res.status);
    }
    throw new ApiError(
      formatApiErrorDetail(data.detail, res.statusText || "Request failed"),
      res.status,
    );
  }

  return res.json();
}

export class ApiError extends Error {
  constructor(
    message: string,
    public status: number,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

export interface User {
  id: string;
  email: string;
  username: string;
  is_admin: boolean;
  is_2fa_enabled: boolean;
}

export interface Conversation {
  id: string;
  user_id: string;
  title: string;
  model: string | null;
  created_at: string;
  updated_at: string;
}

export interface Message {
  id: string;
  conversation_id: string;
  role: string;
  content: string;
  created_at: string;
}

interface LoginResponse {
  access_token?: string;
  refresh_token?: string;
  user?: User;
  requires_2fa?: boolean;
  temp_token?: string;
}

interface ChatChoice {
  message?: { role: string; content: string };
  delta?: { content?: string };
}

interface ChatResponse {
  choices: ChatChoice[];
  conversation_id?: string;
}

export interface ChatModelOption {
  id: string;
  label: string;
  qwen_mode_supported?: boolean;
  /** False when the alias primary backend is down (shown greyed in picker). */
  active?: boolean;
  /** inference | pool35 when this alias maps to a switchable RPC pool. */
  pool?: "inference" | "pool35";
}

export interface PoolSwitchPhase {
  id: string;
  label: string;
  done: boolean;
}

export interface PoolSwitchStatus {
  switching: boolean;
  active_pool?: string | null;
  target_pool?: string | null;
  from_pool?: string | null;
  phase: string;
  phases?: PoolSwitchPhase[];
  elapsed_sec?: number;
  estimated_pct?: number;
  estimated_label?: boolean;
  error?: string | null;
}

export interface PoolSwitchConfig {
  enabled: boolean;
  active_pool?: string | null;
}

export interface QwenModeOption {
  id: "precise" | "instruct";
  label: string;
}

interface ChatConfigResponse {
  chat_model: string;
  models: ChatModelOption[];
  qwen_modes?: QwenModeOption[];
  default_qwen_mode?: string;
  qwen_mode_supported?: boolean;
  pool_switch?: PoolSwitchConfig;
  /** Admin-editable phrases (Settings tab) cycled while the model streams a <think> block. */
  thinking_phrases?: string[];
}

export const api = {
  register(email: string, username: string, password: string) {
    return request<{ user: User; message: string }>("/auth/register", {
      method: "POST",
      body: { email, username, password },
    });
  },

  /** docs/AUTH_ACCOUNT_LIFECYCLE.md — called from the emailed /verify-email?token= link. */
  verifyEmail(token: string) {
    return request<{ ok: boolean; message: string }>("/auth/verify-email", {
      method: "POST",
      body: { token },
    });
  },

  /** docs/AUTH_ACCOUNT_LIFECYCLE.md — always returns a generic ok message. */
  resendVerification(login: string) {
    return request<{ ok: boolean; message: string }>("/auth/resend-verification", {
      method: "POST",
      body: { login },
    });
  },

  login(login: string, password: string) {
    return request<LoginResponse>("/auth/login", {
      method: "POST",
      body: { login, password },
    });
  },

  verify2FA(tempToken: string, code: string) {
    return request<{ access_token: string; refresh_token: string; user: User }>(
      "/auth/verify-2fa",
      { method: "POST", body: { temp_token: tempToken, code } },
    );
  },

  refresh(refreshToken: string) {
    return request<{ access_token: string }>("/auth/refresh", {
      method: "POST",
      body: { refresh_token: refreshToken },
    });
  },

  me(token: string) {
    return request<{ user: User }>("/auth/me", { token });
  },

  setup2FA(token: string) {
    return request<{ secret: string; provisioning_uri: string }>(
      "/auth/setup-2fa",
      { method: "POST", token },
    );
  },

  enable2FA(token: string, code: string) {
    return request<{ message: string }>("/auth/enable-2fa", {
      method: "POST",
      body: { code },
      token,
    });
  },

  changePassword(
    token: string,
    currentPassword: string,
    newPassword: string,
    newPasswordConfirm: string,
  ) {
    return request<{ ok: boolean; message: string }>("/auth/change-password", {
      method: "POST",
      body: {
        current_password: currentPassword,
        new_password: newPassword,
        new_password_confirm: newPasswordConfirm,
      },
      token,
    });
  },

  // Conversations
  listConversations(token: string) {
    return request<{ conversations: Conversation[] }>("/conversations", {
      token,
    });
  },

  createConversation(token: string, title?: string, model?: string) {
    return request<{ conversation: Conversation }>("/conversations", {
      method: "POST",
      body: { title: title ?? "New chat", ...(model ? { model } : {}) },
      token,
    });
  },

  getConversation(token: string, convId: string) {
    return request<{ conversation: Conversation; messages: Message[] }>(
      `/conversations/${convId}`,
      { token },
    );
  },

  renameConversation(token: string, convId: string, title: string) {
    return request<{ ok: boolean }>(`/conversations/${convId}`, {
      method: "PATCH",
      body: { title },
      token,
    });
  },

  deleteConversation(token: string, convId: string) {
    return request<{ ok: boolean }>(`/conversations/${convId}`, {
      method: "DELETE",
      token,
    });
  },

  editMessage(token: string, convId: string, msgId: string, content: string) {
    return request<{ messages: Message[] }>(
      `/conversations/${convId}/messages/${msgId}`,
      {
        method: "PATCH",
        body: { content },
        token,
      },
    );
  },

  // Chat (non-streaming)
  chat(
    token: string,
    messages: { role: string; content: string }[],
    conversationId?: string,
    model?: string,
  ) {
    return request<ChatResponse>("/chat", {
      method: "POST",
      body: {
        messages,
        stream: false,
        ...(conversationId ? { conversation_id: conversationId } : {}),
        ...(model ? { model } : {}),
      },
      token,
    });
  },

  // Chat (SSE streaming) — returns a ReadableStream
  async chatStream(
    token: string,
    messages: { role: string; content: string }[],
    conversationId?: string,
    model?: string,
    qwenMode?: string,
  ): Promise<Response> {
    const res = await fetch(`${BASE}/chat`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        messages,
        stream: true,
        ...(conversationId ? { conversation_id: conversationId } : {}),
        ...(model ? { model } : {}),
        ...(qwenMode ? { qwen_mode: qwenMode } : {}),
      }),
    });
    if (!res.ok) {
      const data = await res.json().catch(() => ({ detail: res.statusText }));
      throw new ApiError(
        formatApiErrorDetail(data.detail, res.statusText || "Request failed"),
        res.status,
      );
    }
    return res;
  },

  chatConfig(token: string) {
    return request<ChatConfigResponse>("/config", { token });
  },

  poolStatus(token: string) {
    return request<PoolSwitchStatus>("/admin/pool/status", { token });
  },

  poolSwitch(
    token: string,
    body: { target: "inference" | "pool35"; password: string; totp_code?: string },
  ) {
    return request<{ accepted: boolean; target: string }>("/admin/pool/switch", {
      method: "POST",
      body,
      token,
    });
  },
};
