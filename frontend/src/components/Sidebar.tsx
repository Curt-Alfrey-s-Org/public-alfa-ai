import { useMemo, useState } from "react";
import type { Conversation } from "../api/client";

interface Props {
  conversations: Conversation[];
  activeId: string | null;
  onSelect: (id: string) => void;
  onNew: () => void;
  onDelete: (id: string) => void;
  onRename: (id: string, title: string) => void;
  collapsed: boolean;
  onToggle: () => void;
}

function formatRelativeTime(iso: string): string {
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return "";
  const sec = Math.max(0, Math.round((Date.now() - t) / 1000));
  if (sec < 60) return "just now";
  const min = Math.round(sec / 60);
  if (min < 60) return `${min}m ago`;
  const hr = Math.round(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.round(hr / 24);
  if (day < 14) return `${day}d ago`;
  try {
    return new Date(t).toLocaleDateString(undefined, { month: "short", day: "numeric" });
  } catch {
    return "";
  }
}

export default function Sidebar({
  conversations,
  activeId,
  onSelect,
  onNew,
  onDelete,
  onRename,
  collapsed,
  onToggle,
}: Props) {
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editTitle, setEditTitle] = useState("");
  const [pendingDeleteId, setPendingDeleteId] = useState<string | null>(null);
  const [query, setQuery] = useState("");

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return conversations;
    return conversations.filter((c) => c.title.toLowerCase().includes(q));
  }, [conversations, query]);

  function startRename(conv: Conversation) {
    setPendingDeleteId(null);
    setEditingId(conv.id);
    setEditTitle(conv.title);
  }

  function commitRename() {
    if (editingId && editTitle.trim() && editTitle.trim() !== conversations.find((c) => c.id === editingId)?.title) {
      onRename(editingId, editTitle.trim());
    }
    setEditingId(null);
  }

  function cancelRename() {
    setEditingId(null);
    setEditTitle("");
  }

  function requestDelete(convId: string) {
    setEditingId(null);
    setPendingDeleteId(convId);
  }

  function confirmDelete(convId: string) {
    setPendingDeleteId(null);
    onDelete(convId);
  }

  if (collapsed) {
    return (
      <div className="flex w-12 flex-col items-center border-r border-slate-800 bg-slate-900 py-3">
        <button
          type="button"
          onClick={onToggle}
          className="rounded p-1.5 text-slate-400 hover:bg-slate-800 hover:text-slate-200"
          title="Show chat history"
          aria-label="Show chat history"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" className="h-5 w-5">
            <path fillRule="evenodd" d="M2 4.75A.75.75 0 012.75 4h14.5a.75.75 0 010 1.5H2.75A.75.75 0 012 4.75zm0 10.5a.75.75 0 01.75-.75h14.5a.75.75 0 010 1.5H2.75a.75.75 0 01-.75-.75zM2 10a.75.75 0 01.75-.75h7.5a.75.75 0 010 1.5h-7.5A.75.75 0 012 10z" clipRule="evenodd" />
          </svg>
        </button>
        <button
          type="button"
          onClick={onNew}
          className="mt-3 rounded p-1.5 text-slate-400 hover:bg-slate-800 hover:text-sky-400"
          title="New chat"
          aria-label="New chat"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" className="h-5 w-5">
            <path d="M10.75 4.75a.75.75 0 00-1.5 0v4.5h-4.5a.75.75 0 000 1.5h4.5v4.5a.75.75 0 001.5 0v-4.5h4.5a.75.75 0 000-1.5h-4.5v-4.5z" />
          </svg>
        </button>
      </div>
    );
  }

  return (
    <div className="flex w-72 flex-col border-r border-slate-800 bg-slate-900">
      <div className="flex items-center justify-between border-b border-slate-800 px-3 py-3">
        <span className="text-sm font-semibold text-slate-300">Chats</span>
        <div className="flex gap-1">
          <button
            type="button"
            onClick={onNew}
            className="rounded p-1 text-slate-400 hover:bg-slate-800 hover:text-sky-400"
            title="New chat"
            aria-label="New chat"
          >
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" className="h-4 w-4">
              <path d="M10.75 4.75a.75.75 0 00-1.5 0v4.5h-4.5a.75.75 0 000 1.5h4.5v4.5a.75.75 0 001.5 0v-4.5h4.5a.75.75 0 000-1.5h-4.5v-4.5z" />
            </svg>
          </button>
          <button
            type="button"
            onClick={onToggle}
            className="rounded p-1 text-slate-400 hover:bg-slate-800 hover:text-slate-200"
            title="Hide chat history"
            aria-label="Hide chat history"
          >
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" className="h-4 w-4">
              <path fillRule="evenodd" d="M2 4.75A.75.75 0 012.75 4h14.5a.75.75 0 010 1.5H2.75A.75.75 0 012 4.75zm0 10.5a.75.75 0 01.75-.75h14.5a.75.75 0 010 1.5H2.75a.75.75 0 01-.75-.75zM2 10a.75.75 0 01.75-.75h7.5a.75.75 0 010 1.5h-7.5A.75.75 0 012 10z" clipRule="evenodd" />
            </svg>
          </button>
        </div>
      </div>

      <div className="border-b border-slate-800 px-3 py-2">
        <label className="sr-only" htmlFor="chat-history-search">
          Search chats
        </label>
        <input
          id="chat-history-search"
          type="search"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search chats…"
          className="w-full rounded-lg border border-slate-700 bg-slate-950 px-2.5 py-1.5 text-xs text-slate-200 placeholder:text-slate-600 focus:border-sky-600 focus:outline-none focus:ring-1 focus:ring-sky-600"
        />
      </div>

      <div className="flex-1 overflow-y-auto">
        {filtered.map((conv) => {
          const isActive = conv.id === activeId;
          const confirming = pendingDeleteId === conv.id;
          return (
            <div
              key={conv.id}
              className={`group border-b border-slate-800/60 px-2 py-1.5 transition ${
                isActive ? "bg-slate-800" : "hover:bg-slate-800/50"
              }`}
            >
              {confirming ? (
                <div className="space-y-2 px-1 py-1">
                  <p className="text-xs text-slate-300">Delete this chat?</p>
                  <p className="truncate text-[11px] text-slate-500">{conv.title}</p>
                  <div className="flex gap-2">
                    <button
                      type="button"
                      onClick={() => confirmDelete(conv.id)}
                      className="rounded bg-red-900/60 px-2 py-1 text-xs text-red-200 hover:bg-red-800/70"
                    >
                      Delete
                    </button>
                    <button
                      type="button"
                      onClick={() => setPendingDeleteId(null)}
                      className="rounded border border-slate-700 px-2 py-1 text-xs text-slate-400 hover:text-slate-200"
                    >
                      Cancel
                    </button>
                  </div>
                </div>
              ) : (
                <div className="flex items-start gap-1">
                  <button
                    type="button"
                    onClick={() => onSelect(conv.id)}
                    className={`min-w-0 flex-1 rounded px-1 py-1 text-left ${
                      isActive ? "text-white" : "text-slate-400 hover:text-slate-200"
                    }`}
                    title={conv.title}
                  >
                    {editingId === conv.id ? (
                      <div className="w-full space-y-1.5" onClick={(e) => e.stopPropagation()}>
                        <p className="text-[10px] font-medium uppercase tracking-wide text-slate-500">
                          Rename chat
                        </p>
                        <input
                          autoFocus
                          value={editTitle}
                          onChange={(e) => setEditTitle(e.target.value)}
                          onKeyDown={(e) => {
                            if (e.key === "Enter") commitRename();
                            if (e.key === "Escape") cancelRename();
                          }}
                          className="w-full rounded border border-slate-600 bg-slate-950 px-1.5 py-1 text-sm text-slate-100 outline-none focus:ring-1 focus:ring-sky-600"
                        />
                        <div className="flex gap-2">
                          <button
                            type="button"
                            onClick={commitRename}
                            className="rounded bg-slate-700 px-2 py-0.5 text-[11px] text-slate-200 hover:bg-slate-600"
                          >
                            Save name
                          </button>
                          <button
                            type="button"
                            onClick={cancelRename}
                            className="rounded px-2 py-0.5 text-[11px] text-slate-500 hover:text-slate-300"
                          >
                            Cancel
                          </button>
                        </div>
                      </div>
                    ) : (
                      <>
                        <span className="block truncate text-sm">{conv.title}</span>
                        <span className="mt-0.5 block text-[11px] text-slate-600">
                          {formatRelativeTime(conv.updated_at)}
                        </span>
                      </>
                    )}
                  </button>
                  {editingId !== conv.id && (
                    <div
                      className={`mt-0.5 flex shrink-0 gap-0.5 ${
                        isActive
                          ? "opacity-100"
                          : "opacity-70 sm:opacity-0 sm:group-hover:opacity-100 sm:group-focus-within:opacity-100"
                      }`}
                    >
                      <button
                        type="button"
                        onClick={() => startRename(conv)}
                        className="rounded p-1 text-slate-500 hover:bg-slate-700 hover:text-slate-200"
                        title="Rename chat (does not re-run AI)"
                        aria-label={`Rename ${conv.title}`}
                      >
                        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" className="h-3.5 w-3.5">
                          <path d="M13.488 2.513a1.75 1.75 0 00-2.475 0L3.22 10.306a1.75 1.75 0 00-.434.725L2.01 13.97a.75.75 0 00.917.918l2.937-.776a1.75 1.75 0 00.726-.434l7.793-7.793a1.75 1.75 0 000-2.475z" />
                        </svg>
                      </button>
                      <button
                        type="button"
                        onClick={() => requestDelete(conv.id)}
                        className="rounded p-1 text-slate-500 hover:bg-slate-700 hover:text-red-400"
                        title="Delete chat"
                        aria-label={`Delete ${conv.title}`}
                      >
                        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" className="h-3.5 w-3.5">
                          <path fillRule="evenodd" d="M5 3.25V4H2.75a.75.75 0 000 1.5h.3l.815 8.15A1.5 1.5 0 005.357 15h5.285a1.5 1.5 0 001.493-1.35l.815-8.15h.3a.75.75 0 000-1.5H11v-.75A2.25 2.25 0 008.75 1h-1.5A2.25 2.25 0 005 3.25zm2.25-.75a.75.75 0 00-.75.75V4h3v-.75a.75.75 0 00-.75-.75h-1.5z" clipRule="evenodd" />
                        </svg>
                      </button>
                    </div>
                  )}
                </div>
              )}
            </div>
          );
        })}
        {conversations.length === 0 && (
          <p className="px-3 py-4 text-center text-xs text-slate-600">
            No conversations yet. Send a message to start one.
          </p>
        )}
        {conversations.length > 0 && filtered.length === 0 && (
          <p className="px-3 py-4 text-center text-xs text-slate-600">
            No chats match “{query.trim()}”
          </p>
        )}
      </div>
    </div>
  );
}
