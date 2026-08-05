async function fetchJSON(url) {
  const res = await fetch(url, { cache: "no-store" });
  if (!res.ok) throw new Error(await res.text());
  return res.json();
}

// Match Excel report columns (Serving / TTFT / TPOT / ITL)
const METRICS = [
  { id: "successful_requests", label: "Successful requests" },
  { id: "request_throughput", label: "Request throughput" },
  { id: "output_token_throughput", label: "Output token throughput" },
  { id: "total_token_throughput", label: "Total Token throughput" },
  { id: "ttft_mean_ms", label: "Mean TTFT" },
  { id: "ttft_p50_ms", label: "Median TTFT" },
  { id: "ttft_p99_ms", label: "P99 TTFT" },
  { id: "tpot_mean_ms", label: "Mean TPOT" },
  { id: "tpot_p50_ms", label: "Median TPOT" },
  { id: "tpot_p99_ms", label: "P99 TPOT" },
  { id: "itl_mean_ms", label: "Mean ITL" },
  { id: "itl_p50_ms", label: "Median ITL" },
  { id: "itl_p99_ms", label: "P99 ITL" },
  { id: "success_rate", label: "success_rate" },
];

let activeMetric = "request_throughput";
const chart = echarts.init(document.getElementById("chart"));

function metricLabel(id) {
  const found = METRICS.find((m) => m.id === id);
  return found ? found.label : id;
}

function fillSelect(sel, values, preferred) {
  const prev = preferred !== undefined ? preferred : sel.value;
  sel.innerHTML = "";
  const list = (values || []).filter((v) => v !== null && v !== undefined && String(v) !== "");
  if (!list.length) {
    const opt = document.createElement("option");
    opt.value = "";
    opt.textContent = "(no data)";
    sel.appendChild(opt);
    sel.value = "";
    return;
  }
  list.forEach((v) => {
    const opt = document.createElement("option");
    opt.value = String(v);
    opt.textContent = String(v);
    sel.appendChild(opt);
  });
  if (prev && list.map(String).includes(String(prev))) {
    sel.value = String(prev);
  } else {
    sel.value = String(list[0]);
  }
}

function sortWorkloads(workloads) {
  const rank = (w) => {
    const s = String(w);
    if (/^sharegpt$/i.test(s)) return [2, s];
    let m = s.match(/^(\d+)\+(\d+)$/);
    if (m) return [0, Number(m[1]), Number(m[2])];
    m = s.match(/^random_isl(\d+)_osl(\d+)$/);
    if (m) return [0, Number(m[1]), Number(m[2])];
    return [1, s];
  };
  return [...workloads].sort((a, b) => {
    const ra = rank(a);
    const rb = rank(b);
    for (let i = 0; i < Math.max(ra.length, rb.length); i++) {
      const x = ra[i] ?? 0;
      const y = rb[i] ?? 0;
      if (x < y) return -1;
      if (x > y) return 1;
    }
    return 0;
  });
}

async function loadFilters(keepSelection = true) {
  const modelSel = document.getElementById("model");
  const workloadSel = document.getElementById("workload");
  const concurrencySel = document.getElementById("concurrency");

  const preferredModel = keepSelection ? modelSel.value : "";
  const preferredWorkload = keepSelection ? workloadSel.value : "";
  const preferredConcurrency = keepSelection ? concurrencySel.value : "";

  const allMeta = await fetchJSON("/api/meta");
  fillSelect(modelSel, allMeta.models || [], preferredModel);

  const model = modelSel.value;
  const meta = model
    ? await fetchJSON(`/api/meta?model=${encodeURIComponent(model)}`)
    : allMeta;

  fillSelect(workloadSel, sortWorkloads(meta.workloads || []), preferredWorkload);

  const conc = (meta.concurrencies || []).map(String);
  let pick = preferredConcurrency;
  if (!pick || !conc.includes(String(pick))) {
    pick = conc.includes("16") ? "16" : (conc[0] || "");
  }
  fillSelect(concurrencySel, conc, pick);
}

function makeLabel(point) {
  return `${point.model} | ${point.workload} | c=${point.concurrency} | ${point.engine_version}`;
}

