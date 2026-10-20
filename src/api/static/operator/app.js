const TOKEN_KEY = "change-me";

const state = {
  runs: [],
  selectedRunId: null,
  chatMessages: [],
  eventSource: null,
  toolEvents: [],
};

function getToken() {
  return sessionStorage.getItem(TOKEN_KEY) || "";
}

function authHeaders() {
  const t = getToken();
  const h = { "Content-Type": "application/json" };
  if (t) h.Authorization = `Bearer ${t}`;
  return h;
}

async function fetchJson(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    headers: { ...authHeaders(), ...(options.headers || {}) },
  });
  if (response.status === 401 || response.status === 403) {
    throw new Error("Unauthorized — set ALFA_AI_API_TOKEN and click Save token.");
  }
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Request failed: ${response.status} ${text.slice(0, 200)}`);
  }
  return response.json();
}

const runsList = document.getElementById("runs-list");
const tasksList = document.getElementById("tasks-list");
const artifactsList = document.getElementById("artifacts-list");
const runMeta = document.getElementById("run-meta");
const createRunForm = document.getElementById("create-run-form");
const goalInput = document.getElementById("goal-input");
const refreshRunsBtn = document.getElementById("refresh-runs");
const processNextBtn = document.getElementById("process-next");
const tokenInput = document.getElementById("token-input");
const saveTokenBtn = document.getElementById("save-token");
const authStatus = document.getElementById("auth-status");
const chatLog = document.getElementById("chat-log");
const chatForm = document.getElementById("chat-form");
const chatInput = document.getElementById("chat-input");
const chatModelLabel = document.getElementById("chat-model-label");
const toolEventsList = document.getElementById("tool-events-list");

function renderRuns() {
  runsList.innerHTML = "";
  for (const run of state.runs) {
    const item = document.createElement("li");
    item.className = "run-item";
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = `${run.status.toUpperCase()} — ${run.goal.slice(0, 80)}${run.goal.length > 80 ? "…" : ""}`;
    if (run.run_id === state.selectedRunId) button.classList.add("active");
    button.addEventListener("click", () => {
      state.selectedRunId = run.run_id;
      renderRuns();
      loadRunDetails();
      startEventStream(run.run_id);
    });
    item.appendChild(button);
    runsList.appendChild(item);
  }
}

function renderToolEvents() {
  if (!toolEventsList) return;
  toolEventsList.innerHTML = "";
  const items = state.toolEvents.slice(-40);
  for (const ev of items) {
    const li = document.createElement("li");
    const label = ev.type === "tool_start"
      ? `→ ${ev.tool}`
      : ev.type === "tool_end"
        ? `${ev.ok ? "✓" : "✗"} ${ev.tool} (${ev.duration_ms || 0}ms)`
        : ev.type === "task_start"
          ? `▶ ${ev.role}: ${ev.title || ev.task_id}`
          : ev.type === "task_done"
            ? `■ ${ev.role} ${ev.status} — ${(ev.summary || "").slice(0, 60)}`
            : JSON.stringify(ev);
    li.textContent = label;
    toolEventsList.appendChild(li);
  }
}

function stopEventStream() {
  if (state.eventSource) {
    state.eventSource.close();
    state.eventSource = null;
  }
}

function startEventStream(runId) {
  stopEventStream();
  if (!runId || !getToken()) return;
  state.toolEvents = [];
  renderToolEvents();
  const token = getToken();
  const qs = token ? `?access_token=${encodeURIComponent(token)}` : "";
  const es = new EventSource(`/api/runs/${encodeURIComponent(runId)}/events${qs}`);
  state.eventSource = es;
  es.onmessage = (msg) => {
    try {
      const ev = JSON.parse(msg.data);
      state.toolEvents.push(ev);
      renderToolEvents();
      if (ev.type === "run_complete" || ev.type === "task_done") {
        loadRuns().then(loadRunDetails).catch(() => {});
      }
    } catch {
      /* ignore malformed */
    }
  };
  es.onerror = () => {
    stopEventStream();
  };
}

function renderRunDetails(data) {
  if (!data || !data.ok) {
    runMeta.textContent = "Run not found.";
    tasksList.innerHTML = "";
    artifactsList.innerHTML = "";
    return;
  }
  const run = data.run;
  runMeta.textContent = `Run ${run.run_id} | ${run.status} | ${run.created_at}`;

  tasksList.innerHTML = "";
  for (const task of data.tasks) {
    const li = document.createElement("li");
    li.textContent = `${task.role} | ${task.status} | ${task.title}`;
    tasksList.appendChild(li);
  }

  artifactsList.innerHTML = "";
  for (const artifact of data.artifacts || []) {
    const li = document.createElement("li");
    li.textContent = `${artifact.artifact_type} | ${artifact.path}`;
    artifactsList.appendChild(li);
  }
}

async function loadRuns() {
  state.runs = await fetchJson("/api/runs");
  if (!state.selectedRunId && state.runs.length > 0) {
    state.selectedRunId = state.runs[state.runs.length - 1].run_id;
  }
  renderRuns();
}

async function loadRunDetails() {
  if (!state.selectedRunId) return;
  const details = await fetchJson(`/api/runs/${state.selectedRunId}`);
  renderRunDetails(details);
}

function renderChat() {
  chatLog.innerHTML = "";
  for (const m of state.chatMessages) {
    const div = document.createElement("div");
    div.className = `msg ${m.role}`;
    div.textContent = `${m.role === "user" ? "You" : m.role === "assistant" ? "Assistant" : m.role}: ${m.content}`;
    chatLog.appendChild(div);
  }
  chatLog.scrollTop = chatLog.scrollHeight;
}

saveTokenBtn.addEventListener("click", async () => {
  const v = tokenInput.value.trim();
  if (v) sessionStorage.setItem(TOKEN_KEY, v);
  else sessionStorage.removeItem(TOKEN_KEY);
  authStatus.textContent = v ? "Token saved in session (tab only)." : "Token cleared.";
  await loadChatModelLabel();
  try {
    await loadRuns();
    await loadRunDetails();
  } catch {
    /* ignore until token valid */
  }
});

createRunForm.addEventListener("submit", async (e) => {
  e.preventDefault();
  const goal = goalInput.value.trim();
  if (!goal) return;
  try {
    const created = await fetchJson("/api/runs", {
      method: "POST",
      body: JSON.stringify({ goal }),
    });
    goalInput.value = "";
    state.selectedRunId = created.run_id;
    await loadRuns();
    await loadRunDetails();
  } catch (err) {
    runMeta.textContent = String(err.message);
  }
});

refreshRunsBtn.addEventListener("click", async () => {
  try {
    await loadRuns();
    await loadRunDetails();
  } catch (err) {
    runMeta.textContent = String(err.message);
  }
});

processNextBtn.addEventListener("click", async () => {
  try {
    if (state.selectedRunId) startEventStream(state.selectedRunId);
    const data = await fetchJson("/api/runs/process-next", { method: "POST" });
    if (data.result && data.result.tool_events) {
      for (const ev of data.result.tool_events) {
        state.toolEvents.push({ type: "tool_end", ...ev });
      }
      renderToolEvents();
    }
    await loadRuns();
    await loadRunDetails();
  } catch (err) {
    runMeta.textContent = String(err.message);
  }
});

chatForm.addEventListener("submit", async (e) => {
  e.preventDefault();
  const text = chatInput.value.trim();
  if (!text) return;
  chatInput.value = "";
  state.chatMessages.push({ role: "user", content: text });
  renderChat();
  try {
    const body = {
      messages: state.chatMessages.map(({ role, content }) => ({ role, content })),
    };
    const data = await fetchJson("/operator/api/chat", {
      method: "POST",
      body: JSON.stringify(body),
    });
    const choice = data.choices && data.choices[0];
    const reply = choice && choice.message && choice.message.content ? choice.message.content : JSON.stringify(data);
    state.chatMessages.push({ role: "assistant", content: reply });
  } catch (err) {
    state.chatMessages.push({ role: "assistant", content: `Error: ${err.message}` });
  }
  renderChat();
});

async function loadChatModelLabel() {
  if (!getToken()) {
    chatModelLabel.textContent = "(save token to show model)";
    return;
  }
  try {
    const cfg = await fetchJson("/operator/api/config");
    chatModelLabel.textContent = cfg.chat_model || "(unknown)";
  } catch {
    chatModelLabel.textContent = "OPERATOR_CHAT_MODEL / DEFAULT_MODEL";
  }
}

async function init() {
  const existing = getToken();
  if (existing) tokenInput.placeholder = "(token saved — re-enter to replace)";

  try {
    const health = await fetch("/health");
    if (health.ok) authStatus.textContent = "API reachable.";
  } catch {
    authStatus.textContent = "Cannot reach API.";
  }

  await loadChatModelLabel();

  try {
    await loadRuns();
    await loadRunDetails();
  } catch (err) {
    runMeta.textContent = String(err.message);
  }
}

init();
