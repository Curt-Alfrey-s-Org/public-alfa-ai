const TOKEN_KEY = "change-me";
/** Same key as frontend/src/contexts/AuthContext.tsx — admin JWT after web login. */
const WEB_ACCESS_KEY = "alfa_ai_access_token";

function getToken() {
  const manual = sessionStorage.getItem(TOKEN_KEY) || "";
  if (manual) return manual;
  try {
    return localStorage.getItem(WEB_ACCESS_KEY) || "";
  } catch {
    return "";
  }
}

function authHeaders() {
  const t = getToken();
  const h = { "Content-Type": "application/json" };
  if (t) h.Authorization = `Bearer ${t}`;
  return h;
}

async function fetchJson(url) {
  const response = await fetch(url, { headers: authHeaders() });
  if (response.status === 401 || response.status === 403) {
    throw new Error("Unauthorized — set ALFA_AI_API_TOKEN and Save token.");
  }
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Request failed: ${response.status} ${text.slice(0, 300)}`);
  }
  return response.json();
}

function badgeClass(stale, ageSec) {
  if (stale || ageSec == null) return "bad";
  if (ageSec > 60) return "warn";
  return "ok";
}

function badgeLabel(stale, ageSec) {
  if (stale) return "stale";
  if (ageSec == null) return "unknown";
  return `${ageSec}s ago`;
}

function pctBar(label, value, max, elClass) {
  const pct = max > 0 ? Math.min(100, Math.round((value / max) * 100)) : 0;
  const fillClass =
    pct > 90 ? "bad" : pct > 75 ? "warn" : "";
  return `
    <div class="bar">
      <label><span>${label}</span><span>${pct}%</span></label>
      <div class="bar-track"><div class="bar-fill ${fillClass}" style="width:${pct}%"></div></div>
    </div>`;
}

function renderBrain(data) {
  const el = document.getElementById("brain-services");
  const brain = data.brain || {};
  const services = brain.services || [];
  const html = services
    .map((s) => {
      const ok = s.ok;
      const name = s.name || "service";
      const detail =
        s.status_code != null
          ? `HTTP ${s.status_code}`
          : s.error || (ok ? "ok" : "fail");
      return `<div class="svc-pill ${ok ? "ok" : "bad"}"><strong>${escapeHtml(
        name,
      )}</strong><br /><span class="meta">${escapeHtml(String(detail))}</span></div>`;
    })
    .join("");
  if (!html) {
    el.innerHTML = '<p class="empty">No service data.</p>';
    return;
  }
  el.innerHTML = html;
}

function escapeHtml(s) {
  const d = document.createElement("div");
  d.textContent = s;
  return d.innerHTML;
}

function renderClusterHosts(data) {
  const el = document.getElementById("cluster-hosts");
  if (!el) return;
  const hosts = data.hosts || [];
  if (!hosts.length) {
    el.innerHTML = '<p class="empty">No cluster host data.</p>';
    return;
  }
  el.innerHTML = hosts
    .map((h) => {
      const cls = h.reachable ? "ok" : "bad";
      const label = h.reachable ? "reachable" : "offline";
      const checks = (h.checks || [])
        .map((c) => {
          const cOk = c.ok;
          const detail =
            c.status_code != null
              ? `HTTP ${c.status_code}`
              : c.error || (cOk ? "ok" : "fail");
          return `<div class="svc-pill ${cOk ? "ok" : "bad"}"><strong>${escapeHtml(
            c.name || "check",
          )}</strong><br /><span class="meta">${escapeHtml(
            String(c.url || ""),
          )}</span><br /><span class="meta">${escapeHtml(
            String(detail).slice(0, 200),
          )}</span></div>`;
        })
        .join("");
      return `
      <div class="worker-card">
        <h3>${escapeHtml(String(h.name || h.key || "?"))} <span class="badge ${cls}">${label}</span></h3>
        <div class="worker-meta">${escapeHtml(
          `${h.lan_ip || ""}${h.role ? " · " + h.role : ""}`,
        )}</div>
        <div class="svc-grid">${checks || '<p class="empty">No checks defined.</p>'}</div>
      </div>`;
    })
    .join("");
}

function renderWorkers(data) {
  const el = document.getElementById("worker-cards");
  const workers = data.workers || [];
  if (!workers.length) {
    el.innerHTML =
      '<p class="empty">No worker heartbeats yet. Set ALFA_BRAIN_URL on workers.</p>';
    return;
  }
  el.innerHTML = workers
    .map((w) => {
      const p = w.payload || {};
      const name = p.worker_name || p.hostname || w.redis_key || "?";
      const stale = w.stale;
      const age = w.age_sec;
      const bc = badgeClass(stale, age);
      const gpuU = p.gpu_utilization_percent;
      const gmu = p.gpu_mem_used_mb;
      const gmt = p.gpu_mem_total_mb;
      const memU = p.mem_used_mb;
      const memT = p.mem_total_mb;
      const disk = p.disk_used_percent;
      let bars = "";
      if (gmu != null && gmt != null) {
        bars += pctBar("GPU VRAM", gmu, gmt);
      } else if (gpuU != null) {
        bars += pctBar("GPU util", gpuU, 100);
      }
      if (memU != null && memT != null) {
        bars += pctBar("RAM", memU, memT);
      }
      if (disk != null) {
        bars += `
    <div class="bar">
      <label><span>Disk /</span><span>${disk}%</span></label>
      <div class="bar-track"><div class="bar-fill ${
        disk > 90 ? "bad" : disk > 80 ? "warn" : ""
      }" style="width:${Math.min(100, disk)}%"></div></div>
    </div>`;
      }
      const metaBits = [
        p.hostname && `host: ${p.hostname}`,
        p.gpu_name && `GPU: ${p.gpu_name}`,
        p.load1 && `load: ${p.load1}`,
      ]
        .filter(Boolean)
        .join(" · ");
      return `
      <div class="worker-card">
        <h3>${escapeHtml(String(name))} <span class="badge ${bc}">${badgeLabel(stale, age)}</span></h3>
        <div class="worker-meta">${escapeHtml(metaBits || "—")}</div>
        ${bars || '<p class="meta">No resource bars (CPU worker or metrics n/a)</p>'}
        ${
          p.log_tail
            ? `<pre class="log">${escapeHtml(String(p.log_tail).slice(0, 400))}</pre>`
            : ""
        }
      </div>`;
    })
    .join("");
}

async function refresh() {
  const authStatus = document.getElementById("auth-status");
  try {
    const data = await fetchJson("/api/admin/health");
    authStatus.textContent = `build ${data.build_hash || "?"} · ${new Date().toLocaleTimeString()}`;
    renderBrain(data);
    renderClusterHosts(data);
    renderWorkers(data);
  } catch (e) {
    authStatus.textContent = String(e.message);
  }
}

const tokenInput = document.getElementById("token-input");
const saveTokenBtn = document.getElementById("save-token");

saveTokenBtn.addEventListener("click", () => {
  const v = tokenInput.value.trim();
  if (v) sessionStorage.setItem(TOKEN_KEY, v);
  else sessionStorage.removeItem(TOKEN_KEY);
  refresh();
});

async function init() {
  const existing = getToken();
  if (existing) tokenInput.placeholder = "(token saved — re-enter to replace)";
  await refresh();
  setInterval(refresh, 10000);
}

init();