function renderChart(metric, payload) {
  // One line per engine; all historical runs (any engine_version) are points on that line.
  const series = ["vllm", "sglang"].map((engine) => ({
    name: engine,
    type: "line",
    showSymbol: true,
    symbolSize: 6,
    connectNulls: false,
    data: (payload.series[engine] || []).map((p) => ({
      value: [p.created_at, p.value],
      extra: makeLabel(p),
    })),
  }));

  chart.setOption({
    backgroundColor: "transparent",
    tooltip: {
      trigger: "axis",
      formatter(params) {
        if (!params || !params.length) return "";
        const lines = [params[0].axisValueLabel];
        params.forEach((item) => {
          const val = item.data && item.data.value ? item.data.value[1] : item.value;
          const extra = item.data && item.data.extra ? ` (${item.data.extra})` : "";
          lines.push(`${item.seriesName}: ${val}${extra}`);
        });
        return lines.join("<br/>");
      },
    },
    legend: { textStyle: { color: "#8b9bb4" } },
    xAxis: {
      type: "time",
      axisLabel: {
        color: "#8b9bb4",
        formatter(value) {
          const d = new Date(value);
          const hh = String(d.getHours()).padStart(2, "0");
          const mm = String(d.getMinutes()).padStart(2, "0");
          const ss = String(d.getSeconds()).padStart(2, "0");
          return `${hh}:${mm}:${ss}`;
        },
      },
    },
    yAxis: {
      type: "value",
      name: metricLabel(metric),
      axisLabel: { color: "#8b9bb4" },
      splitLine: { lineStyle: { color: "#2a3548" } },
    },
    series,
  }, true);
}

async function refresh() {
  await loadFilters(true);

  const model = document.getElementById("model").value;
  const workload = document.getElementById("workload").value;
  const concurrency = document.getElementById("concurrency").value;
  if (!model || !workload || !concurrency) {
    renderChart(activeMetric, { series: { vllm: [], sglang: [] } });
    return;
  }

  const qs = new URLSearchParams({
    metric: activeMetric,
    model,
    workload,
    concurrency,
  });
  const data = await fetchJSON(`/api/trends/all?${qs.toString()}`);
  renderChart(activeMetric, data);
}

function renderTabs() {
  const container = document.getElementById("metric-tabs");
  container.innerHTML = "";
  METRICS.forEach((metric) => {
    const btn = document.createElement("button");
    btn.className = `tab-btn${metric.id === activeMetric ? " active" : ""}`;
    btn.textContent = metric.label;
    btn.addEventListener("click", async () => {
      activeMetric = metric.id;
      renderTabs();
      await refresh();
    });
    container.appendChild(btn);
  });
}

document.getElementById("model").addEventListener("change", () => refresh().catch(alert));
document.getElementById("workload").addEventListener("change", () => refresh().catch(alert));
document.getElementById("concurrency").addEventListener("change", () => refresh().catch(alert));
window.addEventListener("resize", () => chart.resize());

// ---------- Records list (bottom section) ----------

const RECORD_COLUMNS = [
  { id: "run_date", label: "Date" },
  { id: "engine", label: "Engine" },
  { id: "engine_version", label: "Version" },
  { id: "model", label: "Model" },
  { id: "workload", label: "Workload" },
  { id: "concurrency", label: "Concurrency" },
  { id: "successful_requests", label: "Successful requests" },
  { id: "request_throughput", label: "Request throughput" },
  { id: "output_token_throughput", label: "Output token tps" },
  { id: "total_token_throughput", label: "Total token tps" },
  { id: "ttft_mean_ms", label: "Mean TTFT" },
  { id: "ttft_p50_ms", label: "Median TTFT" },
  { id: "ttft_p99_ms", label: "P99 TTFT" },
  { id: "tpot_mean_ms", label: "Mean TPOT" },
  { id: "tpot_p50_ms", label: "Median TPOT" },
  { id: "tpot_p99_ms", label: "P99 TPOT" },
  { id: "itl_mean_ms", label: "Mean ITL" },
  { id: "itl_p50_ms", label: "Median ITL" },
  { id: "itl_p99_ms", label: "P99 ITL" },
  { id: "success_rate", label: "Success rate" },
];

function fillFilterSelect(sel, values, allLabel) {
  const prev = sel.value;
  sel.innerHTML = "";
  const allOpt = document.createElement("option");
  allOpt.value = "";
  allOpt.textContent = allLabel;
  sel.appendChild(allOpt);
  (values || []).forEach((v) => {
    const opt = document.createElement("option");
    opt.value = String(v);
    opt.textContent = String(v);
    sel.appendChild(opt);
  });
  if (prev && (values || []).map(String).includes(String(prev))) {
    sel.value = String(prev);
  } else {
    sel.value = "";
  }
}

function formatCell(value) {
  if (value === null || value === undefined || value === "") return "-";
  if (typeof value === "number" && !Number.isInteger(value)) {
    return value.toFixed(2);
  }
  return String(value);
}

