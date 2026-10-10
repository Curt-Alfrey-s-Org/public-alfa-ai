import { isValidElement, useEffect, useState, type ReactNode } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

import { ALFA_AVATAR_SRC } from "../lib/alfaChatTheme";
import { splitThinkContent } from "../lib/thinkTags";
import ExpandableClip from "./ExpandableClip";
import ThinkingIndicator from "./ThinkingIndicator";

export interface ChatTimingMeta {
  /** Wall seconds from send to stream end (or live elapsed while streaming). */
  totalSec: number;
  /** Seconds until first content delta; null until first token. */
  ttftSec: number | null;
  /** Streamed character count (for rough tok/s). */
  approxChars?: number;
  /** True while the SSE stream is still open. */
  live?: boolean;
}

interface Props {
  role: "user" | "assistant";
  content: string;
  editable?: boolean;
  disabled?: boolean;
  onEdit?: (newContent: string) => void;
  /** Admin-editable phrases to cycle while inside a <think> block. Defaults to none (hidden). */
  thinkingPhrases?: string[];
  /** Optional client-side response timing (brain SPA benchmark). */
  timing?: ChatTimingMeta;
  /** Ask ALFa dock: collapse long replies behind Expand (Approve stays in the composer bar). */
  scrollBody?: boolean;
}

export function formatTiming(timing: ChatTimingMeta): string {
  const total = timing.totalSec.toFixed(1);
  const parts = [timing.live ? `${total}s…` : `${total}s`];
  if (timing.ttftSec != null) {
    parts.push(`first ${timing.ttftSec.toFixed(1)}s`);
  }
  const approxTok = Math.max((timing.approxChars ?? 0) / 4, 0);
  if (!timing.live && approxTok >= 1) {
    let tokRate: number | null = null;
    if (timing.ttftSec != null) {
      const decodeSec = timing.totalSec - timing.ttftSec;
      if (decodeSec >= 0.15) {
        tokRate = approxTok / decodeSec;
      }
    }
    if (tokRate == null && timing.totalSec >= 1) {
      tokRate = approxTok / timing.totalSec;
    }
    if (tokRate != null) {
      parts.push(`~${tokRate.toFixed(1)} tok/s`);
    }
  }
  return parts.join(" · ");
}

function markdownNodeText(node: ReactNode): string {
  if (node == null || typeof node === "boolean") {
    return "";
  }
  if (typeof node === "string" || typeof node === "number") {
    return String(node);
  }
  if (Array.isArray(node)) {
    return node.map(markdownNodeText).join("");
  }
  if (isValidElement(node) && node.props && "children" in node.props) {
    return markdownNodeText(node.props.children as ReactNode);
  }
  return "";
}

function CopyCodeIcon() {
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      className="h-3.5 w-3.5"
      aria-hidden="true"
    >
      <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
    </svg>
  );
}

function MarkdownPre({ children }: { children?: ReactNode }) {
  const [copied, setCopied] = useState(false);
  const codeText = markdownNodeText(children).replace(/\n$/, "");

  const copyCode = () => {
    if (!codeText || !navigator.clipboard?.writeText) {
      return;
    }
    void navigator.clipboard.writeText(codeText).then(
      () => {
        setCopied(true);
        window.setTimeout(() => setCopied(false), 2000);
      },
      () => {
        /* NotAllowedError or insecure context -- MDN Clipboard.writeText */
      },
    );
  };

  return (
    <div className="group/code relative my-2">
      <button
        type="button"
        onClick={copyCode}
        disabled={!codeText}
        aria-label={copied ? "Copied" : "Copy code"}
        title={copied ? "Copied" : "Copy"}
        className="absolute right-2 top-2 z-10 rounded-md border border-slate-600 bg-slate-800/90 p-1.5 text-slate-300 opacity-100 shadow-sm hover:bg-slate-700 hover:text-white disabled:opacity-40 md:opacity-0 md:group-hover/code:opacity-100"
      >
        {copied ? (
          <span className="px-0.5 text-[10px] font-medium text-emerald-300">Copied</span>
        ) : (
          <CopyCodeIcon />
        )}
      </button>
      <ExpandableClip
        collapsedClassName="max-h-48"
        expandLabel="Expand code"
        collapseLabel="Collapse code"
      >
        <pre className="pr-10">{children}</pre>
      </ExpandableClip>
    </div>
  );
}

