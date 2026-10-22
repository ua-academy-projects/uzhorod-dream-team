const historyRows = document.querySelector("#history-rows");
const statusMessage = document.querySelector("#status-message");
const refreshButton = document.querySelector("#refresh-button");
const latestTemperature = document.querySelector("#latest-temperature");
const latestTime = document.querySelector("#latest-time");
const themeButton = document.querySelector("#theme-button");
const languageButton = document.querySelector("#language-button");
const settingsMessage = document.querySelector("#settings-message");
const themeColorMeta = document.querySelector('meta[name="theme-color"]');

// All texts of the page in both languages. Keys used in index.html (data-i18n)
// are plain strings; texts with a value inside are functions.
const texts = {
  uk: {
    pageTitle: "Погода у Львові — історія",
    eyebrow: "Історія погоди",
    title: "Погода у Львові",
    intro: "Збережені вимірювання температури з Open-Meteo.",
    latestEyebrow: "Останній запис",
    latestHeading: "Зараз у Львові",
    historyEyebrow: "Збережені вимірювання",
    historyHeading: "Історія температури",
    refresh: "Оновити таблицю",
    columnCity: "Місто",
    columnTemperature: "Температура",
    columnTime: "Час вимірювання (Київ)",
    loading: "Завантажуємо історію погоди…",
    emptyLatest: "Ще немає збережених вимірювань.",
    emptyStatus: "Записів поки немає. Нові дані з’являться після першого вимірювання.",
    measuredAt: (time) => `Виміряно: ${time} за Києвом`,
    shown: (count) => `Показано записів: ${count}.`,
    latestUnavailable: "Останній запис недоступний.",
    serverError: (status) => `Не вдалося завантажити історію (помилка сервера: ${status}).`,
    badData: "Сервер повернув дані в неочікуваному форматі.",
    connectionError: "Не вдалося завантажити історію. Перевір з’єднання та спробуй ще раз.",
    darkTheme: "Темна тема",
    lightTheme: "Світла тема",
    // The language button shows the other language.
    languageButton: "EN",
    languageButtonLabel: "Switch to English",
    languageButtonLang: "en",
    saveFailed: "Не вдалося зберегти налаштування. Спробуй ще раз пізніше.",
  },
  en: {
    pageTitle: "Weather in Lviv — history",
    eyebrow: "Weather history",
    title: "Weather in Lviv",
    intro: "Saved temperature measurements from Open-Meteo.",
    latestEyebrow: "Latest record",
    latestHeading: "Now in Lviv",
    historyEyebrow: "Saved measurements",
    historyHeading: "Temperature history",
    refresh: "Refresh table",
    columnCity: "City",
    columnTemperature: "Temperature",
    columnTime: "Measured at (Kyiv)",
    loading: "Loading the weather history…",
    emptyLatest: "No saved measurements yet.",
    emptyStatus: "No records yet. New data will appear after the first measurement.",
    measuredAt: (time) => `Measured: ${time}, Kyiv time`,
    shown: (count) => `Records shown: ${count}.`,
    latestUnavailable: "The latest record is not available.",
    serverError: (status) => `Could not load the history (server error: ${status}).`,
    badData: "The server returned data in an unexpected format.",
    connectionError: "Could not load the history. Check the connection and try again.",
    darkTheme: "Dark theme",
    lightTheme: "Light theme",
    languageButton: "UA",
    languageButtonLabel: "Перейти на українську",
    languageButtonLang: "uk",
    saveFailed: "Could not save the settings. Please try again later.",
  },
};

// Date format of each language, for example "11 жовт. 2026 р., 21:45" or "11 Oct 2026, 21:45".
const locales = { uk: "uk-UA", en: "en-GB" };

// The color of the browser bar on phones, the same as --page in style.css.
const pageColors = { light: "#eaf4f4", dark: "#0f1f22" };

// The same values as in Go (history/settings.go).
let settings = { theme: "light", lang: "uk" };

// What the history part of the page shows now. Kept so that the page can be
// drawn again in another language without loading the data again.
//   { kind: "loading" } | { kind: "records", records } | { kind: "error", message: (t) => text }
let view = { kind: "loading" };

function t() {
  return texts[settings.lang];
}

function formatKyivTime(value) {
  return new Intl.DateTimeFormat(locales[settings.lang], {
    dateStyle: "medium",
    timeStyle: "short",
    timeZone: "Europe/Kyiv",
  }).format(new Date(value));
}