function renderRecordsTable(records) {
  const thead = document.querySelector("#rec-table thead");
  const tbody = document.querySelector("#rec-table tbody");

  thead.innerHTML = "";
  const headRow = document.createElement("tr");
  RECORD_COLUMNS.forEach((col) => {
    const th = document.createElement("th");
    th.textContent = col.label;
    headRow.appendChild(th);
  });
  thead.appendChild(headRow);

  tbody.innerHTML = "";
  if (!records.length) {
    const tr = document.createElement("tr");
    const td = document.createElement("td");
    td.colSpan = RECORD_COLUMNS.length;
    td.className = "empty-cell";
    td.textContent = "No records match the current filters";
    tr.appendChild(td);
    tbody.appendChild(tr);
    return;
  }
  records.forEach((rec) => {
    const tr = document.createElement("tr");
    RECORD_COLUMNS.forEach((col) => {
      const td = document.createElement("td");
      td.textContent = formatCell(rec[col.id]);
      tr.appendChild(td);
    });
    tbody.appendChild(tr);
  });
}

async function refreshRecords() {
  const model = document.getElementById("rec-model").value;
  const engine = document.getElementById("rec-engine").value;
  const engineVersion = document.getElementById("rec-engine-version").value;
  const date = document.getElementById("rec-date").value;

  const qs = new URLSearchParams();
  if (model) qs.set("model", model);
  if (engine) qs.set("engine", engine);
  if (engineVersion) qs.set("engine_version", engineVersion);
  if (date) qs.set("date", date);

  const data = await fetchJSON(`/api/records?${qs.toString()}`);
  document.getElementById("rec-count").textContent = `${data.count} record(s)`;
  renderRecordsTable(data.records || []);
}

function recordFilterValues() {
  return {
    model: document.getElementById("rec-model").value,
    engine: document.getElementById("rec-engine").value,
    engineVersion: document.getElementById("rec-engine-version").value,
  };
}

async function loadRecordFilters() {
  // Cascade: options at each level are narrowed by the selections above it.
  // Refilling may reset an invalidated selection to "All", which changes the
  // downstream lists, so repeat until selections are stable (2 passes max).
  for (let i = 0; i < 3; i++) {
    const sel = recordFilterValues();
    const qs = new URLSearchParams();
    if (sel.model) qs.set("model", sel.model);
    if (sel.engine) qs.set("engine", sel.engine);
    if (sel.engineVersion) qs.set("engine_version", sel.engineVersion);

    const meta = await fetchJSON(`/api/records/meta?${qs}`);
    fillFilterSelect(document.getElementById("rec-model"), meta.models, "All models");
    fillFilterSelect(document.getElementById("rec-engine"), meta.engines, "All engines");
    fillFilterSelect(document.getElementById("rec-engine-version"), meta.engine_versions, "All versions");
    fillFilterSelect(document.getElementById("rec-date"), meta.dates, "All dates");

    const after = recordFilterValues();
    if (after.model === sel.model && after.engine === sel.engine
        && after.engineVersion === sel.engineVersion) break;
  }
}

["rec-model", "rec-engine", "rec-engine-version", "rec-date"].forEach((id) => {
  document.getElementById(id).addEventListener("change", () =>
    loadRecordFilters().then(refreshRecords).catch(alert));
});

// ---------- Concurrency bar-chart page ----------

let ccChart = null;
let ccActiveMetric = "request_throughput";

function ccSelectValues() {
  return {
    model: document.getElementById("cc-model").value,
    engine: document.getElementById("cc-engine").value,
    engineVersion: document.getElementById("cc-engine-version").value,
    date: document.getElementById("cc-date").value,
    workload: document.getElementById("cc-workload").value,
  };
}

async function loadCcFilters() {
  const modelSel = document.getElementById("cc-model");
  const engineSel = document.getElementById("cc-engine");
  const versionSel = document.getElementById("cc-engine-version");
  const dateSel = document.getElementById("cc-date");
  const workloadSel = document.getElementById("cc-workload");

  // Cascade: each level only offers values that exist under the previous selections.
  const m0 = await fetchJSON("/api/concurrency/meta");
  fillSelect(modelSel, m0.models);

  const qs1 = new URLSearchParams({ model: modelSel.value });
  const m1 = await fetchJSON(`/api/concurrency/meta?${qs1}`);
  fillSelect(engineSel, m1.engines);

  const qs2 = new URLSearchParams({ model: modelSel.value, engine: engineSel.value });
  const m2 = await fetchJSON(`/api/concurrency/meta?${qs2}`);
  fillSelect(versionSel, m2.engine_versions);

  const qs3 = new URLSearchParams({
    model: modelSel.value,
    engine: engineSel.value,
    engine_version: versionSel.value,
  });
  const m3 = await fetchJSON(`/api/concurrency/meta?${qs3}`);
  fillSelect(dateSel, m3.dates);

  const qs4 = new URLSearchParams({
    model: modelSel.value,
    engine: engineSel.value,
    engine_version: versionSel.value,
    date: dateSel.value,
  });
  const m4 = await fetchJSON(`/api/concurrency/meta?${qs4}`);
  fillSelect(workloadSel, sortWorkloads(m4.workloads || []));
}

