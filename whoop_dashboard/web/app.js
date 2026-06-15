"use strict";

const $ = (id) => document.getElementById(id);
const charts = {};
let suppressAnim = false;  // true during a silent auto-refresh (skip count-up + chart animation)
let loadInFlight = false;  // guard against overlapping loads

// ---- helpers --------------------------------------------------------------
function recoveryColor(s) {
  if (s == null) return "#8a8a95";
  if (s >= 67) return "#34d399";
  if (s >= 34) return "#fbbf24";
  return "#f87171";
}
function fmtHours(h) {
  if (h == null) return "--";
  const m = Math.round(h * 60);
  return `${Math.floor(m / 60)}h ${String(m % 60).padStart(2, "0")}m`;
}
function num(v, d = 0) { return v == null ? "--" : Number(v).toFixed(d); }
function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}
function localKey(dt) {
  return `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, "0")}-${String(dt.getDate()).padStart(2, "0")}`;
}
function titleCase(s) { return String(s || "").replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase()); }
const SPORT_ICON = (n) => {
  n = (n || "").toLowerCase();
  const m = { run: "🏃", tread: "🏃", walk: "🚶", cycl: "🚴", bik: "🚴", weight: "🏋️", strength: "🏋️",
    functional: "🏋️", swim: "🏊", hik: "🥾", yoga: "🧘", pilates: "🧘", basketball: "🏀", soccer: "⚽",
    tennis: "🎾", pickle: "🏓", golf: "⛳", box: "🥊", row: "🚣", ellipt: "🔥", ski: "⛷️", volley: "🏐",
    climb: "🧗", dance: "🕺", ultimate: "🥏" };
  for (const k in m) if (n.includes(k)) return m[k];
  return "💪";
};
async function getJSON(u) { const r = await fetch(u); if (!r.ok) throw new Error(`${u} -> ${r.status}`); return r.json(); }
function makeChart(id, cfg) {
  if (suppressAnim) { cfg.options = cfg.options || {}; cfg.options.animation = false; }  // seamless auto-refresh
  if (charts[id]) charts[id].destroy();
  charts[id] = new Chart($(id), cfg);
}

// ---- chart theme ----------------------------------------------------------
Chart.defaults.color = "#8a8a95";
Chart.defaults.borderColor = "#23232b";
Chart.defaults.font.family = "-apple-system, system-ui, sans-serif";
Chart.defaults.maintainAspectRatio = false;
const GRID = { color: "#1c1c22" }, NOGRID = { display: false };
const baseLine = (extra = {}) => ({
  responsive: true, maintainAspectRatio: false,
  interaction: { mode: "index", intersect: false },
  elements: { point: { radius: 0, hitRadius: 8 }, line: { tension: 0.35, borderWidth: 2 } },
  plugins: { legend: { display: false } },
  scales: { x: { grid: NOGRID, ticks: { maxTicksLimit: 8 } }, y: { grid: GRID } },
  ...extra,
});

// ---- tab routing ----------------------------------------------------------
function tabFromHash() { return (location.hash || "#overview").slice(1); }
function showTab(name) {
  if (!document.getElementById(name)) name = "overview";
  document.querySelectorAll(".section").forEach((s) => s.classList.toggle("active", s.id === name));
  document.querySelectorAll(".tab").forEach((t) => t.classList.toggle("active", t.dataset.tab === name));
  requestAnimationFrame(() => Object.values(charts).forEach((c) => { try { c.resize(); } catch (e) {} }));
}
window.addEventListener("hashchange", () => showTab(tabFromHash()));

// ---- renderers ------------------------------------------------------------
function renderStatus(s) {
  const name = s.profile && s.profile.first_name ? s.profile.first_name : "";
  $("greeting").textContent = name ? `· ${name}` : "";
  const last = s.last_sync ? new Date(s.last_sync).toLocaleString() : "never";
  const c = s.counts || {};
  $("footer").textContent =
    `${c.days ?? c.cycles ?? 0} days · ${c.sleeps || 0} sleeps · ${c.workouts || 0} workouts · last sync ${last}`;
  const b = $("banner");
  if (!s.credentials_present) {
    b.innerHTML = "No WHOOP credentials. Copy <code>.env.example</code> to <code>.env</code> with your Client ID/Secret.";
    b.classList.remove("hidden");
  } else if (!s.authorized) {
    b.innerHTML = "Not connected. Use the menu-bar “Connect WHOOP”, then Sync.";
    b.classList.remove("hidden");
  } else if (!s.last_sync) {
    b.textContent = "Connected. Click Sync to pull your data."; b.classList.remove("hidden");
  } else b.classList.add("hidden");
}