function AssistantMarkdown({
  content,
  collapsible,
}: {
  content: string;
  collapsible: boolean;
}) {
  const markdown = (
    <div className="prose-chat min-w-0 text-sm">
      <ReactMarkdown remarkPlugins={[remarkGfm]} components={{ pre: MarkdownPre }}>
        {content}
      </ReactMarkdown>
    </div>
  );
  if (!collapsible) {
    return markdown;
  }
  return (
    <ExpandableClip collapsedClassName="max-h-40" className="min-w-0">
      {markdown}
    </ExpandableClip>
  );
}

export default function ChatMessage({
  role,
  content,
  editable = false,
  disabled = false,
  onEdit,
  thinkingPhrases = [],
  timing,
  scrollBody = false,
}: Props) {
  const isUser = role === "user";
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(content);
  const { thinking, visible } = splitThinkContent(content);

  useEffect(() => {
    if (!editing) setDraft(content);
  }, [content, editing]);

  const saveEdit = () => {
    const trimmed = draft.trim();
    if (!trimmed) return;
    // Always resubmit (even if text unchanged) so Save regenerates the reply -- Cursor-like.
    onEdit?.(trimmed);
    setEditing(false);
  };

  return (
    <div className={`group flex gap-3 ${isUser ? "justify-end" : "justify-start"}`}>
      {!isUser && (
        <img
          src={ALFA_AVATAR_SRC}
          alt="ALFa AI"
          className="mt-1 h-8 w-8 flex-shrink-0 rounded-full object-cover"
        />
      )}
      <div
        className={`min-w-0 ${
          isUser && editing ? "w-full max-w-3xl" : "max-w-[80%]"
        } ${isUser ? "flex flex-col items-end gap-1" : ""}`}
      >
        <div
          className={`min-w-0 rounded-2xl px-4 py-3 ${
            isUser
              ? editing
                ? "w-full border border-sky-500/50 bg-slate-900 text-slate-100"
                : "bg-sky-600 text-white"
              : "bg-slate-800 text-slate-100"
          }`}
        >
          {isUser && editing ? (
            <div className="space-y-2">
              <p className="text-[11px] font-medium uppercase tracking-wide text-sky-400">
                Edit message
              </p>
              <textarea
                value={draft}
                onChange={(e) => setDraft(e.target.value)}
                rows={Math.min(12, Math.max(4, draft.split("\n").length + 1))}
                className="w-full resize-y rounded-lg border border-slate-600 bg-slate-950 px-3 py-2 text-sm leading-relaxed text-slate-100 focus:outline-none focus:ring-1 focus:ring-sky-500"
                autoFocus
              />
              <p className="text-[11px] text-slate-500">
                Save truncates later replies and regenerates from this message.
              </p>
              <div className="flex justify-end gap-2">
                <button
                  type="button"
                  onClick={() => {
                    setDraft(content);
                    setEditing(false);
                  }}
                  className="rounded px-2.5 py-1 text-xs text-slate-400 hover:bg-slate-800 hover:text-slate-200"
                >
                  Cancel
                </button>
                <button
                  type="button"
                  onClick={saveEdit}
                  disabled={!draft.trim() || disabled}
                  className="rounded bg-sky-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-sky-500 disabled:opacity-50"
                >
                  Save & regenerate
                </button>
              </div>
            </div>
          ) : isUser ? (
            <p className="whitespace-pre-wrap text-sm leading-relaxed">{content}</p>
          ) : thinking ? (
            <ThinkingIndicator phrases={thinkingPhrases} />
          ) : (
            <AssistantMarkdown content={visible} collapsible={scrollBody} />
          )}
        </div>
        {isUser && editable && !editing && !disabled && onEdit && (
          <button
            type="button"
            onClick={() => setEditing(true)}
            className="text-xs text-slate-500 opacity-0 transition hover:text-slate-300 group-hover:opacity-100"
          >
            Edit & regenerate
          </button>
        )}
        {!isUser && timing && timing.totalSec >= 0 && (
          <p className="mt-1 px-1 text-[11px] tabular-nums text-slate-500" title="Client wall time for this reply">
            {formatTiming(timing)}
          </p>
        )}
      </div>
    </div>
  );
}
