import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { useAuth } from "../contexts/AuthContext";
import { api, ApiError, sanitizePublicError, PUBLIC_CHAT_ERROR } from "../api/client";
import type { ChatModelOption, Conversation, Message, QwenModeOption } from "../api/client";
import ChatMessage from "../components/ChatMessage";
import type { ChatTimingMeta } from "../components/ChatMessage";
import ChatInput from "../components/ChatInput";
import Sidebar from "../components/Sidebar";
import QuantumOrbLoader from "../components/QuantumOrbLoader";
import PoolSwitchModal from "../components/PoolSwitchModal";
import PoolStatusBanner from "../components/PoolStatusBanner";
import {
  ALFA_AVATAR_SRC,
  alfaHeaderStyle,
  alfaPanelStyle,
} from "../lib/alfaChatTheme";

interface LocalMessage {
  id?: string;
  role: "user" | "assistant";
  content: string;
  timing?: ChatTimingMeta;
}

function toLocalMessages(msgs: Message[]): LocalMessage[] {
  return msgs.map((m) => ({
    id: m.id,
    role: m.role as "user" | "assistant",
    content: m.content,
  }));
}

function attachTimingToLastAssistant(
  msgs: LocalMessage[],
  timing: ChatTimingMeta,
): LocalMessage[] {
  for (let i = msgs.length - 1; i >= 0; i--) {
    if (msgs[i].role === "assistant") {
      const next = [...msgs];
      next[i] = { ...next[i], timing };
      return next;
    }
  }
  return msgs;
}

const QWEN_MODE_STORAGE_KEY = "alfa-ai-qwen-mode";

function loadStoredQwenMode(): string {
  try {
    return localStorage.getItem(QWEN_MODE_STORAGE_KEY) ?? "";
  } catch {
    return "";
  }
}

function storeQwenMode(mode: string) {
  try {
    localStorage.setItem(QWEN_MODE_STORAGE_KEY, mode);
  } catch {
    /* ignore */
  }
}