// Count-up animation (ease-out cubic).
function animateCount(el, to, decimals = 0) {
  if (to == null) { el.textContent = "--"; el.dataset.v = "0"; return; }
  if (suppressAnim) { el.textContent = Number(to).toFixed(decimals); el.dataset.v = to; return; }  // no count-up on auto-refresh
  const from = parseFloat(el.dataset.v || "0") || 0;
  el.dataset.v = to;
  const start = performance.now(), dur = 800;
  function tick(now) {
    const t = Math.min(1, (now - start) / dur);
    const e = 1 - Math.pow(1 - t, 3);
    el.textContent = (from + (to - from) * e).toFixed(decimals);
    if (t < 1) requestAnimationFrame(tick); else el.textContent = Number(to).toFixed(decimals);
  }
  requestAnimationFrame(tick);
}

function setChip(id, delta, { decimals = 0, unit = "", goodUp = true, title = "vs. previous day" } = {}) {
  const el = $(id);
  if (delta == null || !isFinite(delta)) { el.textContent = ""; el.className = "chip"; el.removeAttribute("title"); return; }
  const flat = Math.abs(delta) < (decimals ? 0.05 : 0.5);
  const up = delta >= 0;
  const arrow = flat ? "→" : up ? "▲" : "▼";
  el.textContent = `${arrow} ${up ? "+" : ""}${delta.toFixed(decimals)}${unit}`;
  el.className = "chip " + (flat ? "" : (goodUp === up ? "up" : "down"));
  el.title = title;
}

const WD = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const mean = (a) => (a.length ? a.reduce((s, x) => s + x, 0) / a.length : null);

function computeInsights(recovery, sleep, strain, sports, summary) {
  const out = [];
  const rs = recovery.map((r) => r.recovery_score).filter((v) => v != null);
  if (rs.length >= 8) {
    const a = mean(rs.slice(-7)), b = mean(rs.slice(-14, -7));
    if (b != null) {
      const d = Math.round(a - b);
      out.push({ icon: d >= 0 ? "📈" : "📉", tone: d > 2 ? "up" : d < -2 ? "down" : "flat",
        title: d > 2 ? "Recovery trending up" : d < -2 ? "Recovery dipping" : "Recovery holding steady",
        detail: `7-day average ${Math.round(a)}% vs ${Math.round(b)}% the week before.` });
    }
  }
  const sh = sleep.map((s) => s.hours).filter((v) => v != null);
  const sn = sleep.map((s) => s.need_hours).filter((v) => v != null);
  if (sh.length && sn.length) {
    const got = mean(sh), need = mean(sn), gap = need - got;
    out.push(gap > 0.5
      ? { icon: "🌙", tone: "down", title: "Carrying sleep debt",
          detail: `Averaging ${fmtHours(got)} vs ${fmtHours(need)} needed — about ${Math.round(gap * 60)}m short each night.` }
      : { icon: "🌙", tone: "up", title: "Meeting your sleep need",
          detail: `Averaging ${fmtHours(got)} of ${fmtHours(need)} needed.` });
  }
  if (rs.length >= 7) {
    const byWd = {};
    recovery.forEach((r) => { if (r.recovery_score != null) {
      const w = new Date(r.day + "T00:00:00").getDay(); (byWd[w] = byWd[w] || []).push(r.recovery_score);
    }});
    let best = null, bv = -1;
    Object.entries(byWd).forEach(([w, arr]) => { const m = mean(arr); if (m > bv) { bv = m; best = +w; } });
    if (best != null) out.push({ icon: "💚", tone: "flat", title: `Best recovery on ${WD[best]}s`,
      detail: `You average ${Math.round(bv)}% recovery on ${WD[best]}s.` });
  }
  if (sports && sports.length) {
    const s = sports[0];
    out.push({ icon: "🏆", tone: "flat", title: `Go-to: ${titleCase(s.sport_name)}`,
      detail: `${s.count} sessions logged · ${s.avg_strain ?? "--"} avg strain.` });
  }
  return out.slice(0, 4);
}

function renderInsights(list) {
  const el = $("insights");
  el.innerHTML = list.length ? list.map((i) => `
    <div class="insight ${i.tone}">
      <div class="ic">${i.icon}</div>
      <div><div class="it">${esc(i.title)}</div><div class="id">${esc(i.detail)}</div></div>
    </div>`).join("")
    : `<div class="muted">Sync more history to unlock insights.</div>`;
}

