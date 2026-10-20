import { useCallback, useEffect, useRef, useState } from "react";
import Editor from "@monaco-editor/react";
import { useAuth } from "../../contexts/AuthContext";
import { ApiError } from "../../api/client";
import ChatMessage from "../../components/ChatMessage";
import ChatInput from "../../components/ChatInput";
import QuantumOrbLoader from "../../components/QuantumOrbLoader";
import { ALFA_AVATAR_SRC, alfaHeaderStyle, alfaPanelStyle } from "../../lib/alfaChatTheme";

interface FileEntry {
  name: string;
  path: string;
  is_dir: boolean;
  size: number | null;
}

interface AgentMessage {
  role: "user" | "assistant";
  content: string;
}

const BASE = "/alfa-ai/api/admin";

async function apiFetch<T>(path: string, token: string, opts?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    ...opts,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...opts?.headers },
  });
  if (!res.ok) {
    const d = await res.json().catch(() => ({ detail: res.statusText }));
    throw new ApiError(d.detail ?? "Request failed", res.status);
  }
  return res.json();
}

function langFromPath(p: string): string {
  const ext = p.split(".").pop()?.toLowerCase() ?? "";
  const map: Record<string, string> = {
    py: "python", js: "javascript", ts: "typescript", tsx: "typescript",
    jsx: "javascript", json: "json", yaml: "yaml", yml: "yaml",
    md: "markdown", html: "html", css: "css", sql: "sql",
    sh: "shell", bash: "shell", toml: "ini", conf: "ini",
    xml: "xml",
  };
  return map[ext] ?? "plaintext";
}

