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

renderTabs();
refresh().catch(alert);