export default function Chat() {
  const { user, token, logout } = useAuth();
  const [messages, setMessages] = useState<LocalMessage[]>([]);
  const [sending, setSending] = useState(false);
  const [streamContent, setStreamContent] = useState("");
  const [liveTiming, setLiveTiming] = useState<ChatTimingMeta | null>(null);
  const [model, setModel] = useState("");
  const [defaultModel, setDefaultModel] = useState("");
  const [availableModels, setAvailableModels] = useState<ChatModelOption[]>([]);
  const [qwenModes, setQwenModes] = useState<QwenModeOption[]>([]);
  const [qwenMode, setQwenMode] = useState("instruct");
  const [qwenModeSupported, setQwenModeSupported] = useState(true);
  const [thinkingPhrases, setThinkingPhrases] = useState<string[]>([]);
  const [error, setError] = useState("");
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [activeConvId, setActiveConvId] = useState<string | null>(null);
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);
  const [loadingConv, setLoadingConv] = useState(false);
  const [poolSwitchEnabled, setPoolSwitchEnabled] = useState(false);
  const [switchModal, setSwitchModal] = useState<{
    pool: "inference" | "pool35";
    label: string;
  } | null>(null);
  const [poolSwitchActive, setPoolSwitchActive] = useState(false);
  const scrollRef = useRef<HTMLDivElement>(null);

  const reloadChatConfig = useCallback(async () => {
    if (!token) return;
    try {
      const c = await api.chatConfig(token);
      setDefaultModel(c.chat_model);
      const models =
        c.models?.length
          ? c.models
          : [{ id: c.chat_model, label: c.chat_model, active: true }];
      setAvailableModels(models);
      setPoolSwitchEnabled(Boolean(c.pool_switch?.enabled));
      setModel((prev) => {
        const prevRow = models.find((m) => m.id === prev);
        if (prev && prevRow?.active !== false) return prev;
        const defaultRow = models.find((m) => m.id === c.chat_model);
        if (defaultRow?.active !== false) return c.chat_model;
        const firstActive = models.find((m) => m.active !== false);
        return firstActive?.id ?? c.chat_model;
      });
      if (c.qwen_modes?.length) {
        setQwenModes(c.qwen_modes);
      }
      setQwenModeSupported(c.qwen_mode_supported ?? true);
      setThinkingPhrases(c.thinking_phrases ?? []);
    } catch {
      /* ignore */
    }
  }, [token]);

  const loadConversations = useCallback(async () => {
    if (!token) return;
    try {
      const { conversations: convs } = await api.listConversations(token);
      setConversations(convs);
    } catch {
      /* ignore */
    }
  }, [token]);

  useEffect(() => {
    loadConversations();
  }, [loadConversations]);

  useEffect(() => {
    if (!token) return;
    api.chatConfig(token).then((c) => {
      setDefaultModel(c.chat_model);
      const models =
        c.models?.length
          ? c.models
          : [{ id: c.chat_model, label: c.chat_model, active: true }];
      setAvailableModels(models);
      setPoolSwitchEnabled(Boolean(c.pool_switch?.enabled));
      setModel((prev) => {
        const prevRow = models.find((m) => m.id === prev);
        if (prev && prevRow?.active !== false) return prev;
        const defaultRow = models.find((m) => m.id === c.chat_model);
        if (defaultRow?.active !== false) return c.chat_model;
        const firstActive = models.find((m) => m.active !== false);
        return firstActive?.id ?? c.chat_model;
      });
      if (c.qwen_modes?.length) {
        setQwenModes(c.qwen_modes);
      }
      const stored = loadStoredQwenMode();
      const fallback = c.default_qwen_mode || "instruct";
      const initial =
        stored && c.qwen_modes?.some((m) => m.id === stored) ? stored : fallback;
      setQwenMode(initial);
      setQwenModeSupported(c.qwen_mode_supported ?? true);
      setThinkingPhrases(c.thinking_phrases ?? []);
    }).catch(() => {});
  }, [token]);

  const selectedModel = availableModels.find((m) => m.id === model);
  const showActivatePool =
    user?.is_admin &&
    poolSwitchEnabled &&
    selectedModel?.pool &&
    selectedModel.active === false &&
    !poolSwitchActive;
  const showQwenMode =
    qwenModes.length > 0 &&
    (selectedModel?.qwen_mode_supported ?? qwenModeSupported);

  useEffect(() => {
    scrollRef.current?.scrollTo({
      top: scrollRef.current.scrollHeight,
      behavior: "smooth",
    });
  }, [messages, streamContent, liveTiming]);

  const runChatStream = useCallback(
    async (
      convId: string | null,
      apiMessages: { role: string; content: string }[],
    ): Promise<{ convId: string | null; timing: ChatTimingMeta | null }> => {
      if (!token) return { convId: null, timing: null };

      const t0 = performance.now();
      let ttftSec: number | null = null;
      let charCount = 0;
      let tickId: ReturnType<typeof setInterval> | null = null;

      const pushLive = () => {
        const totalSec = (performance.now() - t0) / 1000;
        setLiveTiming({
          totalSec,
          ttftSec,
          approxChars: charCount,
          live: true,
        });
      };

      pushLive();
      tickId = setInterval(pushLive, 200);

      try {
        const res = await api.chatStream(
          token,
          apiMessages,
          convId ?? undefined,
          model || undefined,
          showQwenMode ? qwenMode : undefined,
        );

        const reader = res.body?.getReader();
        if (!reader) throw new Error("No response stream");

        const decoder = new TextDecoder();
        let accumulated = "";
        let resolvedConvId = convId;
        let buffer = "";

        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split("\n");
          buffer = lines.pop() ?? "";

          for (const line of lines) {
            if (!line.startsWith("data: ")) continue;
            const raw = line.slice(6).trim();
            if (raw === "[DONE]") continue;

            try {
              const parsed = JSON.parse(raw);

              if (parsed.conversation_id && !parsed.choices) {
                resolvedConvId = parsed.conversation_id;
                if (!activeConvId) setActiveConvId(resolvedConvId);
                continue;
              }
              if (parsed.error) {
                setError(sanitizePublicError(parsed.error, 502, PUBLIC_CHAT_ERROR));
                continue;
              }

              const delta = parsed.choices?.[0]?.delta?.content ?? "";
              if (delta) {
                if (ttftSec == null) {
                  ttftSec = (performance.now() - t0) / 1000;
                }
                accumulated += delta;
                charCount = accumulated.length;
                setStreamContent(accumulated);
                pushLive();
              }
            } catch {
              /* skip unparseable chunks */
            }
          }
        }

        const totalSec = (performance.now() - t0) / 1000;
        const timing: ChatTimingMeta = {
          totalSec,
          ttftSec,
          approxChars: accumulated.length,
          live: false,
        };
        setStreamContent("");
        setLiveTiming(null);
        return { convId: resolvedConvId, timing };
      } finally {
        if (tickId) clearInterval(tickId);
      }
    },
    [token, model, qwenMode, showQwenMode, activeConvId],
  );

  const refreshMessages = useCallback(
    async (convId: string) => {
      if (!token) return;
      const { messages: msgs } = await api.getConversation(token, convId);
      setMessages(toLocalMessages(msgs));
    },
    [token],
  );

  const selectConversation = useCallback(
    async (convId: string) => {
      if (!token) return;
      setActiveConvId(convId);
      setError("");
      setStreamContent("");
      setLiveTiming(null);
      setLoadingConv(true);
      setMessages([]);
      try {
        const { conversation, messages: msgs } = await api.getConversation(token, convId);
        setModel(conversation.model || defaultModel);
        setMessages(toLocalMessages(msgs));
      } catch (err) {
        setError(err instanceof ApiError ? err.message : "Failed to load conversation");
      } finally {
        setLoadingConv(false);
      }
    },
    [token, defaultModel],
  );

  const handleNewChat = useCallback(() => {
    setActiveConvId(null);
    setMessages([]);
    setError("");
    setStreamContent("");
    setLiveTiming(null);
    if (defaultModel) setModel(defaultModel);
  }, [defaultModel]);

  const handleDelete = useCallback(
    async (convId: string) => {
      if (!token) return;
      try {
        await api.deleteConversation(token, convId);
        setConversations((prev) => prev.filter((c) => c.id !== convId));
        if (activeConvId === convId) handleNewChat();
      } catch (err) {
        setError(err instanceof ApiError ? err.message : "Failed to delete chat");
      }
    },
    [token, activeConvId, handleNewChat],
  );

  const handleRename = useCallback(
    async (convId: string, title: string) => {
      if (!token) return;
      try {
        await api.renameConversation(token, convId, title);
        setConversations((prev) =>
          prev.map((c) => (c.id === convId ? { ...c, title } : c)),
        );
      } catch {
        /* ignore */
      }
    },
    [token],
  );

  const handleSend = useCallback(
    async (text: string) => {
      if (!token) return;
      setError("");
      const userMsg: LocalMessage = { role: "user", content: text };
      const updated = [...messages, userMsg];
      setMessages(updated);
      setSending(true);
      setStreamContent("");
      setLiveTiming(null);

      const apiMessages = updated.map((m) => ({
        role: m.role,
        content: m.content,
      }));

      try {
        const { convId, timing } = await runChatStream(activeConvId, apiMessages);
        if (convId) {
          await refreshMessages(convId);
          if (timing) {
            setMessages((prev) => attachTimingToLastAssistant(prev, timing));
          }
        }
        loadConversations();
      } catch (err) {
        const status = err instanceof ApiError ? err.status : 502;
        const detail = err instanceof ApiError ? err.message : undefined;
        setError(sanitizePublicError(detail, status, PUBLIC_CHAT_ERROR));
      } finally {
        setSending(false);
        setLiveTiming(null);
      }
    },
    [token, messages, activeConvId, runChatStream, refreshMessages, loadConversations],
  );

  const handleEditMessage = useCallback(
    async (index: number, newContent: string) => {
      if (!token || !activeConvId) return;
      const msg = messages[index];
      if (!msg?.id || msg.role !== "user") return;

      setError("");
      setSending(true);
      setStreamContent("");
      setLiveTiming(null);

      try {
        const { messages: updated } = await api.editMessage(
          token,
          activeConvId,
          msg.id,
          newContent,
        );
        const local = toLocalMessages(updated);
        setMessages(local);

        const apiMessages = local.map((m) => ({
          role: m.role,
          content: m.content,
        }));
        const { timing } = await runChatStream(activeConvId, apiMessages);
        await refreshMessages(activeConvId);
        if (timing) {
          setMessages((prev) => attachTimingToLastAssistant(prev, timing));
        }
        loadConversations();
      } catch (err) {
        const status = err instanceof ApiError ? err.status : 502;
        const detail = err instanceof ApiError ? err.message : undefined;
        setError(sanitizePublicError(detail, status, PUBLIC_CHAT_ERROR));
      } finally {
        setSending(false);
        setLiveTiming(null);
      }
    },
    [token, activeConvId, messages, runChatStream, refreshMessages, loadConversations],
  );

  return (
    <div className="flex h-screen">
      <Sidebar
        conversations={conversations}
        activeId={activeConvId}
        onSelect={selectConversation}
        onNew={handleNewChat}
        onDelete={handleDelete}
        onRename={handleRename}
        collapsed={sidebarCollapsed}
        onToggle={() => setSidebarCollapsed(!sidebarCollapsed)}
      />

      <div className="flex flex-1 flex-col" style={alfaPanelStyle}>
        {user?.is_admin && poolSwitchEnabled && poolSwitchActive && token && (
          <PoolStatusBanner
            token={token}
            onReady={() => {
              setPoolSwitchActive(false);
              reloadChatConfig();
            }}
          />
        )}
        {switchModal && token && (
          <PoolSwitchModal
            targetPool={switchModal.pool}
            targetLabel={switchModal.label}
            token={token}
            requires2FA={Boolean(user?.is_2fa_enabled)}
            onClose={() => setSwitchModal(null)}
            onAccepted={() => {
              setSwitchModal(null);
              setPoolSwitchActive(true);
            }}
          />
        )}
        <header
          className="flex items-center justify-between border-b px-4 py-3"
          style={alfaHeaderStyle}
        >
          <div className="flex items-center gap-3">
            <img src={ALFA_AVATAR_SRC} alt="ALFa AI" className="h-7 w-7 rounded-full object-cover" />
            <h1 className="text-lg font-bold text-sky-400">ALFa AI</h1>
            {availableModels.length > 0 && user?.is_admin ? (
              <select
                value={model}
                onChange={(e) => setModel(e.target.value)}
                disabled={sending}
                aria-label="Chat model"
                title={selectedModel?.label ?? model}
                className="w-auto min-w-[12rem] max-w-[min(100%,28rem)] rounded-full border border-slate-700 bg-slate-800 px-2.5 py-0.5 text-xs text-slate-400 focus:outline-none focus:ring-1 focus:ring-sky-500"
              >
                {availableModels.map((m) => (
                  <option
                    key={m.id}
                    value={m.id}
                    disabled={m.active === false}
                    className={m.active === false ? "text-slate-600" : undefined}
                  >
                    {m.active === false ? `${m.label} (unavailable)` : m.label}
                  </option>
                ))}
              </select>
            ) : (
              model && (
                <span className="rounded-full bg-slate-800 px-2.5 py-0.5 text-xs text-slate-400">
                  {model}
                </span>
              )
            )}
            {showActivatePool && selectedModel?.pool && (
              <button
                type="button"
                disabled={sending || poolSwitchActive}
                onClick={() =>
                  setSwitchModal({
                    pool: selectedModel.pool as "inference" | "pool35",
                    label: selectedModel.label,
                  })
                }
                className="rounded-full border border-amber-700/60 bg-amber-950/40 px-2.5 py-0.5 text-xs text-amber-300 hover:bg-amber-900/40 disabled:opacity-50"
              >
                Activate
              </button>
            )}
            {showQwenMode && (
              <select
                value={qwenMode}
                onChange={(e) => {
                  setQwenMode(e.target.value);
                  storeQwenMode(e.target.value);
                }}
                disabled={sending}
                aria-label="Response mode"
                className="max-w-xs rounded-full border border-slate-700 bg-slate-800 px-2.5 py-0.5 text-xs text-slate-400 focus:outline-none focus:ring-1 focus:ring-sky-500"
              >
                {qwenModes.map((m) => (
                  <option key={m.id} value={m.id}>
                    {m.label}
                  </option>
                ))}
              </select>
            )}
          </div>
          <div className="flex items-center gap-3">
            <Link
              to="/about"
              className="text-xs text-slate-400 hover:text-slate-300"
            >
              About
            </Link>
            <Link
              to="/manual"
              className="text-xs text-slate-400 hover:text-slate-300"
            >
              Manual
            </Link>
            <Link
              to="/account/password"
              className="text-xs text-slate-400 hover:text-slate-300"
            >
              Password
            </Link>
            {user?.is_admin && (
              <Link
                to="/admin"
                className="rounded bg-slate-800 px-2 py-0.5 text-xs text-sky-400 hover:text-sky-300"
              >
                Admin
              </Link>
            )}
            {user && !user.is_2fa_enabled && (
              <Link
                to="/setup-2fa"
                className="text-xs text-amber-400 hover:text-amber-300"
              >
                Enable 2FA
              </Link>
            )}
            <span className="text-sm text-slate-400">{user?.username}</span>
            <button
              onClick={logout}
              className="rounded-lg border border-slate-700 px-3 py-1 text-xs text-slate-400 transition hover:border-slate-600 hover:text-slate-300"
            >
              Sign out
            </button>
          </div>
        </header>

        <div ref={scrollRef} className="flex-1 overflow-y-auto px-4 py-6">
          <div className="mx-auto max-w-3xl space-y-4">
            {loadingConv && (
              <p className="py-12 text-center text-sm text-slate-500">Loading chat…</p>
            )}
            {!loadingConv && messages.length === 0 && !streamContent && activeConvId && (
              <p className="py-12 text-center text-sm text-slate-500">
                This chat has no messages yet. Send one below, or pick another from the sidebar.
              </p>
            )}
            {!loadingConv && messages.length === 0 && !streamContent && !activeConvId && (
              <div className="flex flex-col items-center justify-center py-24 text-center">
              <img src={ALFA_AVATAR_SRC} alt="ALFa AI" className="mb-4 h-16 w-16 rounded-full object-cover" />
              <h2 className="text-xl font-semibold text-slate-300">
                How can I help you?
              </h2>
                <p className="mt-2 max-w-sm text-sm text-slate-500">
                  Ask me anything — code, system administration, data analysis,
                  or just chat.
                </p>
                <div className="mt-6 flex flex-wrap justify-center gap-2">
                  <Link
                    to="/about#platform"
                    className="rounded-full border border-slate-700 bg-slate-900/80 px-3 py-1.5 text-xs text-slate-400 transition hover:border-slate-600 hover:text-slate-200"
                  >
                    What runs this?
                  </Link>
                  <Link
                    to="/manual#chat"
                    className="rounded-full border border-slate-700 bg-slate-900/80 px-3 py-1.5 text-xs text-slate-400 transition hover:border-slate-600 hover:text-slate-200"
                  >
                    How to chat
                  </Link>
                  <Link
                    to="/about#models"
                    className="rounded-full border border-slate-700 bg-slate-900/80 px-3 py-1.5 text-xs text-slate-400 transition hover:border-slate-600 hover:text-slate-200"
                  >
                    Model tiers
                  </Link>
                  <Link
                    to="/manual"
                    className="rounded-full border border-slate-700 bg-slate-900/80 px-3 py-1.5 text-xs text-slate-400 transition hover:border-slate-600 hover:text-slate-200"
                  >
                    Users Manual
                  </Link>
                </div>
              </div>
            )}
            {messages.map((msg, i) => (
              <ChatMessage
                key={msg.id ?? `local-${i}`}
                role={msg.role}
                content={msg.content}
                editable={msg.role === "user" && Boolean(msg.id && activeConvId)}
                disabled={sending}
                onEdit={(newContent) => handleEditMessage(i, newContent)}
                thinkingPhrases={thinkingPhrases}
                timing={msg.timing}
              />
            ))}
            {streamContent && (
              <ChatMessage
                role="assistant"
                content={streamContent}
                thinkingPhrases={thinkingPhrases}
                timing={liveTiming ?? undefined}
              />
            )}
            {sending && !streamContent && (
              <div className="flex flex-col items-start gap-1">
                <div className="rounded-2xl bg-slate-800 px-4 py-2">
                  <QuantumOrbLoader />
                </div>
                {liveTiming && (
                  <p className="px-1 text-[11px] tabular-nums text-slate-500">
                    Waiting… {liveTiming.totalSec.toFixed(1)}s
                    {qwenMode === "precise" ? " (thinking)" : ""}
                  </p>
                )}
              </div>
            )}
            {error && (
              <div className="rounded-xl border border-red-800/50 bg-red-950/30 px-4 py-3 text-sm text-red-400">
                {error}
              </div>
            )}
          </div>
        </div>

        <div className="border-t px-4 py-4" style={alfaHeaderStyle}>
          <div className="mx-auto max-w-3xl">
            <ChatInput onSend={handleSend} disabled={sending} />
          </div>
        </div>
      </div>
    </div>
  );
}