// Checks the data from /api/history before showing it.
function validRecords(records) {
  return (
    Array.isArray(records) &&
    records.every(
      (record) =>
        typeof record.city === "string" &&
        typeof record.temperature_c === "number" &&
        Number.isFinite(record.temperature_c) &&
        !Number.isNaN(new Date(record.observed_at).getTime()),
    )
  );
}

function renderRecords(records) {
  if (records.length === 0) {
    historyRows.replaceChildren();
    latestTemperature.textContent = "—";
    latestTime.textContent = t().emptyLatest;
    statusMessage.textContent = t().emptyStatus;
    return;
  }

  const rows = records.map((record) => {
    const row = document.createElement("tr");
    const cityCell = document.createElement("td");
    const temperatureCell = document.createElement("td");
    const timeCell = document.createElement("td");

    cityCell.textContent = record.city;
    temperatureCell.textContent = `${record.temperature_c.toFixed(1)} °C`;
    timeCell.textContent = formatKyivTime(record.observed_at);
    row.append(cityCell, temperatureCell, timeCell);
    return row;
  });

  historyRows.replaceChildren(...rows);
  latestTemperature.textContent = `${records[0].temperature_c.toFixed(1)} °C`;
  latestTime.textContent = t().measuredAt(formatKyivTime(records[0].observed_at));
  statusMessage.textContent = t().shown(records.length);
}

// Draws the history part of the page from `view` in the current language.
function renderView() {
  if (view.kind === "loading") {
    statusMessage.textContent = t().loading;
  } else if (view.kind === "records") {
    renderRecords(view.records);
  } else {
    historyRows.replaceChildren();
    latestTemperature.textContent = "—";
    latestTime.textContent = t().latestUnavailable;
    statusMessage.textContent = view.message(t());
  }
}

async function loadHistory() {
  refreshButton.disabled = true;
  view = { kind: "loading" };
  renderView();

  try {
    const response = await fetch("/api/history");
    if (!response.ok) {
      view = { kind: "error", message: (text) => text.serverError(response.status) };
    } else {
      const records = await response.json();
      view = validRecords(records)
        ? { kind: "records", records }
        : { kind: "error", message: (text) => text.badData };
    }
  } catch {
    view = { kind: "error", message: (text) => text.connectionError };
  } finally {
    refreshButton.disabled = false;
  }
  renderView();
}

// Shows the settings on the page: the theme (style.css takes the colors from
// data-theme on <html>) and the language of all texts.
function applySettings(next) {
  settings = next;
  const text = t();

  document.documentElement.dataset.theme = settings.theme;
  themeColorMeta.content = pageColors[settings.theme];
  // The theme button says what it will do.
  themeButton.textContent = settings.theme === "dark" ? text.lightTheme : text.darkTheme;

  document.documentElement.lang = settings.lang;
  document.title = text.pageTitle;
  for (const element of document.querySelectorAll("[data-i18n]")) {
    element.textContent = text[element.dataset.i18n];
  }
  languageButton.textContent = text.languageButton;
  languageButton.lang = text.languageButtonLang;
  languageButton.setAttribute("aria-label", text.languageButtonLabel);

  renderView();
}

function validSettings(value) {
  return (
    (value.theme === "light" || value.theme === "dark") &&
    (value.lang === "uk" || value.lang === "en")
  );
}

// Reads the saved settings. The browser sends the wh_session cookie by itself,
// so the server knows whose settings these are.
async function loadSettings() {
  try {
    const response = await fetch("/api/settings");
    if (!response.ok) {
      throw new Error(`server error: ${response.status}`);
    }
    const saved = await response.json();
    if (validSettings(saved)) {
      applySettings({ theme: saved.theme, lang: saved.lang });
    }
  } catch {
    // Without saved settings the page works with the light theme in Ukrainian.
  }
}

// Shows the new settings at once and saves them; if saving fails, they go back.
async function saveSettings(next) {
  const previous = settings;
  applySettings(next);
  settingsMessage.textContent = "";
  themeButton.disabled = true;
  languageButton.disabled = true;

  try {
    const response = await fetch("/api/settings", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(next),
    });
    if (!response.ok) {
      throw new Error(`server error: ${response.status}`);
    }
  } catch {
    applySettings(previous);
    settingsMessage.textContent = t().saveFailed;
  } finally {
    themeButton.disabled = false;
    languageButton.disabled = false;
  }
}

themeButton.addEventListener("click", () =>
  saveSettings({ ...settings, theme: settings.theme === "dark" ? "light" : "dark" }),
);
languageButton.addEventListener("click", () =>
  saveSettings({ ...settings, lang: settings.lang === "uk" ? "en" : "uk" }),
);
refreshButton.addEventListener("click", loadHistory);
loadSettings();
loadHistory();