function renderOverview(latest, summary, days, recovery, sleep, strain, sports) {
  const rec = latest.recovery || {}, slp = latest.sleep || {}, str = latest.strain || {};
  const recP = latest.recovery_prev || {}, slpP = latest.sleep_prev || {}, strP = latest.strain_prev || {};
  const score = rec.recovery_score;
  $("rec-ring").style.setProperty("--col", recoveryColor(score));
  $("rec-score").style.color = recoveryColor(score);
  requestAnimationFrame(() => $("rec-ring").style.setProperty("--pct", score ?? 0));
  animateCount($("rec-score"), score, 0);
  $("rec-sub").textContent = `HRV ${num(rec.hrv_rmssd_milli)} ms · RHR ${num(rec.resting_heart_rate)} bpm`;
  setChip("rec-chip", score != null && recP.recovery_score != null ? score - recP.recovery_score : null);

  $("sleep-hours").textContent = fmtHours(slp.hours);
  requestAnimationFrame(() => { $("sleep-perf-bar").style.width = `${Math.min(100, slp.performance || 0)}%`; });
  $("sleep-sub").textContent = `Performance ${num(slp.performance)}% · need ${fmtHours(slp.need_hours)}`;
  setChip("sleep-chip", slp.hours != null && slpP.hours != null ? (slp.hours - slpP.hours) * 60 : null, { unit: "m" });

  animateCount($("strain-val"), str.strain, 1);
  requestAnimationFrame(() => { $("strain-bar").style.width = `${Math.min(100, ((str.strain || 0) / 21) * 100)}%`; });
  $("strain-sub").textContent = `Avg HR ${num(str.average_heart_rate)} · ${str.calories ?? "--"} cal`;
  setChip("strain-chip", str.strain != null && strP.strain != null ? str.strain - strP.strain : null, { decimals: 1 });

  const label = { 7: "7 days", 30: "30 days", 90: "90 days", 180: "6 months", 365: "1 year", 1825: "all time" }[days] || `${days}d`;
  $("range-label").textContent = `over ${label}`;
  const items = [
    ["Avg recovery", summary.avg_recovery != null ? summary.avg_recovery + "%" : "--"],
    ["Avg HRV", summary.avg_hrv != null ? summary.avg_hrv + " ms" : "--"],
    ["Avg resting HR", summary.avg_rhr != null ? summary.avg_rhr + " bpm" : "--"],
    ["Avg sleep", fmtHours(summary.avg_sleep_hours)],
    ["Avg sleep perf.", summary.avg_sleep_performance != null ? summary.avg_sleep_performance + "%" : "--"],
    ["Avg day strain", summary.avg_strain ?? "--"],
    ["Best recovery", summary.max_recovery != null ? summary.max_recovery + "%" : "--"],
    ["Workouts", summary.workout_count ?? 0],
  ];
  $("stats").innerHTML = items.map(([k, v]) => `<div class="stat"><div class="v">${v}</div><div class="k">${k}</div></div>`).join("");

  renderInsights(computeInsights(recovery, sleep, strain, sports, summary));
}

function renderRecovery(d) {
  const labels = d.map((x) => x.day);
  makeChart("chart-recovery", {
    type: "line",
    data: { labels, datasets: [{ data: d.map((x) => x.recovery_score), borderColor: "#34d399",
      backgroundColor: "rgba(52,211,153,.12)", fill: true,
      segment: { borderColor: (c) => recoveryColor(c.p1.parsed.y) } }] },
    options: baseLine({ scales: { x: { grid: NOGRID, ticks: { maxTicksLimit: 8 } }, y: { grid: GRID, min: 0, max: 100 } } }),
  });
  makeChart("chart-hrv", {
    type: "line",
    data: { labels, datasets: [{ data: d.map((x) => x.hrv_rmssd_milli), borderColor: "#2dd4bf", backgroundColor: "rgba(45,212,191,.1)", fill: true }] },
    options: baseLine(),
  });
  makeChart("chart-rhr", {
    type: "line",
    data: { labels, datasets: [{ data: d.map((x) => x.resting_heart_rate), borderColor: "#f87171", backgroundColor: "rgba(248,113,113,.1)", fill: true }] },
    options: baseLine(),
  });
  renderCalendar(d);
}

