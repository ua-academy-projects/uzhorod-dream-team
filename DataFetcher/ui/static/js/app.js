const MAX_POINTS = 50;
const REFRESH_MS = 10_000;
const valueNode = document.getElementById('current-value');
const timeNode = document.getElementById('last-update');
const rowsNode = document.getElementById('history-rows');
const errorNode = document.getElementById('error-message');
const statusNode = document.getElementById('connection');
const recordCountNode = document.getElementById('record-count');
const sourceSelect = document.getElementById('source-select');
const themeToggle = document.getElementById('theme-toggle');
const languageSelect = document.getElementById('language-select');
const fontSelect = document.getElementById('font-select');
let chart;
let lastTimestamp = 0;
let currentSource = null;
let requestId = 0;
let preferences = { theme: 'light', language: 'en', font: 'system' };
const translations = {
  en: { eyebrow: 'Live snapshots', current: 'Current value · USD', update: 'Last update', waiting: 'Waiting for data', chart: 'Value over time', history: 'History', time: 'Time', value: 'Value (USD)', connected: 'Connected', issue: 'Connection issue', none: 'No snapshots yet', records: 'records', error: 'Unable to load historical data. Please try again later.' },
  ua: { eyebrow: 'Поточні дані', current: 'Поточне значення · USD', update: 'Останнє оновлення', waiting: 'Очікування даних', chart: 'Зміна значення', history: 'Історія', time: 'Час', value: 'Значення (USD)', connected: 'З’єднано', issue: 'Проблема з’єднання', none: 'Даних поки немає', records: 'записів', error: 'Не вдалося завантажити історію. Спробуйте пізніше.' },
};
function applyPreferences(next) {
  preferences = { ...preferences, ...next };
  applyTheme(preferences.theme);
  document.documentElement.lang = preferences.language === 'ua' ? 'uk' : 'en';
  document.documentElement.dataset.font = preferences.font;
  languageSelect.value = preferences.language;
  fontSelect.value = preferences.font;
  const t = translations[preferences.language];
  document.getElementById('eyebrow').textContent = t.eyebrow;
  document.getElementById('current-label').textContent = t.current;
  document.getElementById('update-label').textContent = t.update;
  document.getElementById('chart-title').textContent = t.chart;
  document.getElementById('history-title').textContent = t.history;
  document.querySelector('thead th:first-child').textContent = t.time;
  document.querySelector('thead th:last-child').textContent = t.value;
  if (timeNode.textContent === 'Waiting for data' || timeNode.textContent === 'Очікування даних') timeNode.textContent = t.waiting;
  errorNode.textContent = t.error;
  if (chart) { chart.data.datasets[0].label = t.value; chart.update('none'); }
}
async function savePreferences() {
  try {
    const response = await fetch('/api/preferences', { method: 'PUT', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(preferences) });
    if (!response.ok) throw new Error(`Preference save failed (${response.status})`);
  } catch (err) { console.error('Unable to save preferences', err); }
}
async function loadPreferences() {
  try {
    const response = await fetch('/api/preferences', { credentials: 'same-origin', cache: 'no-store' });
    if (!response.ok) throw new Error(`Preference load failed (${response.status})`);
    const result = await response.json();
    if (!result.cache_available) console.error('Preference cache is unavailable; using durable stored preferences');
    applyPreferences(result.preferences || {});
  } catch (err) { console.error('Unable to load preferences', err); }
}
/* THEME */
function getThemeColor(name) {
  return getComputedStyle(document.documentElement)
    .getPropertyValue(name)
    .trim();
}
function updateChartTheme() {
  if (!chart) {
    return;
  }
  chart.options.scales.x.ticks.color =
    getThemeColor('--chart-muted');
  chart.options.scales.y.ticks.color =
    getThemeColor('--chart-muted');
  chart.options.scales.y.grid.color =
    getThemeColor('--chart-grid');
  chart.data.datasets[0].borderColor =
    getThemeColor('--chart-line');
  chart.data.datasets[0].backgroundColor =
    getThemeColor('--chart-fill');
  chart.update();
}
function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  themeToggle.setAttribute(
    'aria-pressed',
    String(theme === 'dark')
  );
  updateChartTheme();
}
themeToggle.addEventListener('click', () => {
  const currentTheme =
    document.documentElement.dataset.theme;
  const newTheme =
    currentTheme === 'dark'
      ? 'light'
      : 'dark';
  applyPreferences({ theme: newTheme });
  savePreferences();
});
languageSelect.addEventListener('change', () => { applyPreferences({ language: languageSelect.value }); savePreferences(); });
fontSelect.addEventListener('change', () => { applyPreferences({ font: fontSelect.value }); savePreferences(); });
/* FORMAT VALUE */
function formatValue(value) {
  return Number(value).toLocaleString(
    undefined,
    {
      maximumFractionDigits: 2,
    }
  );
}
/* CHART */
function createChart() {
  chart = new Chart(
    document.getElementById('history-chart'),
    {
      type: 'line',
      data: {
        labels: [],
        datasets: [
          {
            label: 'Value (USD)',
            data: [],
            borderColor:
              getThemeColor('--chart-line'),
            backgroundColor:
              getThemeColor('--chart-fill'),
            fill: true,
            tension: 0.4,
            borderWidth: 2,
            pointRadius: 0,
            pointHoverRadius: 5,
            pointBackgroundColor:
              getThemeColor('--surface'),
            pointBorderColor:
              getThemeColor('--chart-line'),
            pointBorderWidth: 2,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: {
          mode: 'index',
          intersect: false,
        },
        plugins: {
          legend: {
            display: false,
          },
        },
        scales: {
          x: {
            grid: {
              display: false,
            },
            ticks: {
              color:
                getThemeColor('--chart-muted'),
            },
          },
          y: {
            beginAtZero: false,
            grid: {
              color:
                getThemeColor('--chart-grid'),
              drawBorder: false,
            },
            ticks: {
              color:
                getThemeColor('--chart-muted'),
            },
          },
        },
      },
    }
  );
}
/* RESET */
function resetView() {
  lastTimestamp = 0;
  rowsNode.replaceChildren();
  if (chart) {
    chart.data.labels.length = 0;
    chart.data.datasets[0].data.length = 0;
    chart.update('none');
  }
  valueNode.textContent = '—';
  timeNode.textContent =
    'Waiting for data';
  recordCountNode.textContent =
    '0 records';
}
/* TABLE */
function appendTable(fresh) {
  const rows = fresh.map((record) => {
    const row =
      document.createElement('tr');
    const timeCell =
      document.createElement('td');
    const valueCell =
      document.createElement('td');
    timeCell.textContent =
      new Date(
        record.recorded_at
      ).toLocaleString();
    valueCell.textContent =
      formatValue(record.value);
    row.append(
      timeCell,
      valueCell
    );
    return row;
  });
  rowsNode.prepend(...rows);
  while (
    rowsNode.children.length > MAX_POINTS
  ) {
    rowsNode.lastElementChild.remove();
  }
}
/* APPEND CHART */
function appendChart(fresh) {
  if (!chart) {
    createChart();
  }
  const labels =
    chart.data.labels;
  const data =
    chart.data.datasets[0].data;
  [...fresh]
    .reverse()
    .forEach((record) => {
      labels.push(
        new Date(
          record.recorded_at
        ).toLocaleTimeString()
      );
      data.push(record.value);
    });
  while (
    labels.length > MAX_POINTS
  ) {
    labels.shift();
    data.shift();
  }
  chart.update('none');
}
/* SOURCES */
async function loadSources() {
  try {
    const response = await fetch(
      '/api/sources',
      {
        cache: 'no-store',
      }
    );
    if (!response.ok) {
      throw new Error(
        'Sources unavailable'
      );
    }
    const result =
      await response.json();
    const sources =
      result.data || [];
    if (sources.length === 0) {
      return;
    }
    sourceSelect.replaceChildren(
      ...sources.map((name) => {
        const option =
          document.createElement('option');
        option.value = name;
        option.textContent =
          name.toUpperCase();
        return option;
      })
    );
    currentSource =
      sources.includes('btc')
        ? 'btc'
        : sources[0];
    sourceSelect.value =
      currentSource;
  } catch (err) {
    console.error(err);
  }
}
/* HISTORY */
async function refreshHistory() {
  if (!currentSource) {
    return;
  }
  const source =
    currentSource;
  const myRequest =
    ++requestId;
  try {
    const response = await fetch(
      `/api/history?source=${encodeURIComponent(source)}`,
      {
        cache: 'no-store',
      }
    );
    if (!response.ok) {
      throw new Error(
        'History unavailable'
      );
    }
    const result =
      await response.json();
    if (myRequest !== requestId) {
      return;
    }
    const records =
      result.data || [];
    errorNode.hidden = true;
    statusNode.textContent = translations[preferences.language].connected;
    recordCountNode.textContent =
      `${records.length} ${translations[preferences.language].records}`;
    if (records.length > 0) {
      valueNode.textContent =
        formatValue(
          records[0].value
        );
      timeNode.textContent =
        new Date(
          records[0].recorded_at
        ).toLocaleString();
    } else {
      valueNode.textContent = '—';
      timeNode.textContent = translations[preferences.language].none;
    }
    const fresh =
      records.filter(
        (record) =>
          new Date(
            record.recorded_at
          ).getTime() > lastTimestamp
      );
    if (fresh.length > 0) {
      appendTable(fresh);
      appendChart(fresh);
      lastTimestamp =
        Math.max(
          ...fresh.map(
            (record) =>
              new Date(
                record.recorded_at
              ).getTime()
          )
        );
    }
  } catch (err) {
    if (myRequest !== requestId) {
      return;
    }
    console.error(err);
    errorNode.hidden = false;
    statusNode.textContent = translations[preferences.language].issue;
  }
}
/* SOURCE CHANGE */
sourceSelect.addEventListener(
  'change',
  () => {
    currentSource =
      sourceSelect.value;
    resetView();
    refreshHistory();
  }
);
/* LOOP */
async function loop() {
  if (!currentSource) {
    await loadSources();
  }
  await refreshHistory();
  setTimeout(
    loop,
    REFRESH_MS
  );
}
loadPreferences().finally(loop);
