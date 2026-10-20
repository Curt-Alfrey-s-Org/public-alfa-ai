const state = {
  runs: [],
  selectedRunId: null,
};

const runsList = document.getElementById("runs-list");
const tasksList = document.getElementById("tasks-list");
const artifactsList = document.getElementById("artifacts-list");
const runMeta = document.getElementById("run-meta");
const createRunForm = document.getElementById("create-run-form");
const goalInput = document.getElementById("goal-input");
const refreshRunsBtn = document.getElementById("refresh-runs");
const processNextBtn = document.getElementById("process-next");

async function fetchJson(url, options = {}) {
  const response = await fetch(url, options);
  if (!response.ok) {
    throw new Error(`Request failed: ${response.status}`);
  }
  return response.json();
}

function renderRuns() {
  runsList.innerHTML = "";
  for (const run of state.runs) {
    const item = document.createElement("li");
    item.className = "run-item";
    const button = document.createElement("button");
    button.textContent = `${run.status.toUpperCase()} - ${run.goal}`;
    if (run.run_id === state.selectedRunId) {
      button.classList.add("active");
    }
    button.addEventListener("click", () => {
      state.selectedRunId = run.run_id;
      renderRuns();
      loadRunDetails();
    });
    item.appendChild(button);
    runsList.appendChild(item);
  }
}

function renderRunDetails(data) {
  if (!data || !data.ok) {
    runMeta.textContent = "Run not found.";
    tasksList.innerHTML = "";
    artifactsList.innerHTML = "";
    return;
  }

  const run = data.run;
  runMeta.textContent = `Run ${run.run_id} | Status: ${run.status} | Created: ${run.created_at}`;

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
  if (!state.selectedRunId) {
    return;
  }
  const details = await fetchJson(`/api/runs/${state.selectedRunId}`);
  renderRunDetails(details);
}

createRunForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const goal = goalInput.value.trim();
  if (!goal) {
    return;
  }
  const payload = { goal };
  const created = await fetchJson("/api/runs", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  goalInput.value = "";
  state.selectedRunId = created.run_id;
  await loadRuns();
  await loadRunDetails();
});

refreshRunsBtn.addEventListener("click", async () => {
  await loadRuns();
  await loadRunDetails();
});

processNextBtn.addEventListener("click", async () => {
  await fetchJson("/api/runs/process-next", { method: "POST" });
  await loadRuns();
  await loadRunDetails();
});

async function init() {
  await loadRuns();
  await loadRunDetails();
}

init().catch((error) => {
  runMeta.textContent = `Failed to load UI: ${error.message}`;
});