function renderCalendar(recovery) {
  const map = new Map(recovery.map((d) => [d.day, d.recovery_score]));
  const days = recovery.map((d) => d.day).sort();
  if (!days.length) { if (charts["chart-calendar"]) charts["chart-calendar"].destroy(); return; }
  const start = new Date(days[0] + "T00:00:00");
  start.setDate(start.getDate() - start.getDay());
  const end = new Date(days[days.length - 1] + "T00:00:00");
  const points = []; let weeks = 0, di = 0;
  for (let dt = new Date(start); dt <= end; dt.setDate(dt.getDate() + 1)) {
    const iso = localKey(dt), wk = Math.floor(di / 7);
    weeks = Math.max(weeks, wk);
    points.push({ x: wk, y: dt.getDay(), d: iso, v: map.has(iso) ? map.get(iso) : null });
    di++;
  }
  makeChart("chart-calendar", {
    type: "matrix",
    data: { datasets: [{ data: points, backgroundColor: (c) => recoveryColor(c.raw.v), borderWidth: 0,
      width: (c) => Math.max(4, ((c.chart.chartArea || {}).width || 0) / (weeks + 1) - 2),
      height: (c) => Math.max(4, ((c.chart.chartArea || {}).height || 0) / 7 - 2) }] },
    options: { responsive: true, maintainAspectRatio: false,
      plugins: { legend: { display: false }, tooltip: { callbacks: {
        title: (i) => i[0].raw.d, label: (i) => i.raw.v == null ? "no data" : `Recovery ${i.raw.v}%` } } },
      scales: { x: { type: "linear", min: -0.5, max: weeks + 0.5, grid: NOGRID, ticks: { display: false } },
        y: { type: "linear", min: -0.5, max: 6.5, reverse: true, grid: NOGRID,
          ticks: { stepSize: 1, callback: (v) => ["S", "M", "T", "W", "T", "F", "S"][v] || "" } } } },
  });
}

function renderSleep(d) {
  const labels = d.map((x) => x.day);
  const ds = (l, k, c) => ({ label: l, data: d.map((x) => x[k]), backgroundColor: c, stack: "s" });
  makeChart("chart-sleep", {
    type: "bar",
    data: { labels, datasets: [ds("Deep", "deep_hours", "#4f46e5"), ds("REM", "rem_hours", "#60a5fa"),
      ds("Light", "light_hours", "#93c5fd"), ds("Awake", "awake_hours", "#3f3f46")] },
    options: { responsive: true, maintainAspectRatio: false, plugins: { legend: { position: "bottom" } },
      scales: { x: { grid: NOGRID, stacked: true, ticks: { maxTicksLimit: 8 } }, y: { grid: GRID, stacked: true } } },
  });
  makeChart("chart-sleep-perf", {
    type: "line",
    data: { labels, datasets: [
      { label: "Performance", data: d.map((x) => x.performance), borderColor: "#60a5fa" },
      { label: "Efficiency", data: d.map((x) => x.efficiency), borderColor: "#34d399" }] },
    options: baseLine({ plugins: { legend: { position: "bottom" } }, scales: { x: { grid: NOGRID, ticks: { maxTicksLimit: 8 } }, y: { grid: GRID, min: 0, max: 100 } } }),
  });
  makeChart("chart-sleep-need", {
    type: "bar",
    data: { labels, datasets: [
      { label: "Slept", data: d.map((x) => x.hours), backgroundColor: "#60a5fa" },
      { label: "Needed", data: d.map((x) => x.need_hours), backgroundColor: "rgba(248,113,113,.55)" }] },
    options: { responsive: true, maintainAspectRatio: false, plugins: { legend: { position: "bottom" } },
      scales: { x: { grid: NOGRID, ticks: { maxTicksLimit: 8 } }, y: { grid: GRID } } },
  });
  makeChart("chart-resp", {
    type: "line",
    data: { labels, datasets: [{ data: d.map((x) => x.respiratory_rate), borderColor: "#818cf8", backgroundColor: "rgba(129,140,248,.1)", fill: true }] },
    options: baseLine(),
  });
}

function renderStrain(d) {
  const labels = d.map((x) => x.day);
  makeChart("chart-strain", {
    type: "bar",
    data: { labels, datasets: [{ data: d.map((x) => x.strain), backgroundColor: "#2dd4bf" }] },
    options: { responsive: true, maintainAspectRatio: false, plugins: { legend: { display: false } },
      scales: { x: { grid: NOGRID, ticks: { maxTicksLimit: 8 } }, y: { grid: GRID, min: 0, max: 21 } } },
  });
  makeChart("chart-cal", {
    type: "bar",
    data: { labels, datasets: [{ data: d.map((x) => x.calories), backgroundColor: "#fb923c" }] },
    options: { responsive: true, maintainAspectRatio: false, plugins: { legend: { display: false } },
      scales: { x: { grid: NOGRID, ticks: { maxTicksLimit: 8 } }, y: { grid: GRID } } },
  });
}

