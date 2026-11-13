// The browser calls the fetcher through the nginx on the bastion (same origin, no CORS): GET /api/pois.
// Overpass can be slow: the fetcher may spend over a minute going through all its endpoints.
const REQUEST_TIMEOUT_MS = 100000;

const form = document.getElementById("form");
const cancelBtn = document.getElementById("cancel");
const statusEl = document.getElementById("status");
const resultsEl = document.getElementById("results");

const map = L.map("map").setView([50.4501, 30.5234], 13);
L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
  maxZoom: 19,
  attribution: "&copy; OpenStreetMap contributors",
}).addTo(map);
const markers = L.layerGroup().addTo(map);
let area = null;
let controller = null;

function setStatus(text, isError = false) {
  statusEl.textContent = text;
  statusEl.classList.toggle("error", isError);
}

// Circle that shows the search area; follows the form fields.
function drawArea() {
  const lat = parseFloat(form.lat.value);
  const lon = parseFloat(form.lon.value);
  const radius = parseInt(form.radius.value, 10);
  if (!Number.isFinite(lat) || !Number.isFinite(lon) || !(radius > 0)) return;
  if (area) map.removeLayer(area);
  area = L.circle([lat, lon], { radius, weight: 1 }).addTo(map);
}

map.on("click", (e) => {
  form.lat.value = e.latlng.lat.toFixed(5);
  form.lon.value = e.latlng.lng.toFixed(5);
  drawArea();
});
for (const name of ["lat", "lon", "radius"]) form[name].addEventListener("input", drawArea);

// OSM tags are user-supplied text: build the DOM with textContent, never innerHTML.
function popupFor(poi) {
  const box = document.createElement("div");
  const title = document.createElement("strong");
  title.textContent = poiName(poi);
  box.append(title);
  for (const key of ["opening_hours", "phone", "website"]) {
    const value = poi.tags[key];
    if (!value) continue;
    const row = document.createElement("div");
    if (key === "website" && /^https?:\/\//.test(value)) {
      const link = document.createElement("a");
      link.href = value;
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      link.textContent = value;
      row.append(link);
    } else {
      row.textContent = `${key}: ${value}`;
    }
    box.append(row);
  }
  return box;
}

function poiName(poi) {
  return poi.tags["name:uk"] || poi.tags.name || "(без назви)";
}

function render(pois) {
  markers.clearLayers();
  resultsEl.replaceChildren();
  for (const poi of pois) {
    const marker = L.circleMarker([poi.lat, poi.lon], { radius: 7 }).bindPopup(popupFor(poi));
    markers.addLayer(marker);
    const item = document.createElement("li");
    item.textContent = poiName(poi);
    item.addEventListener("click", () => {
      map.panTo([poi.lat, poi.lon]);
      marker.openPopup();
    });
    resultsEl.append(item);
  }
  if (area) map.fitBounds(area.getBounds());
  setStatus(`Знайдено: ${pois.length}`);
}

async function describeError(res) {
  if (res.status === 400) return `Некоректні параметри: ${(await res.text()).trim()}`;
  if (res.status === 429) return "Забагато запитів, спробуйте за хвилину.";
  if (res.status === 502 || res.status === 504) return "Джерело даних тимчасово недоступне, спробуйте пізніше.";
  return `Помилка сервера (${res.status}).`;
}

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  drawArea();
  controller?.abort();
  const ctl = (controller = new AbortController());
  const timer = setTimeout(() => ctl.abort(), REQUEST_TIMEOUT_MS);
  const params = new URLSearchParams({
    lat: form.lat.value,
    lon: form.lon.value,
    radius: form.radius.value,
    type: form.type.value,
  });
  setStatus("Завантаження (перший запит може тривати до півхвилини)...");
  cancelBtn.hidden = false;
  try {
    const res = await fetch(`/api/pois?${params}`, { signal: ctl.signal });
    if (!res.ok) throw new Error(await describeError(res));
    render(await res.json());
  } catch (err) {
    if (controller !== ctl) return; // superseded by a newer search
    if (err.name === "AbortError") setStatus("Запит скасовано або перевищено час очікування.", true);
    else setStatus(err.message || "Не вдалося виконати запит.", true);
  } finally {
    clearTimeout(timer);
    if (controller === ctl) cancelBtn.hidden = true;
  }
});

cancelBtn.addEventListener("click", () => controller?.abort());