function renderCcChart(metric, payload) {
  if (!ccChart) return;
  const points = payload.points || [];
  ccChart.setOption({
    backgroundColor: "transparent",
    title: {
      text: points.length
        ? `${payload.model} | ${payload.engine} ${payload.engine_version} | ${payload.workload} | ${payload.date}`
        : "No data for the current filters",
      left: "center",
      textStyle: { color: "#8b9bb4", fontSize: 13, fontWeight: "normal" },
    },
    tooltip: {
      trigger: "axis",
      axisPointer: { type: "shadow" },
      formatter(params) {
        if (!params || !params.length) return "";
        const p = params[0];
        return `Concurrency ${p.axisValue}<br/>${metricLabel(metric)}: ${p.value}`;
      },
    },
    grid: { left: 60, right: 30, top: 60, bottom: 40 },
    xAxis: {
      type: "category",
      name: "Concurrency",
      data: points.map((p) => String(p.concurrency)),
      axisLabel: { color: "#8b9bb4" },
      nameTextStyle: { color: "#8b9bb4" },
    },
    yAxis: {
      type: "value",
      name: metricLabel(metric),
      axisLabel: { color: "#8b9bb4" },
      nameTextStyle: { color: "#8b9bb4" },
      splitLine: { lineStyle: { color: "#2a3548" } },
    },
    series: [{
      type: "bar",
      data: points.map((p) => p.value),
      barMaxWidth: 48,
      itemStyle: { color: "#3d8bfd", borderRadius: [3, 3, 0, 0] },
      label: { show: true, position: "top", color: "#8b9bb4" },
    }],
  }, true);
}

async function refreshCc() {
  await loadCcFilters();
  const sel = ccSelectValues();
  if (!sel.model || !sel.engine || !sel.engineVersion || !sel.date || !sel.workload) {
    renderCcChart(ccActiveMetric, { points: [] });
    return;
  }
  const qs = new URLSearchParams({
    model: sel.model,
    engine: sel.engine,
    engine_version: sel.engineVersion,
    date: sel.date,
    workload: sel.workload,
    metric: ccActiveMetric,
  });
  const data = await fetchJSON(`/api/concurrency?${qs}`);
  renderCcChart(ccActiveMetric, data);
}

function renderCcTabs() {
  const container = document.getElementById("cc-metric-tabs");
  container.innerHTML = "";
  METRICS.forEach((metric) => {
    const btn = document.createElement("button");
    btn.className = `tab-btn${metric.id === ccActiveMetric ? " active" : ""}`;
    btn.textContent = metric.label;
    btn.addEventListener("click", async () => {
      ccActiveMetric = metric.id;
      renderCcTabs();
      await refreshCc();
    });
    container.appendChild(btn);
  });
}

["cc-model", "cc-engine", "cc-engine-version", "cc-date", "cc-workload"].forEach((id) => {
  document.getElementById(id).addEventListener("change", () => refreshCc().catch(alert));
});

// ---------- Page tabs ----------

let ccPageInitialized = false;

function showPage(page) {
  document.querySelectorAll(".page-tab").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.page === page);
  });
  document.getElementById("page-trend").classList.toggle("hidden", page !== "trend");
  document.getElementById("page-concurrency").classList.toggle("hidden", page !== "concurrency");

  if (page === "concurrency") {
    if (!ccPageInitialized) {
      ccPageInitialized = true;
      // Init only when visible, otherwise echarts measures a 0-sized container.
      ccChart = echarts.init(document.getElementById("cc-chart"));
      window.addEventListener("resize", () => ccChart && ccChart.resize());
      renderCcTabs();
      refreshCc().catch(alert);
    } else {
      ccChart.resize();
    }
  } else {
    chart.resize();
  }
}

document.querySelectorAll(".page-tab").forEach((btn) => {
  btn.addEventListener("click", () => showPage(btn.dataset.page));
});

renderTabs();
refresh().catch(alert);
loadRecordFilters().then(refreshRecords).catch(alert);