function renderActivities(sports, workouts) {
  $("sport-cards").innerHTML = sports.slice(0, 8).map((s) => `
    <div class="sport">
      <div class="ico">${SPORT_ICON(s.sport_name)}</div>
      <div class="name">${esc(titleCase(s.sport_name))}</div>
      <div class="row"><span>Sessions</span><b>${s.count}</b></div>
      <div class="row"><span>Avg strain</span><b>${s.avg_strain ?? "--"}</b></div>
      <div class="row"><span>Calories</span><b>${s.calories != null ? Math.round(s.calories).toLocaleString() : "--"}</b></div>
    </div>`).join("") || `<div class="muted">No activities in range</div>`;

  makeChart("chart-sports", {
    type: "bar",
    data: { labels: sports.map((s) => titleCase(s.sport_name)),
      datasets: [{ data: sports.map((s) => s.total_strain), backgroundColor: "#2dd4bf" }] },
    options: { indexAxis: "y", responsive: true, maintainAspectRatio: false,
      plugins: { legend: { display: false } }, scales: { x: { grid: GRID }, y: { grid: NOGRID } } },
  });

  const tb = $("workouts").querySelector("tbody");
  tb.innerHTML = workouts.length ? workouts.slice(0, 150).map((w) => `
    <tr>
      <td>${esc(w.day || "")}</td>
      <td>${SPORT_ICON(w.sport_name)} ${esc(titleCase(w.sport_name))}</td>
      <td class="r">${num(w.strain, 1)}</td>
      <td class="r">${w.minutes != null ? (w.minutes >= 60 ? Math.floor(w.minutes / 60) + "h " + String(w.minutes % 60).padStart(2, "0") + "m" : w.minutes + "m") : "—"}</td>
      <td class="r">${w.average_heart_rate ?? "—"}</td>
      <td class="r">${w.max_heart_rate ?? "—"}</td>
      <td class="r">${w.calories ?? "—"}</td>
      <td class="r">${w.distance_meter ? (w.distance_meter / 1000).toFixed(2) + " km" : "—"}</td>
    </tr>`).join("") : `<tr><td colspan="8" class="muted">No workouts in range</td></tr>`;
}

// ---- orchestration --------------------------------------------------------
async function load(auto = false) {
  if (loadInFlight) return;          // never overlap a load with the auto-refresh
  loadInFlight = true;
  suppressAnim = auto;               // silent (no animations) on a background refresh
  const days = $("range").value;
  try {
    const [status, latest, summary, recovery, sleep, strain, workouts, sports] = await Promise.all([
      getJSON("/api/status"), getJSON("/api/latest"), getJSON(`/api/summary?days=${days}`),
      getJSON(`/api/recovery?days=${days}`), getJSON(`/api/sleep?days=${days}`),
      getJSON(`/api/strain?days=${days}`), getJSON(`/api/workouts?days=${days}`),
      getJSON(`/api/sports?days=${days}`),
    ]);
    renderStatus(status);
    renderOverview(latest, summary, days, recovery, sleep, strain, sports);
    renderRecovery(recovery);
    renderSleep(sleep);
    renderStrain(strain);
    renderActivities(sports, workouts);
    showTab(tabFromHash());
  } catch (e) {
    if (!auto) {                     // don't flash an error banner on a silent refresh
      $("banner").textContent = "Error loading data: " + e.message;
      $("banner").classList.remove("hidden");
    }
  } finally {
    suppressAnim = false;
    loadInFlight = false;
  }
}

$("range").addEventListener("change", () => load());
$("sync").addEventListener("click", async () => {
  const b = $("sync"); b.disabled = true; b.textContent = "Syncing…";
  try {
    const r = await fetch("/api/sync", { method: "POST" });
    const body = await r.json();
    if (!r.ok && r.status !== 202) throw new Error(body.error || r.status);
  } catch (e) {
    $("banner").textContent = "Sync failed: " + e.message; $("banner").classList.remove("hidden");
  } finally { b.disabled = false; b.textContent = "Sync"; load(); }
});

showTab(tabFromHash());
load();

// Auto-refresh every 60s so the dashboard stays live without a manual reload (matches the
// native app). Skips when the tab is hidden, while you're typing into a field, or with a
// food entry pending — so a background refresh never interrupts what you're doing.
setInterval(() => {
  if (document.hidden) return;
  const el = document.activeElement;
  if (el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA")) return;
  load(true);
}, 60000);
