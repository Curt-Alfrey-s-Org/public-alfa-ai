import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useAuth } from "../../contexts/AuthContext";
import { ApiError } from "../../api/client";
import ChatMessage, { type ChatTimingMeta } from "../ChatMessage";
import ChatInput from "../ChatInput";
import ThinkingIndicator from "../ThinkingIndicator";
import {
  ALFA_AVATAR_SRC,
  alfaHeaderStyle,
  alfaLauncherStyle,
  alfaPanelStyle,
} from "../../lib/alfaChatTheme";
import { ASK_ALFA_SUGGESTED_PROMPTS } from "../../lib/askAlfaSuggestedPrompts";
import {
  MAX_QUEUED_TURNS,
  dequeueFollowUp,
  enqueueFollowUp,
} from "../../lib/askAlfaTurnQueue";
import {
  type InspectionStep,
  type ReadinessBlock,
  InspectionStepsBlock,
  LiveInspectionLines,
  ReadinessBlockCard,
} from "./InspectionSteps";
import ContextUsageRing, { type ContextUsage } from "./ContextUsageRing";
import {
  AppliedSettingCard,
  CursorHandoffCard,
  HostActionApproveCard,
  HostActionResultCard,
  MissionNavigationCard,
  SettingApproveCard,
} from "./AskAlfaCards";
import type {
  AgentMessage,
  ChatSession,
  HistoryTurn,
  HostActionRecord,
  MissionNavigationHint,
  MonitoringAgentResponse,
  SettingProposal,
} from "./askAlfaTypes";

const BASE = "/alfa-ai/api/admin";
const SESSION_STORAGE_KEY = "alfa-achange-me";
const MAX_SESSIONS = 6;
const MAX_CONCURRENT_BUSY = 3;
/** Caller-managed turns for POST /monitoring-agent/stream (OpenAI-style messages). */
const MAX_HISTORY_ITEMS = 8;
const MAX_HISTORY_CONTENT_CHARS = 2000;

const DEFAULT_THINKING_PHRASES = [
  "Working on it...",
  "Still working...",
  "Checking cluster context...",
];

