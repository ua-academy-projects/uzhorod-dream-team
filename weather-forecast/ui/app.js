"use strict";

const button = document.querySelector("#collect");
const status = document.querySelector("#status");
let collecting = false;
let refreshing = false;
const chartPeriod = document.querySelector("#chart-period");
let currentCity = null;
let chartRequest = 0;

function showStatus(message, error = false) {
  status.textContent = message;
  status.classList.toggle("error", error);
}

function utc(value) {
  return new Date(value).toISOString().replace("T", " ").slice(0, 19);
}

async function api(path, options = {}, allowEmpty = false, timeoutMs = 25000) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(path, { ...options, cache: "no-store", signal: controller.signal });
    const data = await response.json();
    if (allowEmpty && response.status === 404) return null;
    if (!response.ok) {
      const error = new Error(data.error || `HTTP ${response.status}`);
      error.status = response.status;
      error.requestId = data.request_id;
      throw error;
    }
    return data;
  } catch (error) {
    if (error.name === "AbortError") throw new Error("History did not respond in time.");
    if (error instanceof TypeError) throw new Error("Could not connect to History.");
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

function renderLatest(snapshot) {
  currentCity = snapshot ? snapshot.city : null;
  document.querySelector("#temperature").textContent = snapshot ? `${snapshot.temperature_c.toFixed(1)} °C` : "—";
  document.querySelector("#humidity").textContent = snapshot ? `${snapshot.humidity_percent} %` : "—";
  document.querySelector("#wind").textContent = snapshot ? `${snapshot.wind_speed_kmh.toFixed(1)} km/h` : "—";
  document.querySelector("#weather-time").textContent = snapshot ? utc(snapshot.weather_time) : "—";
  document.querySelector("#fetched-at").textContent = snapshot ? utc(snapshot.fetched_at) : "—";
}

function renderHistory(snapshots) {
  const body = document.querySelector("#history");
  body.replaceChildren();
  document.querySelector("#history-empty").hidden = snapshots.length !== 0;
  for (const snapshot of snapshots) {
    const row = document.createElement("tr");
    const values = [snapshot.id, utc(snapshot.weather_time), utc(snapshot.fetched_at),
      snapshot.temperature_c.toFixed(1), snapshot.humidity_percent, snapshot.wind_speed_kmh.toFixed(1)];
    for (const value of values) {
      const cell = document.createElement("td");
      cell.textContent = value;
      row.append(cell);
    }
    body.append(row);
  }
}

function svgElement(name, attributes, text) {
  const element = document.createElementNS("http://www.w3.org/2000/svg", name);
  for (const [key, value] of Object.entries(attributes)) element.setAttribute(key, value);
  if (text !== undefined) element.textContent = text;
  return element;
}

function renderChart(snapshots) {
  const chart = document.querySelector("#chart");
  chart.replaceChildren();
  // SVG needs its hidden attribute changed explicitly.
  chart.toggleAttribute("hidden", snapshots.length === 0);
  document.querySelector("#chart-empty").hidden = snapshots.length !== 0;
  if (!snapshots.length) return;
  const points = [...snapshots].sort((a, b) => Date.parse(a.weather_time) - Date.parse(b.weather_time));
  const temperatures = points.map(p => p.temperature_c);
  const last = Date.now();
  const duration = { "24h": 24, "7d": 168, "30d": 720 }[chartPeriod.value] * 3600000;
  // The first partial hour may begin just before the selected period.
  const first = Math.floor((last - duration) / 3600000) * 3600000;
  const low = Math.min(...temperatures) - 1, high = Math.max(...temperatures) + 1;
  const left = 65, right = 875, top = 20, bottom = 225;
  const x = time => first === last ? (left + right) / 2 : left + (time - first) / (last - first) * (right - left);
  const y = temp => bottom - (temp - low) / (high - low) * (bottom - top);
  const label = { fill: "var(--muted)", "font-size": 13, "font-family": "system-ui, sans-serif" };
  for (let i = 0; i <= 4; i++) {
    const temp = low + (high - low) * i / 4;
    chart.append(svgElement("line", { x1: left, y1: y(temp), x2: right, y2: y(temp), stroke: "var(--grid)" }));
    chart.append(svgElement("text", { ...label, x: left - 10, y: y(temp) + 4, "text-anchor": "end" }, `${temp.toFixed(1)}°`));
  }
  const coordinates = points.map(p => `${x(Date.parse(p.weather_time))},${y(p.temperature_c)}`).join(" ");
  chart.append(svgElement("polygon", { points: `${x(Date.parse(points[0].weather_time))},${bottom} ${coordinates} ${x(Date.parse(points[points.length - 1].weather_time))},${bottom}`,
    fill: "var(--accent)", "fill-opacity": 0.1 }));
  chart.append(svgElement("line", { x1: left, y1: bottom, x2: right, y2: bottom, stroke: "var(--axis)" }));
  chart.append(svgElement("polyline", { points: coordinates,
    fill: "none", stroke: "var(--accent)", "stroke-width": 2 }));
  for (const point of points) {
    const dot = svgElement("circle", { cx: x(Date.parse(point.weather_time)), cy: y(point.temperature_c), r: 3, fill: "var(--accent)" });
    dot.append(svgElement("title", {}, `${utc(point.weather_time)} UTC: ${point.temperature_c.toFixed(1)} °C`));
    chart.append(dot);
  }
  chart.append(svgElement("text", { ...label, x: left, y: 258 }, utc(first)));
  chart.append(svgElement("text", { ...label, x: right, y: 258, "text-anchor": "end" }, `${utc(last)} UTC`));
  chart.append(svgElement("desc", {}, `${currentCity}: hourly temperature from ${Math.min(...temperatures).toFixed(1)} to ${Math.max(...temperatures).toFixed(1)} °C. ${points.length} hourly points.`));
}

async function loadChart() {
  const request = ++chartRequest;
  const chartStatus = document.querySelector("#chart-status");
  chartStatus.classList.remove("error");
  if (!currentCity) {
    renderChart([]);
    chartStatus.textContent = "Collect weather to start building temperature history.";
    chartPeriod.disabled = false;
    return;
  }
  const city = currentCity;
  chartPeriod.disabled = true;
  chartStatus.textContent = `Loading temperature history for ${city}…`;
  try {
    const points = await api(`/api/temperature?city=${encodeURIComponent(city)}&period=${chartPeriod.value}`);
    if (request !== chartRequest) return;
    renderChart(points);
    chartStatus.textContent = points.length === 1
      ? `${city}: one hourly point. A line will appear when more data is collected.`
      : `${city}: ${points.length} hourly points in the selected period.`;
  } catch (error) {
    if (request !== chartRequest) return;
    renderChart([]);
    document.querySelector("#chart-empty").hidden = true;
    chartStatus.textContent = `Could not load chart: ${error.message}`;
    chartStatus.classList.add("error");
  } finally {
    if (request === chartRequest) chartPeriod.disabled = false;
  }
}

chartPeriod.addEventListener("change", loadChart);

async function refresh() {
  if (refreshing) return null;
  refreshing = true;
  button.disabled = true;
  showStatus("Loading history…");
  try {
    const [latest, history] = await Promise.all([
      api("/api/latest", {}, true), api("/api/history?limit=100"),
    ]);
    renderLatest(latest);
    renderHistory(history);
    await loadChart();
    showStatus(history.length ? `Showing ${history.length} snapshots. Updated at ${new Date().toISOString().slice(11, 19)} UTC.` : "History is empty. Collect the first snapshot.");
    return history;
  } catch (error) {
    showStatus(`Error: ${error.message} Displayed data may be outdated.`, true);
    return null;
  } finally {
    refreshing = false;
    button.disabled = collecting;
  }
}

async function collectAndWait() {
  let requestId;
  let message = "Weather job queued. Waiting for Fetcher…";
  try {
    const job = await api("/api/collect", { method: "POST" });
    requestId = job.request_id;
  } catch (error) {
    // A conflict means another page already queued the current collection.
    // An uncertain publication also has a persisted ID that can be checked.
    if ((error.status === 409 || error.status === 503) && error.requestId) {
      requestId = error.requestId;
      message = error.status === 503
        ? "RabbitMQ publication is not confirmed. Checking the saved job…"
        : "Another collection is already queued. Waiting for its result…";
    } else {
      throw error;
    }
  }
  if (!requestId) throw new Error("History returned no request ID.");
  const deadline = Date.now() + 125000;
  showStatus(message);
  while (Date.now() < deadline) {
    const job = await api(`/api/jobs/${encodeURIComponent(requestId)}`, {}, false,
      Math.min(25000, deadline - Date.now()));
    if (job.status === "completed") return;
    if (job.status === "failed") throw new Error(job.error?.message || "Weather job failed.");
    if (job.status !== "queued") throw new Error("History returned an invalid job status.");
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  throw new Error("Weather job is still pending. Try again later; saved data remains available.");
}

async function initialize() {
  // Collect on every page load before displaying saved snapshots.
  collecting = true;
  button.disabled = true;
  button.textContent = "Collecting…";
  showStatus("Collecting current weather through Fetcher…");
  try {
    await collectAndWait();
    await refresh();
  } catch (error) {
    const history = await refresh();
    const fallback = history === null
      ? " Saved history could not be loaded either."
      : " Showing saved history; the weather data may be outdated.";
    showStatus(`Could not collect current weather: ${error.message}${fallback}`, true);
  } finally {
    collecting = false;
    button.disabled = refreshing;
    button.textContent = "Collect now";
  }
}

button.addEventListener("click", async () => {
  if (collecting || refreshing) return;
  collecting = true;
  button.disabled = true;
  button.textContent = "Collecting…";
  showStatus("Collecting weather through Fetcher…");
  try {
    await collectAndWait();
    await refresh();
  } catch (error) {
    showStatus(`Could not collect weather: ${error.message}`, true);
  } finally {
    collecting = false;
    button.disabled = refreshing;
    button.textContent = "Collect now";
  }
});

initialize();
// A page restored with the browser's Back button does not rerun this script.
window.addEventListener("pageshow", event => {
  if (event.persisted && !collecting && !refreshing) initialize();
});
// Only the chart refreshes hourly; current measurements update on user actions.
setInterval(() => { if (!collecting && !refreshing && currentCity) loadChart(); }, 3600000);


const themeControl = document.querySelector("#theme");
const preferencesStatus = document.querySelector("#preferences-status");

async function loadPreferences() {
  themeControl.disabled = true;
  try {
    const preferences = await api("/api/preferences", {}, false, 5000);
    document.documentElement.dataset.theme = preferences.theme;
    themeControl.value = preferences.theme;
    preferencesStatus.hidden = true;
  } catch (error) {
    preferencesStatus.textContent = "Could not load theme settings. Weather is still available.";
    preferencesStatus.hidden = false;
  } finally {
    themeControl.disabled = false;
  }
}

themeControl.addEventListener("change", async () => {
  const theme = themeControl.value;
  document.documentElement.dataset.theme = theme;
  themeControl.disabled = true;
  try {
    await api("/api/preferences", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ theme }) }, false, 5000);
    preferencesStatus.hidden = true;
  } catch (error) {
    preferencesStatus.textContent = "Theme changed for this page, but could not be saved.";
    preferencesStatus.hidden = false;
  } finally {
    themeControl.disabled = false;
  }
});

loadPreferences();