export default function EditorPage() {
  const { token } = useAuth();
  const [entries, setEntries] = useState<FileEntry[]>([]);
  const [currentDir, setCurrentDir] = useState("");
  const [openFile, setOpenFile] = useState<string | null>(null);
  const [content, setContent] = useState("");
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [agentOpen, setAgentOpen] = useState(true);
  const [agentBusy, setAgentBusy] = useState(false);
  const [agentMessages, setAgentMessages] = useState<AgentMessage[]>([]);
  const agentLogRef = useRef<HTMLDivElement>(null);
  const editorRef = useRef<unknown>(null);

  const loadDir = useCallback(async (dir: string) => {
    if (!token) return;
    setError("");
    try {
      const data = await apiFetch<{ entries: FileEntry[] }>(`/files?path=${encodeURIComponent(dir)}`, token);
      setEntries(data.entries);
      setCurrentDir(dir);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to load directory");
    }
  }, [token]);

  useEffect(() => { loadDir(""); }, [loadDir]);

  useEffect(() => {
    agentLogRef.current?.scrollTo(0, agentLogRef.current.scrollHeight);
  }, [agentMessages, agentBusy]);

  async function openFileHandler(path: string) {
    if (!token) return;
    setError("");
    try {
      const data = await apiFetch<{ content: string }>(`/files/read?path=${encodeURIComponent(path)}`, token);
      setOpenFile(path);
      setContent(data.content);
      setDirty(false);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to read file");
    }
  }

  async function saveFile() {
    if (!token || !openFile) return;
    setSaving(true);
    setError("");
    try {
      await apiFetch("/files/write", token, {
        method: "PUT",
        body: JSON.stringify({ path: openFile, content }),
      });
      setDirty(false);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to save");
    } finally {
      setSaving(false);
    }
  }

  async function askAgent(question: string) {
    if (!token || !question.trim() || agentBusy) return;
    setAgentBusy(true);
    setError("");
    setAgentMessages((prev) => [...prev, { role: "user", content: question }]);
    try {
      const data = await apiFetch<{ reply: string }>("/agent", token, {
        method: "POST",
        body: JSON.stringify({
          message: question,
          file_path: openFile,
          file_content: openFile ? content : null,
        }),
      });
      setAgentMessages((prev) => [...prev, { role: "assistant", content: data.reply }]);
    } catch (err) {
      const msg = err instanceof ApiError ? err.message : "Ask ALFa failed";
      setAgentMessages((prev) => [...prev, { role: "assistant", content: `Error: ${msg}` }]);
    } finally {
      setAgentBusy(false);
    }
  }

  function navigateUp() {
    const parts = currentDir.split("/").filter(Boolean);
    parts.pop();
    loadDir(parts.join("/"));
  }

  return (
    <div className="flex h-full">
      {/* File tree */}
      <div className="w-64 flex-shrink-0 overflow-y-auto border-r border-slate-800 bg-slate-900">
        <div className="flex items-center gap-2 border-b border-slate-800 px-3 py-2">
          <span className="flex-1 truncate text-xs text-slate-500">
            /{currentDir || "workspace"}
          </span>
          {currentDir && (
            <button onClick={navigateUp} className="text-xs text-slate-400 hover:text-slate-200">
              ..
            </button>
          )}
        </div>
        {entries.map((e) => (
          <button
            key={e.path}
            onClick={() => e.is_dir ? loadDir(e.path) : openFileHandler(e.path)}
            className={`flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm transition hover:bg-slate-800 ${
              openFile === e.path ? "bg-slate-800 text-sky-400" : "text-slate-300"
            }`}
          >
            <span className="w-4 text-center text-xs text-slate-500">
              {e.is_dir ? "📁" : "📄"}
            </span>
            <span className="flex-1 truncate">{e.name}</span>
            {e.size !== null && (
              <span className="text-xs text-slate-600">
                {e.size > 1024 ? `${(e.size / 1024).toFixed(0)}K` : `${e.size}B`}
              </span>
            )}
          </button>
        ))}
      </div>

      {/* Editor */}
      <div className="flex min-w-0 flex-1 flex-col">
        {openFile ? (
          <>
            <div className="flex items-center gap-2 border-b border-slate-800 bg-slate-900/50 px-4 py-2">
              <span className="flex-1 truncate text-sm text-slate-300">{openFile}</span>
              {dirty && <span className="text-xs text-amber-400">unsaved</span>}
              <button
                onClick={() => setAgentOpen((v) => !v)}
                className="rounded border border-slate-600 px-2 py-1 text-xs text-slate-300 hover:bg-slate-800"
              >
                {agentOpen ? "Hide ALFa" : "Ask ALFa"}
              </button>
              <button
                onClick={saveFile}
                disabled={!dirty || saving}
                className="rounded bg-sky-600 px-3 py-1 text-xs text-white disabled:opacity-40"
              >
                {saving ? "Saving…" : "Save"}
              </button>
            </div>
            <div className="flex min-h-0 flex-1">
              <div className="min-w-0 flex-1">
                <Editor
                  height="100%"
                  theme="vs-dark"
                  language={langFromPath(openFile)}
                  value={content}
                  onChange={(v) => { setContent(v ?? ""); setDirty(true); }}
                  onMount={(editor) => { editorRef.current = editor; }}
                  options={{
                    minimap: { enabled: false },
                    fontSize: 13,
                    wordWrap: "on",
                    scrollBeyondLastLine: false,
                  }}
                />
              </div>
              {agentOpen && (
                <div className="flex w-80 flex-shrink-0 flex-col border-l" style={alfaPanelStyle}>
                  <div
                    className="flex items-center gap-2 border-b px-3 py-2.5 shrink-0"
                    style={alfaHeaderStyle}
                  >
                    <img
                      src={ALFA_AVATAR_SRC}
                      alt="ALFa AI"
                      className="h-6 w-6 shrink-0 rounded-full object-cover"
                    />
                    <div className="min-w-0 flex-1">
                      <span className="text-xs font-bold text-sky-400">ALFa AI</span>
                      <div className="truncate text-[10px] text-slate-400">
                        {openFile ? `Editing: ${openFile}` : "Open a file for context"}
                      </div>
                    </div>
                  </div>
                  <div ref={agentLogRef} className="flex-1 space-y-3 overflow-y-auto px-2 py-3">
                    {agentMessages.length === 0 && !agentBusy && (
                      <div className="flex flex-col items-center justify-center py-6 text-center">
                        <img
                          src={ALFA_AVATAR_SRC}
                          alt="ALFa AI"
                          className="mb-2 h-10 w-10 rounded-full object-cover"
                        />
                        <p className="max-w-[15rem] text-xs text-slate-400 leading-relaxed">
                          Questions about the open file use 27B frontier-code context.
                        </p>
                      </div>
                    )}
                    {agentMessages.map((m, i) => (
                      <ChatMessage key={i} role={m.role} content={m.content} />
                    ))}
                    {agentBusy && (
                      <div className="flex justify-start pl-9">
                        <div className="rounded-2xl bg-slate-800 px-3 py-1.5">
                          <QuantumOrbLoader />
                        </div>
                      </div>
                    )}
                  </div>
                  <div className="shrink-0 border-t border-slate-700/60 p-2">
                    <ChatInput
                      onSend={askAgent}
                      disabled={!openFile || agentBusy}
                      placeholder={openFile ? "Ask about this file…" : "Open a file first…"}
                    />
                  </div>
                </div>
              )}
            </div>
          </>
        ) : (
          <div className="flex flex-1 items-center justify-center text-slate-600">
            Select a file to edit
          </div>
        )}
        {error && (
          <div className="border-t border-red-800/50 bg-red-950/30 px-4 py-2 text-sm text-red-400">
            {error}
          </div>
        )}
      </div>
    </div>
  );
}