function newSessionId(): string {
  return `s-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

function createSession(title?: string): ChatSession {
  return {
    id: newSessionId(),
    title: title ?? "Session 1",
    messages: [],
    pendingQueue: [],
    busy: false,
    busyStartedAt: null,
    streamHint: null,
    liveInspections: [],
  };
}

function thinkingPhrasesFromSetting(raw: string): string[] {
  if (!raw.trim()) return [];
  return raw.split("|").map((p) => p.trim()).filter(Boolean);
}

function formatApiDetail(detail: unknown): string {
  if (typeof detail === "string") return detail;
  if (Array.isArray(detail)) {
    return detail
      .map((item) => {
        if (item && typeof item === "object" && "msg" in item) {
          return String((item as { msg: string }).msg);
        }
        return JSON.stringify(item);
      })
      .join("; ");
  }
  if (detail && typeof detail === "object") return JSON.stringify(detail);
  return "Request failed";
}

/** Unwrap model JSON envelope so the bubble shows plain reply text (E9). */
function unescapeJsonStringValue(raw: string): string {
  let out = "";
  for (let i = 0; i < raw.length; i += 1) {
    const ch = raw[i];
    if (ch === "\\" && i + 1 < raw.length) {
      const nxt = raw[i + 1];
      if (nxt === "n") out += "\n";
      else if (nxt === "t") out += "\t";
      else if (nxt === "r") out += "\r";
      else if (nxt === '"' || nxt === "\\" || nxt === "/") out += nxt;
      else out += ch + nxt;
      i += 1;
      continue;
    }
    out += ch;
  }
  return out;
}

// Tolerate any whitespace/newlines a pretty-printed envelope puts around the
// comma, so the salvaged prose can never swallow a following key.
const REPLY_ENVELOPE_TERMINATOR_RE =
  /"\s*,\s*"(?:setting_change|host_action_id|tool|args)"\s*:/;
const REPLY_ENVELOPE_END_RE = /"\s*\}\s*$/;

function salvageReplyFromEnvelope(text: string): string | null {
  const keyMatch = text.match(/"reply"\s*:\s*"/);
  if (!keyMatch || keyMatch.index === undefined) return null;
  const start = keyMatch.index + keyMatch[0].length;
  const rest = text.slice(start);

  const terminator = rest.match(REPLY_ENVELOPE_TERMINATOR_RE);
  let end: number;
  if (terminator && terminator.index !== undefined) {
    end = terminator.index;
  } else {
    // No structural terminator: only trust an explicit envelope close. Guessing
    // at the last quote leaks the trailing keys into operator-visible prose.
    const envelopeEnd = rest.match(REPLY_ENVELOPE_END_RE);
    if (!envelopeEnd || envelopeEnd.index === undefined) return null;
    end = envelopeEnd.index;
  }
  return unescapeJsonStringValue(rest.slice(0, end));
}

function normalizeReply(raw: string): string {
  const text = (raw || "").trim();
  if (!text.startsWith("{")) return raw;
  try {
    const parsed = JSON.parse(text) as { reply?: unknown };
    if (typeof parsed.reply === "string") return parsed.reply;
    // Valid JSON with no string `reply` is not our envelope - the server already
    // unwrapped it, so this is content the operator asked for. Show it verbatim.
    return raw;
  } catch {
    /* strict parse failed; try tolerant salvage */
  }
  const salvaged = salvageReplyFromEnvelope(text);
  if (salvaged !== null) return salvaged;
  // Salvage only fails when there is no `"reply":` key at all, which means this
  // was never an envelope. Returning raw beats destroying legitimate content;
  // the server is the layer that guarantees no envelope reaches the operator.
  return raw;
}

function titleFromQuestion(question: string, fallback: string): string {
  const cleaned = question.replace(/\s+/g, " ").trim();
  if (!cleaned) return fallback;
  return cleaned.length > 28 ? `${cleaned.slice(0, 28)}...` : cleaned;
}

function clipHistoryContent(content: string): string {
  const trimmed = (content || "").trim();
  if (!trimmed) return "";
  return trimmed.length > MAX_HISTORY_CONTENT_CHARS
    ? trimmed.slice(0, MAX_HISTORY_CONTENT_CHARS)
    : trimmed;
}

/** Last qualifying on-screen turns before `currentMessage` (sent separately as `message`). */
function buildMonitoringAgentHistory(
  messages: AgentMessage[],
  currentMessage: string,
): HistoryTurn[] {
  const currentClipped = clipHistoryContent(currentMessage);
  const qualifying: HistoryTurn[] = [];

  for (const m of messages) {
    if (m.queued) continue;
    if (m.role !== "user" && m.role !== "assistant") continue;
    const clipped = clipHistoryContent(m.content);
    if (!clipped) continue;
    qualifying.push({ role: m.role, content: clipped });
  }

  // Current question is `message`; do not duplicate in history (FIFO drain or fresh send).
  if (currentClipped) {
    for (let i = qualifying.length - 1; i >= 0; i -= 1) {
      if (qualifying[i].role === "user" && qualifying[i].content === currentClipped) {
        qualifying.splice(i, 1);
        break;
      }
    }
  }

  return qualifying.slice(-MAX_HISTORY_ITEMS);
}

function lastPendingIndex(
  messages: ChatSession["messages"],
  kind: "host" | "setting",
): number {
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const row = messages[i];
    if (kind === "host" && row.hostActionProposal?.status === "pending") return i;
    if (kind === "setting" && row.pendingSettingProposal?.status === "pending") return i;
  }
  return -1;
}

type StreamEvent = {
  type?: string;
  message?: string;
  elapsed_sec?: number;
  detail?: string;
  reply?: string;
  applied_setting?: MonitoringAgentResponse["applied_setting"];
  pending_setting_proposal?: MonitoringAgentResponse["pending_setting_proposal"];
  host_action_proposal?: MonitoringAgentResponse["host_action_proposal"];
  cursor_handoff?: string | null;
  step?: InspectionStep;
  inspections?: InspectionStep[];
  readiness_block?: ReadinessBlock | null;
  context_usage?: ContextUsage | null;
};

async function apiFetch<T>(path: string, token: string, opts?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    ...opts,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...opts?.headers },
  });
  if (!res.ok) {
    const d = await res.json().catch(() => ({ detail: res.statusText }));
    throw new ApiError(formatApiDetail(d.detail ?? d.message ?? res.statusText), res.status);
  }
  return res.json();
}

function isAbortError(err: unknown): boolean {
  if (!err || typeof err !== "object") return false;
  const name = (err as { name?: string }).name;
  return name === "AbortError" || name === "TimeoutError";
}

async function monitoringAgentStream(
  token: string,
  message: string,
  history: HistoryTurn[],
  onEvent: (event: StreamEvent) => void,
  signal?: AbortSignal,
): Promise<MonitoringAgentResponse> {
  const res = await fetch(`${BASE}/monitoring-agent/stream`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      Accept: "text/event-stream",
    },
    body: JSON.stringify({ message, history }),
    signal,
  });
  if (!res.ok) {
    const d = await res.json().catch(() => ({ detail: res.statusText }));
    throw new ApiError(formatApiDetail(d.detail ?? d.message ?? res.statusText), res.status);
  }

  const reader = res.body?.getReader();
  if (!reader) throw new ApiError("No response stream", 502);

  const onAbort = () => {
    void reader.cancel().catch(() => undefined);
  };
  if (signal) {
    if (signal.aborted) {
      onAbort();
      throw new DOMException("Aborted", "AbortError");
    }
    signal.addEventListener("abort", onAbort, { once: true });
  }

  const decoder = new TextDecoder();
  let buffer = "";
  let donePayload: MonitoringAgentResponse | null = null;
  let streamError: string | null = null;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) {
        if (!line.startsWith("data: ")) continue;
        const raw = line.slice(6).trim();
        if (!raw) continue;
        try {
          const event = JSON.parse(raw) as StreamEvent;
          onEvent(event);
          if (event.type === "error") {
            streamError = event.detail ?? "Ask ALFa failed";
          } else if (event.type === "done" && event.reply !== undefined) {
            donePayload = {
              reply: event.reply,
              applied_setting: event.applied_setting ?? null,
              pending_setting_proposal: event.pending_setting_proposal ?? null,
              host_action_proposal: event.host_action_proposal ?? null,
              cursor_handoff: event.cursor_handoff ?? null,
              inspections: event.inspections,
              readiness_block: event.readiness_block ?? null,
              context_usage: event.context_usage ?? null,
            };
          }
        } catch {
          /* ignore malformed chunks */
        }
      }
    }
  } finally {
    if (signal) signal.removeEventListener("abort", onAbort);
  }

  if (signal?.aborted) {
    throw new DOMException("Aborted", "AbortError");
  }
  if (streamError) throw new ApiError(streamError, 502);
  if (!donePayload) throw new ApiError("Ask ALFa ended without a reply", 502);
  return donePayload;
}

function buildReplyTiming(
  t0: number,
  ttftSec: number | null,
  content: string,
): ChatTimingMeta {
  return {
    totalSec: (performance.now() - t0) / 1000,
    ttftSec,
    approxChars: content.length,
    live: false,
  };
}

function loadStoredSessions(): { sessions: ChatSession[]; activeId: string } | null {
  try {
    const raw = sessionStorage.getItem(SESSION_STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as { sessions?: ChatSession[]; activeId?: string };
    if (!Array.isArray(parsed.sessions) || parsed.sessions.length === 0) return null;
    const sessions = parsed.sessions.map((s) => ({
      ...s,
      busy: false,
      busyStartedAt: null,
      streamHint: null,
      liveInspections: [],
      pendingQueue: [],
      messages: (Array.isArray(s.messages) ? s.messages : []).filter((m) => !m.queued),
    }));
    const activeId =
      sessions.find((s) => s.id === parsed.activeId)?.id ?? sessions[0].id;
    return { sessions, activeId };
  } catch {
    return null;
  }
}

/**
 * Global "Ask ALFa" admin dock. Chat chrome is shared brain SPA primitives
 * (ChatMessage, ChatInput, alfaChatTheme). Approve/result cards live in
 * AskAlfaCards.tsx. Do not mount @alfa-ai/chat-widget here -- that package
 * is consumer /api/ai-narrative, not monitoring-agent.
 * Map: docs/ALFA_AI_CHAT_WIDGETS.md "Ask ALFa admin dock".
 */
export default function AskAlfaWidget() {
  const { token } = useAuth();
  const [panelOpen, setPanelOpen] = useState(false);
  const [fullscreen, setFullscreen] = useState(false);
  const [thinkingPhrases, setThinkingPhrases] = useState<string[]>(DEFAULT_THINKING_PHRASES);
  const [actionBusy, setActionBusy] = useState<string | null>(null);
  const [tier2Ack, setTier2Ack] = useState<Record<string, boolean>>({});
  const [handoffCopied, setHandoffCopied] = useState<Record<string, boolean>>({});
  const [botAuditCopied, setBotAuditCopied] = useState<Record<string, boolean>>({});
  const [contextUsage, setContextUsage] = useState<ContextUsage | null>(null);
  const [tick, setTick] = useState(0);
  const stored = useRef(loadStoredSessions());
  const initial = stored.current ?? {
    sessions: [createSession("Session 1")],
    activeId: "",
  };
  if (!initial.activeId) initial.activeId = initial.sessions[0].id;
  const [sessions, setSessions] = useState<ChatSession[]>(initial.sessions);
  const [activeId, setActiveId] = useState(initial.activeId);
  const sessionsRef = useRef(sessions);
  sessionsRef.current = sessions;
  const bottomRef = useRef<HTMLDivElement>(null);
  const sessionSeq = useRef(initial.sessions.length);
  /** In-flight SSE AbortControllers keyed by session id. */
  const abortBySession = useRef<Map<string, AbortController>>(new Map());
  /** Per-session stream timing (performance.now() t0 + ttftSec) while busy. */
  const streamTimingRef = useRef<Map<string, { t0: number; ttftSec: number | null }>>(
    new Map(),
  );

  const active = sessions.find((s) => s.id === activeId) ?? sessions[0];
  const busyCount = sessions.filter((s) => s.busy).length;
  const activeElapsed =
    active?.busy && active.busyStartedAt
      ? Math.floor((Date.now() - active.busyStartedAt) / 1000)
      : 0;

  useEffect(() => {
    try {
      sessionStorage.setItem(
        SESSION_STORAGE_KEY,
        JSON.stringify({
          activeId,
          sessions: sessions.map((s) => ({
            id: s.id,
            title: s.title,
            messages: s.messages.filter((m) => !m.queued),
            pendingQueue: [],
            busy: false,
            busyStartedAt: null,
            streamHint: null,
            liveInspections: [],
          })),
        }),
      );
    } catch {
      /* ignore quota */
    }
  }, [sessions, activeId]);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({
      behavior: active?.busy ? "auto" : "smooth",
    });
  }, [active?.messages, active?.busy, activeElapsed, tick, activeId]);

  useEffect(() => {
    if (!panelOpen || !token) return;
    let cancelled = false;
    apiFetch<{ context_usage: ContextUsage }>("/ask-alfa/context-usage", token)
      .then((data) => {
        if (!cancelled && data.context_usage) {
          setContextUsage(data.context_usage);
        }
      })
      .catch(() => {
        /* ring is optional UX */
      });
    return () => {
      cancelled = true;
    };
  }, [panelOpen, token]);

  useEffect(() => {
    if (!panelOpen || !token) return;
    let cancelled = false;
    apiFetch<{ settings: { key: string; value: string }[] }>("/ai-settings", token)
      .then((data) => {
        if (cancelled) return;
        const row = data.settings.find((s) => s.key === "chat_thinking_label");
        const phrases = thinkingPhrasesFromSetting(row?.value ?? "");
        setThinkingPhrases(phrases.length > 0 ? phrases : DEFAULT_THINKING_PHRASES);
      })
      .catch(() => {
        if (!cancelled) setThinkingPhrases(DEFAULT_THINKING_PHRASES);
      });
    return () => {
      cancelled = true;
    };
  }, [panelOpen, token]);

  useEffect(() => {
    return () => {
      // Panel unmount / hard leave: abort all in-flight Ask ALFa streams.
      abortBySession.current.forEach((c) => c.abort());
      abortBySession.current.clear();
    };
  }, []);

  useEffect(() => {
    if (!sessions.some((s) => s.busy)) return;
    const id = window.setInterval(() => setTick((n) => n + 1), 1000);
    return () => window.clearInterval(id);
  }, [sessions]);

  useEffect(() => {
    if (!fullscreen) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setFullscreen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [fullscreen]);

  if (!token) return null;

  function patchSession(sessionId: string, patch: (s: ChatSession) => ChatSession) {
    setSessions((prev) => prev.map((s) => (s.id === sessionId ? patch(s) : s)));
  }

  function addSession() {
    if (sessions.length >= MAX_SESSIONS) return;
    sessionSeq.current += 1;
    const s = createSession(`Session ${sessionSeq.current}`);
    setSessions((prev) => [...prev, s]);
    setActiveId(s.id);
  }

  function abortSession(sessionId: string) {
    const ctrl = abortBySession.current.get(sessionId);
    if (ctrl) {
      ctrl.abort();
      abortBySession.current.delete(sessionId);
    }
  }

  function stopActive() {
    if (!active?.busy) return;
    abortSession(active.id);
  }

  function closeSession(sessionId: string) {
    if (sessions.length <= 1) return;
    const target = sessions.find((s) => s.id === sessionId);
    if (target?.busy) {
      // Plan: abort then close so soft-cap frees immediately.
      abortSession(sessionId);
    }
    const next = sessions.filter((s) => s.id !== sessionId);
    setSessions(next);
    if (activeId === sessionId) setActiveId(next[0].id);
  }

  /** Drain FIFO after a turn. Read latest sessions via ref (not setState side effects).
   * https://react.dev/reference/react/useRef
   */
  function tryDrainQueue(sessionId: string) {
    const current = sessionsRef.current.find((s) => s.id === sessionId);
    if (!current) return;
    const { next } = dequeueFollowUp(current.pendingQueue);
    if (!next) return;
    patchSession(sessionId, (s) => {
      const { next: n, rest } = dequeueFollowUp(s.pendingQueue);
      if (!n) return s;
      return {
        ...s,
        pendingQueue: rest,
        messages: s.messages.map((m) =>
          m.queueId === n.id ? { ...m, queued: false } : m,
        ),
      };
    });
    void runTurn(sessionId, next.content, { fromQueue: true });
  }

  async function runTurn(
    sessionId: string,
    question: string,
    opts?: { fromQueue?: boolean },
  ) {
    if (!token) return;

    const priorMessages =
      sessionsRef.current.find((s) => s.id === sessionId)?.messages ?? [];
    const history = buildMonitoringAgentHistory(priorMessages, question);

    const controller = new AbortController();
    abortBySession.current.set(sessionId, controller);

    const t0 = performance.now();
    const timingState = { t0, ttftSec: null as number | null };
    streamTimingRef.current.set(sessionId, timingState);

    if (opts?.fromQueue) {
      patchSession(sessionId, (s) => ({
        ...s,
        title:
          s.messages.filter((m) => m.role === "user").length <= 1
            ? titleFromQuestion(question, s.title)
            : s.title,
        busy: true,
        busyStartedAt: Date.now(),
        streamHint: null,
        liveInspections: [],
      }));
    } else {
      patchSession(sessionId, (s) => ({
        ...s,
        title:
          s.messages.length === 0
            ? titleFromQuestion(question, s.title)
            : s.title,
        busy: true,
        busyStartedAt: Date.now(),
        streamHint: null,
        liveInspections: [],
        messages: [...s.messages, { role: "user", content: question }],
      }));
    }

    try {
      // Parse done payload inside monitoringAgentStream (same function as the
      // SSE reader) so TypeScript CFA does not collapse it to `never` after a
      // callback-only assignment (strict Docker `tsc` / npm run build).
      const data = await monitoringAgentStream(
        token,
        question,
        history,
        (event) => {
          if (event.type === "status" || event.type === "heartbeat") {
            if (timingState.ttftSec === null) {
              timingState.ttftSec = (performance.now() - t0) / 1000;
            }
          }
          if (event.type === "status" && event.message) {
            patchSession(sessionId, (s) => ({ ...s, streamHint: event.message ?? null }));
          } else if (event.type === "heartbeat") {
            const sec = event.elapsed_sec ?? 0;
            patchSession(sessionId, (s) => ({
              ...s,
              streamHint: `Still working on frontier-code... (${sec}s)`,
            }));
          } else if (event.type === "inspect" && event.step) {
            patchSession(sessionId, (s) => ({
              ...s,
              liveInspections: [...s.liveInspections, event.step as InspectionStep],
            }));
          }
        },
        controller.signal,
      );

      const replyText = normalizeReply(data.reply);
      if (data.context_usage) {
        setContextUsage(data.context_usage);
      }
      patchSession(sessionId, (s) => ({
        ...s,
        busy: false,
        busyStartedAt: null,
        streamHint: null,
        liveInspections: [],
        messages: [
          ...s.messages,
          {
            role: "assistant",
            content: replyText,
            timing: buildReplyTiming(t0, timingState.ttftSec, replyText),
            appliedSetting: data.applied_setting,
            pendingSettingProposal: data.pending_setting_proposal,
            hostActionProposal: data.host_action_proposal,
            cursorHandoff: data.cursor_handoff ?? null,
            inspections:
              data.inspections ??
              (s.liveInspections.length > 0 ? s.liveInspections : undefined),
            readinessBlock: data.readiness_block ?? null,
          },
        ],
      }));
    } catch (err) {
      if (isAbortError(err)) {
        const cancelText = "Cancelled.";
        patchSession(sessionId, (s) => ({
          ...s,
          busy: false,
          busyStartedAt: null,
          streamHint: null,
          liveInspections: [],
          messages: [
            ...s.messages,
            {
              role: "assistant",
              content: cancelText,
              timing: buildReplyTiming(t0, timingState.ttftSec, cancelText),
            },
          ],
        }));
      } else {
        const msg = err instanceof ApiError ? err.message : "Ask ALFa failed";
        const errorText = `Error: ${msg}`;
        patchSession(sessionId, (s) => ({
          ...s,
          busy: false,
          busyStartedAt: null,
          streamHint: null,
          liveInspections: [],
          messages: [
            ...s.messages,
            {
              role: "assistant",
              content: errorText,
              timing: buildReplyTiming(t0, timingState.ttftSec, errorText),
            },
          ],
        }));
      }
    } finally {
      streamTimingRef.current.delete(sessionId);
      abortBySession.current.delete(sessionId);
      tryDrainQueue(sessionId);
    }
  }

  function send(question: string) {
    if (!token || !question.trim() || !active) return;

    if (active.busy) {
      patchSession(active.id, (s) => {
        const { queue, rejected } = enqueueFollowUp(s.pendingQueue, question);
        if (rejected === "full") {
          return {
            ...s,
            messages: [
              ...s.messages,
              {
                role: "assistant",
                content: `Queue full (max ${MAX_QUEUED_TURNS} follow-ups). Wait for the current turn to finish.`,
              },
            ],
          };
        }
        if (rejected === "empty") return s;
        const enqueued = queue[queue.length - 1];
        return {
          ...s,
          pendingQueue: queue,
          messages: [
            ...s.messages,
            {
              role: "user",
              content: enqueued.content,
              queued: true,
              queueId: enqueued.id,
            },
          ],
        };
      });
      return;
    }

    if (busyCount >= MAX_CONCURRENT_BUSY) {
      patchSession(active.id, (s) => ({
        ...s,
        messages: [
          ...s.messages,
          {
            role: "assistant",
            content: `Too many sessions waiting on the model (max ${MAX_CONCURRENT_BUSY}). Wait for one to finish, or open a new tab only for instant catalog proposes.`,
          },
        ],
      }));
      return;
    }

    void runTurn(active.id, question.trim());
  }

  async function reviewHostAction(actionId: string, approve: boolean, messageIndex: number) {
    if (!token || actionBusy || !active) return;
    const proposal = active.messages[messageIndex]?.hostActionProposal;
    if (approve && proposal && (proposal.risk_tier ?? 1) >= 2 && !tier2Ack[actionId]) {
      patchSession(active.id, (s) => ({
        ...s,
        messages: [
          ...s.messages,
          {
            role: "assistant",
            content: "Check the confirmation box before approving mutating or destructive host actions.",
          },
        ],
      }));
      return;
    }
    const sessionId = active.id;
    setActionBusy(actionId);
    try {
      const path = approve
        ? `/host-actions/${actionId}/approve`
        : `/host-actions/${actionId}/reject`;
      const body =
        approve && proposal && (proposal.risk_tier ?? 1) >= 2
          ? JSON.stringify({ ack_tier: 2 })
          : undefined;
      const data = await apiFetch<{ action: HostActionRecord; navigation_hint?: MissionNavigationHint }>(
        path,
        token,
        {
          method: "POST",
          body,
        },
      );
      patchSession(sessionId, (s) => ({
        ...s,
        messages: s.messages.map((m, i) =>
          i === messageIndex
            ? {
                ...m,
                hostActionProposal: null,
                hostActionResult: data.action,
                navigationHint: data.navigation_hint ?? null,
              }
            : m,
        ),
      }));
      setTier2Ack((prev) => {
        const next = { ...prev };
        delete next[actionId];
        return next;
      });
    } catch (err) {
      const msg = err instanceof ApiError ? err.message : "Host action failed";
      patchSession(sessionId, (s) => ({
        ...s,
        messages: [...s.messages, { role: "assistant", content: `Host action error: ${msg}` }],
      }));
    } finally {
      setActionBusy(null);
    }
  }

  async function hostActionFeedback(actionId: string, helpful: boolean) {
    if (!token || actionBusy || !active) return;
    const sessionId = active.id;
    setActionBusy(actionId);
    try {
      await apiFetch(`/host-actions/${actionId}/feedback`, token, {
        method: "POST",
        body: JSON.stringify({ helpful }),
      });
    } catch (err) {
      const msg = err instanceof ApiError ? err.message : "Feedback failed";
      patchSession(sessionId, (s) => ({
        ...s,
        messages: [...s.messages, { role: "assistant", content: `Feedback error: ${msg}` }],
      }));
    } finally {
      setActionBusy(null);
    }
  }

  async function reviewSettingProposal(proposalId: string, approve: boolean, messageIndex: number) {
    if (!token || actionBusy || !active) return;
    const sessionId = active.id;
    setActionBusy(proposalId);
    try {
      const path = approve
        ? `/ai-settings/proposals/${proposalId}/approve`
        : `/ai-settings/proposals/${proposalId}/reject`;
      const data = await apiFetch<{
        setting?: { key: string; value: string; description?: string };
        proposal?: SettingProposal;
      }>(path, token, {
        method: "POST",
        body: approve ? JSON.stringify({ confirm: true }) : undefined,
      });
      patchSession(sessionId, (s) => ({
        ...s,
        messages: s.messages.map((m, i) => {
          if (i !== messageIndex) return m;
          if (approve && data.setting) {
            return {
              ...m,
              pendingSettingProposal: null,
              appliedSetting: {
                key: data.setting.key,
                old_value: m.pendingSettingProposal?.old_value ?? "",
                new_value: data.setting.value,
                description:
                  data.setting.description ?? m.pendingSettingProposal?.description,
              },
            };
          }
          return { ...m, pendingSettingProposal: null };
        }),
      }));
    } catch (err) {
      const msg = err instanceof ApiError ? err.message : "Setting proposal failed";
      patchSession(sessionId, (s) => ({
        ...s,
        messages: [...s.messages, { role: "assistant", content: `Setting error: ${msg}` }],
      }));
    } finally {
      setActionBusy(null);
    }
  }

  const onClose = () => (fullscreen ? setFullscreen(false) : setPanelOpen(false));
  const messages = active?.messages ?? [];
  const busy = !!active?.busy;
  const atSessionLlmCap = busyCount >= MAX_CONCURRENT_BUSY && !busy;
  const queueLen = active?.pendingQueue?.length ?? 0;
  const pendingHostIdx = lastPendingIndex(messages, "host");
  const pendingSettingIdx = lastPendingIndex(messages, "setting");
  const pendingHost = pendingHostIdx >= 0 ? messages[pendingHostIdx].hostActionProposal : null;
  const pendingSetting =
    pendingSettingIdx >= 0 ? messages[pendingSettingIdx].pendingSettingProposal : null;

  const chrome = (
    <>
      <div className="flex items-center gap-3 border-b px-3 py-2.5 shrink-0" style={alfaHeaderStyle}>
        <img
          src={ALFA_AVATAR_SRC}
          alt="ALFa AI"
          className="h-7 w-7 shrink-0 rounded-full object-cover"
        />
        <div className="min-w-0 flex-1">
          <span className="text-sm font-bold text-sky-400">ALFa AI</span>
          <div className="text-[11px] text-slate-400 leading-snug truncate">
            Admin console -- full cluster visibility, no other bot data
          </div>
        </div>
        <div className="flex items-center gap-0.5 shrink-0">
          {!fullscreen && (
            <button
              type="button"
              onClick={() => setFullscreen(true)}
              className="rounded-lg p-2 text-slate-300 hover:bg-white/10 hover:text-white"
              title="Full screen"
              aria-label="Full screen"
            >
              &#x26F6;
            </button>
          )}
          <button
            type="button"
            onClick={onClose}
            className="rounded-lg p-2 text-slate-300 hover:bg-white/10 hover:text-white"
            aria-label="Close ALFa AI"
          >
            &#x2715;
          </button>
        </div>
      </div>

      <div className="flex items-center gap-1 border-b border-slate-700/60 px-2 py-1.5 shrink-0 overflow-x-auto">
        {sessions.map((s) => {
          const selected = s.id === active?.id;
          return (
            <div
              key={s.id}
              className={`group flex max-w-[9rem] items-center gap-0.5 rounded-md border px-1.5 py-0.5 text-[11px] ${
                selected
                  ? "border-sky-700 bg-sky-950/50 text-sky-300"
                  : "border-transparent bg-slate-900/60 text-slate-400 hover:border-slate-700"
              }`}
            >
              <button
                type="button"
                onClick={() => setActiveId(s.id)}
                className="min-w-0 truncate text-left"
                title={s.title}
              >
                {s.busy ? `(${Math.floor((Date.now() - (s.busyStartedAt ?? Date.now())) / 1000)}s) ` : ""}
                {s.title}
              </button>
              {sessions.length > 1 && (
                <button
                  type="button"
                  onClick={() => closeSession(s.id)}
                  className="shrink-0 rounded px-0.5 text-slate-500 hover:text-slate-200"
                  aria-label={s.busy ? `Stop and close ${s.title}` : `Close ${s.title}`}
                  title={s.busy ? "Stop and close session" : "Close session"}
                >
                  &#x2715;
                </button>
              )}
            </div>
          );
        })}
        <button
          type="button"
          onClick={addSession}
          disabled={sessions.length >= MAX_SESSIONS}
          className="ml-0.5 rounded-md border border-dashed border-slate-600 px-2 py-0.5 text-[11px] text-slate-400 hover:border-sky-700 hover:text-sky-300 disabled:opacity-40"
          title={`New session (max ${MAX_SESSIONS})`}
          aria-label="New session"
        >
          +
        </button>
      </div>

      <div className="flex-1 overflow-hidden px-3 py-2 min-h-0 flex flex-col select-text">
        <div className="flex-1 overflow-y-auto min-h-0 px-1 py-2">
          <div className="space-y-4">
            {messages.length === 0 && !busy && (
              <div className="flex flex-col items-center justify-center py-8 text-center">
                <img
                  src={ALFA_AVATAR_SRC}
                  alt="ALFa AI"
                  className="mb-3 h-12 w-12 rounded-full object-cover"
                />
                <h2 className="text-base font-semibold text-slate-200">How can I help you?</h2>
                <p className="mt-2 max-w-xs text-xs text-slate-400 leading-relaxed">
                  Ask in plain language. If something needs to run, Approve / Reject appear
                  above the message box -- not buried under a long reply.
                </p>
                <div className="mt-4 flex max-w-md flex-wrap justify-center gap-1.5">
                  {ASK_ALFA_SUGGESTED_PROMPTS.map((prompt) => (
                    <button
                      key={prompt}
                      type="button"
                      onClick={() => send(prompt)}
                      className="rounded-full border border-slate-700 bg-slate-900/80 px-2.5 py-1 text-[10px] text-slate-300 hover:border-sky-700 hover:text-sky-300"
                    >
                      {prompt}
                    </button>
                  ))}
                </div>
              </div>
            )}

            {messages.map((m, i) => (
              <div key={i}>
                {m.role === "assistant" && m.inspections && m.inspections.length > 0 && (
                  <InspectionStepsBlock inspections={m.inspections} />
                )}
                {m.role === "assistant" && m.readinessBlock && (
                  <ReadinessBlockCard block={m.readinessBlock} />
                )}
                <ChatMessage
                  role={m.role}
                  content={m.content}
                  timing={m.timing}
                  scrollBody={m.role === "assistant"}
                />
                {m.role === "user" && m.queued && (
                  <p className="ml-11 mt-0.5 text-[10px] uppercase tracking-wide text-slate-500">
                    Queued
                  </p>
                )}

                {m.appliedSetting && <AppliedSettingCard setting={m.appliedSetting} />}

                {m.pendingSettingProposal && m.pendingSettingProposal.status === "pending" && (
                  <p className="ml-11 mt-1 text-[11px] text-amber-400/90">
                    Policy setting pending -- Approve or Reject above the message box.
                  </p>
                )}

                {m.hostActionProposal && m.hostActionProposal.status === "pending" && (
                  <p className="ml-11 mt-1 text-[11px] text-amber-400/90">
                    Host action pending -- Approve or Reject above the message box.
                  </p>
                )}

                {m.cursorHandoff && (
                  <CursorHandoffCard
                    text={m.cursorHandoff}
                    copied={!!handoffCopied[`${i}`]}
                    onCopy={() => {
                      void (async () => {
                        try {
                          await navigator.clipboard.writeText(m.cursorHandoff || "");
                          setHandoffCopied((prev) => ({ ...prev, [`${i}`]: true }));
                          window.setTimeout(() => {
                            setHandoffCopied((prev) => {
                              const next = { ...prev };
                              delete next[`${i}`];
                              return next;
                            });
                          }, 2000);
                        } catch {
                          /* clipboard may be blocked */
                        }
                      })();
                    }}
                  />
                )}

                {m.hostActionResult && (
                  <HostActionResultCard
                    result={m.hostActionResult}
                    actionBusy={actionBusy}
                    auditCopied={!!botAuditCopied[`${i}`]}
                    onCopyAudit={() => {
                      void (async () => {
                        try {
                          await navigator.clipboard.writeText(
                            m.hostActionResult?.bot_audit_excerpt || "",
                          );
                          setBotAuditCopied((prev) => ({ ...prev, [`${i}`]: true }));
                          window.setTimeout(() => {
                            setBotAuditCopied((prev) => {
                              const next = { ...prev };
                              delete next[`${i}`];
                              return next;
                            });
                          }, 2000);
                        } catch {
                          /* clipboard may be blocked */
                        }
                      })();
                    }}
                    onFeedback={(helpful) => hostActionFeedback(m.hostActionResult!.id, helpful)}
                  />
                )}

                {m.navigationHint && <MissionNavigationCard hint={m.navigationHint} />}
              </div>
            ))}

            {busy && (
              <div className="flex justify-start pl-11">
                <div className="rounded-2xl bg-slate-800 px-4 py-2 flex flex-col gap-1 min-w-[10rem]">
                  {active?.streamHint ? (
                    <span className="text-sm text-slate-300">{active.streamHint}</span>
                  ) : (
                    <ThinkingIndicator phrases={thinkingPhrases} />
                  )}
                  {active?.liveInspections && active.liveInspections.length > 0 && (
                    <LiveInspectionLines steps={active.liveInspections} />
                  )}
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-[11px] tabular-nums text-slate-500">{activeElapsed}s</span>
                    <button
                      type="button"
                      onClick={stopActive}
                      className="rounded border border-slate-600 px-2 py-0.5 text-[11px] text-slate-300 hover:border-amber-600 hover:text-amber-300"
                      title="Stop this turn (frees soft-cap slot)"
                    >
                      Stop
                    </button>
                  </div>
                </div>
              </div>
            )}

            <div ref={bottomRef} />
          </div>
        </div>

        <div className="shrink-0 border-t border-slate-700/60 pt-3 mt-2 space-y-2">
          {pendingSetting && pendingSettingIdx >= 0 && (
            <SettingApproveCard
              proposal={pendingSetting}
              messageIndex={pendingSettingIdx}
              actionBusy={actionBusy}
              onReview={reviewSettingProposal}
            />
          )}
          {pendingHost && pendingHostIdx >= 0 && (
            <HostActionApproveCard
              proposal={pendingHost}
              messageIndex={pendingHostIdx}
              actionBusy={actionBusy}
              tier2Ack={tier2Ack}
              onAck={(id, checked) =>
                setTier2Ack((prev) => ({
                  ...prev,
                  [id]: checked,
                }))
              }
              onReview={reviewHostAction}
            />
          )}
          {atSessionLlmCap && (
            <p className="text-[10px] text-amber-400/90">
              {MAX_CONCURRENT_BUSY} sessions already waiting on the model. Finish one before another
              LLM ask (catalog proposes still work in a new tab).
            </p>
          )}
          {queueLen > 0 && (
            <p className="text-[10px] text-slate-500">
              {queueLen} follow-up{queueLen === 1 ? "" : "s"} queued
            </p>
          )}
          <div className="flex items-end gap-2">
            <ContextUsageRing usage={contextUsage} />
            <div className="min-w-0 flex-1">
              <ChatInput
                onSend={send}
                disabled={atSessionLlmCap}
                placeholder={busy ? "Queue a follow-up..." : undefined}
              />
            </div>
          </div>
        </div>
      </div>
    </>
  );

  const panelBody = (
    <div
      className={
        fullscreen
          ? "fixed inset-0 z-[200] flex flex-col"
          : "w-[min(calc(100vw-2rem),32rem)] h-[min(85dvh,40rem)] flex flex-col rounded-xl border shadow-2xl overflow-hidden text-slate-100"
      }
      style={alfaPanelStyle}
      role="dialog"
      aria-label="ALFa AI"
      id="alfa-ai-admin-dock-panel"
    >
      {chrome}
    </div>
  );

  return (
    <div
      className="fixed bottom-4 right-4 z-[90] flex flex-col items-end gap-2 pointer-events-none [&>*]:pointer-events-auto pb-[env(safe-area-inset-bottom,0)] pr-[env(safe-area-inset-right,0)]"
      aria-live="polite"
    >
      {panelOpen || fullscreen ? (
        fullscreen ? createPortal(panelBody, document.body) : panelBody
      ) : (
        <button
          type="button"
          onClick={() => setPanelOpen(true)}
          className="flex items-center gap-2 rounded-full border py-1.5 pl-1.5 pr-4 shadow-lg transition-colors hover:brightness-110"
          style={alfaLauncherStyle}
          aria-expanded={false}
          aria-controls="alfa-ai-admin-dock-panel"
          title="Open ALFa AI"
        >
          <img src={ALFA_AVATAR_SRC} alt="" className="h-9 w-9 rounded-full object-cover" aria-hidden />
          <span className="text-sm font-semibold text-sky-400 tracking-wide">ALFa AI</span>
          {busyCount > 0 && (
            <span className="rounded-full bg-sky-900/80 px-1.5 text-[10px] text-sky-300">
              {busyCount}
            </span>
          )}
        </button>
      )}
    </div>
  );
}
