import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import ChatMessage from "../components/ChatMessage";
import ChatInput from "../components/ChatInput";
import { sanitizePublicError, PUBLIC_CHAT_ERROR } from "../api/client";
import QuantumOrbLoader from "../components/QuantumOrbLoader";
import {
  ALFA_AVATAR_SRC,
  ALFA_PANEL_BG,
  alfaHeaderStyle,
} from "../lib/alfaChatTheme";

const BASE = "/alfa-ai/api/guest";

interface LocalMessage {
  role: "user" | "assistant";
  content: string;
}

interface GuestConfig {
  demo_prompts: string[];
  max_messages: number;
  session_id: string;
  thinking_phrases?: string[];
}

export default function GuestChat() {
  const [messages, setMessages] = useState<LocalMessage[]>([]);
  const [sending, setSending] = useState(false);
  const [streamContent, setStreamContent] = useState("");
  const [error, setError] = useState("");
  const [config, setConfig] = useState<GuestConfig | null>(null);
  const [msgCount, setMsgCount] = useState(0);
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    fetch(`${BASE}/config`)
      .then((r) => r.json())
      .then(setConfig)
      .catch(() => {});
  }, []);

  useEffect(() => {
    scrollRef.current?.scrollTo({
      top: scrollRef.current.scrollHeight,
      behavior: "smooth",
    });
  }, [messages, streamContent]);

  const handleSend = useCallback(
    async (text: string) => {
      setError("");
      const userMsg: LocalMessage = { role: "user", content: text };
      const updated = [...messages, userMsg];
      setMessages(updated);
      setSending(true);
      setStreamContent("");
      setMsgCount((c) => c + 1);

      const apiMessages = updated.slice(-6).map((m) => ({
        role: m.role,
        content: m.content,
      }));

      try {
        const res = await fetch(`${BASE}/chat`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            messages: apiMessages,
            stream: true,
            session_id: config?.session_id,
          }),
        });

        if (!res.ok) {
          const data = await res.json().catch(() => ({ detail: res.statusText }));
          throw new Error(sanitizePublicError(data.detail, res.status));
        }

        const reader = res.body?.getReader();
        if (!reader) throw new Error("No stream");
        const decoder = new TextDecoder();
        let accumulated = "";
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
              if (parsed.error) {
                setError(sanitizePublicError(parsed.error, 502));
                continue;
              }
              const delta = parsed.choices?.[0]?.delta?.content ?? "";
              if (delta) {
                accumulated += delta;
                setStreamContent(accumulated);
              }
            } catch { /* skip */ }
          }
        }

        if (accumulated) {
          setMessages((prev) => [...prev, { role: "assistant", content: accumulated }]);
        }
        setStreamContent("");
      } catch (err) {
        setError(
          err instanceof Error
            ? sanitizePublicError(err.message, 502)
            : PUBLIC_CHAT_ERROR,
        );
      } finally {
        setSending(false);
      }
    },
    [messages, config],
  );

  const remaining = (config?.max_messages ?? 10) - msgCount;

  return (
    <div className="flex h-screen flex-col" style={{ backgroundColor: ALFA_PANEL_BG }}>
      {/* Header */}
      <header
        className="flex items-center justify-between border-b px-4 py-3"
        style={alfaHeaderStyle}
      >
        <div className="flex items-center gap-3">
          <img src={ALFA_AVATAR_SRC} alt="ALFa AI" className="h-7 w-7 rounded-full object-cover" />
          <h1 className="text-lg font-bold text-sky-400">ALFa AI</h1>
          <span className="rounded-full bg-slate-800 px-2.5 py-0.5 text-xs text-amber-400">
            Guest Demo
          </span>
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
          <span className="text-xs text-slate-500">
            {remaining > 0 ? `${remaining} messages left` : "Limit reached"}
          </span>
          <Link
            to="/register"
            className="rounded-lg bg-sky-600 px-3 py-1 text-xs font-medium text-white transition hover:bg-sky-500"
          >
            Sign up
          </Link>
          <Link
            to="/login"
            className="rounded-lg border border-slate-700 px-3 py-1 text-xs text-slate-400 transition hover:text-slate-300"
          >
            Sign in
          </Link>
        </div>
      </header>

      {/* Messages area */}
      <div ref={scrollRef} className="flex-1 overflow-y-auto px-4 py-6">
        <div className="mx-auto max-w-3xl space-y-4">
          {messages.length === 0 && !streamContent && (
            <div className="flex flex-col items-center justify-center py-16 text-center">
              <img src={ALFA_AVATAR_SRC} alt="ALFa AI" className="mb-4 h-16 w-16 rounded-full object-cover" />
              <h2 className="text-xl font-semibold text-slate-300">
                Try ALFa AI
              </h2>
              <p className="mt-2 max-w-sm text-sm text-slate-500">
                Ask anything below, or try one of these demos:
              </p>
              {config && (
                <div className="mt-6 flex flex-wrap justify-center gap-2">
                  {config.demo_prompts.map((p) => (
                    <button
                      key={p}
                      onClick={() => handleSend(p)}
                      disabled={sending}
                      className="rounded-lg border border-slate-700 px-3 py-2 text-left text-xs text-slate-300 transition hover:border-sky-600 hover:text-sky-400 disabled:opacity-50"
                    >
                      {p}
                    </button>
                  ))}
                </div>
              )}
            </div>
          )}
          {messages.map((msg, i) => (
            <ChatMessage
              key={i}
              role={msg.role}
              content={msg.content}
              thinkingPhrases={config?.thinking_phrases ?? []}
            />
          ))}
          {streamContent && (
            <ChatMessage
              role="assistant"
              content={streamContent}
              thinkingPhrases={config?.thinking_phrases ?? []}
            />
          )}
          {sending && !streamContent && (
            <div className="flex justify-start">
              <div className="rounded-2xl bg-slate-800 px-4 py-2">
                <QuantumOrbLoader />
              </div>
            </div>
          )}
          {error && (
            <div className="rounded-xl border border-red-800/50 bg-red-950/30 px-4 py-3 text-sm text-red-400">
              {error}
              {remaining <= 0 && (
                <div className="mt-2">
                  <Link to="/register" className="font-medium text-sky-400 hover:text-sky-300">
                    Create a free account
                  </Link>{" "}
                  for unlimited access.
                </div>
              )}
            </div>
          )}
        </div>
      </div>

      {/* Input area */}
      <div className="border-t px-4 py-4" style={alfaHeaderStyle}>
        <div className="mx-auto max-w-3xl">
          <ChatInput onSend={handleSend} disabled={sending || remaining <= 0} />
          {remaining <= 0 && (
            <p className="mt-2 text-center text-xs text-slate-500">
              You've used all guest messages.{" "}
              <Link to="/register" className="text-sky-400 hover:text-sky-300">
                Sign up
              </Link>{" "}
              to continue chatting.
            </p>
          )}
        </div>
      </div>
    </div>
  );
}
