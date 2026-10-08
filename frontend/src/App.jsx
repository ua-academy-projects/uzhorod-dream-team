import { useCallback, useEffect, useState } from 'react';
import * as api from './api.js';
import CurrentWeather from './components/CurrentWeather.jsx';
import RangeSelector, { presetRange } from './components/RangeSelector.jsx';
import ThemeToggle from './components/ThemeToggle.jsx';
import WeatherChart from './components/WeatherChart.jsx';
import WeatherTable from './components/WeatherTable.jsx';

export default function App() {
  const [range, setRange] = useState(() => presetRange('7d'));
  const [latest, setLatest] = useState(null);
  const [history, setHistory] = useState(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [notice, setNotice] = useState(null);
  // null until the saved preference is loaded: the CSS follows the system theme meanwhile
  const [theme, setTheme] = useState(null);

  useEffect(() => {
    api
      .getPreferences()
      .then((prefs) => setTheme(prefs.theme ?? systemTheme()))
      .catch(() => setTheme(systemTheme()));
  }, []);

  useEffect(() => {
    if (theme) document.documentElement.dataset.theme = theme;
  }, [theme]);

  async function toggleTheme() {
    const next = theme === 'dark' ? 'light' : 'dark';
    setTheme(next);
    try {
      await api.savePreferences({ theme: next });
    } catch (err) {
      setNotice(`Theme changed, but could not be saved: ${err.message}`);
    }
  }

  const load = useCallback(async (r) => {
    setLoading(true);
    setError(null);
    try {
      const [latestObs, historyData] = await Promise.all([api.getLatest(), api.getHistory(r.from, r.to)]);
      setLatest(latestObs);
      setHistory(historyData);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load(range);
  }, [range, load]);

  // Presets are relative to "now", so recompute them after new data arrives
  const refresh = () => setRange((r) => (r.preset === 'custom' ? { ...r } : presetRange(r.preset)));

  async function runAction(action, successMessage) {
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      const result = await action();
      setNotice(successMessage(result));
      refresh();
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  }

  const observations = history?.observations ?? [];

  return (
    <main className="container">
      <header className="page-header">
        <div>
          <h1>Weather History{history ? ` — ${history.location.name}` : ''}</h1>
          <p className="muted">
            Data from <a href="https://open-meteo.com/">Open-Meteo</a> (CC BY 4.0), stored in PostgreSQL.
          </p>
        </div>
        {theme && <ThemeToggle theme={theme} onToggle={toggleTheme} />}
      </header>

      {error && <div className="alert error">{error}</div>}
      {notice && <div className="alert">{notice}</div>}

      <CurrentWeather
        observation={latest}
        busy={busy}
        onFetchNow={() => runAction(api.triggerFetch, (o) => `Fetched current weather: ${o.temperature}°C`)}
      />

      <RangeSelector
        range={range}
        onChange={setRange}
        busy={busy}
        onBackfill={() => runAction(() => api.backfill(30), (r) => `Fetched ${r.fetched} hourly observations, ${r.inserted} new`)}
      />

      {loading && !history ? (
        <p className="muted">Loading…</p>
      ) : observations.length === 0 ? (
        <p className="card muted">No observations in this range. Try “Load past 30 days”.</p>
      ) : (
        <>
          <WeatherChart observations={observations} />
          <WeatherTable observations={observations} />
        </>
      )}
    </main>
  );
}

function systemTheme() {
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}
