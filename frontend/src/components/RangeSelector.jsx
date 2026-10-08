import { useState } from 'react';

export const PRESETS = [
  { id: '24h', label: 'Last 24 hours', hours: 24 },
  { id: '7d', label: 'Last 7 days', hours: 24 * 7 },
  { id: '30d', label: 'Last 30 days', hours: 24 * 30 },
  { id: '90d', label: 'Last 90 days', hours: 24 * 90 },
];

export function presetRange(presetId) {
  const preset = PRESETS.find((p) => p.id === presetId);
  const to = new Date();
  return { preset: presetId, from: new Date(to.getTime() - preset.hours * 3600 * 1000), to };
}

// yyyy-mm-dd in local time (toISOString would shift to UTC)
const toInputValue = (date) =>
  `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;

export default function RangeSelector({ range, onChange, onBackfill, busy }) {
  const [customFrom, setCustomFrom] = useState(toInputValue(range.from));
  const [customTo, setCustomTo] = useState(toInputValue(range.to));

  function applyCustom(event) {
    event.preventDefault();
    const from = new Date(`${customFrom}T00:00:00`);
    const to = new Date(`${customTo}T23:59:59`);
    if (from > to) return;
    onChange({ preset: 'custom', from, to });
  }

  return (
    <section className="toolbar">
      <div className="presets">
        {PRESETS.map((p) => (
          <button
            key={p.id}
            className={range.preset === p.id ? 'active' : ''}
            onClick={() => onChange(presetRange(p.id))}
          >
            {p.label}
          </button>
        ))}
      </div>

      <form className="custom-range" onSubmit={applyCustom}>
        <label>
          From <input type="date" value={customFrom} onChange={(e) => setCustomFrom(e.target.value)} required />
        </label>
        <label>
          To <input type="date" value={customTo} onChange={(e) => setCustomTo(e.target.value)} required />
        </label>
        <button type="submit" className={range.preset === 'custom' ? 'active' : ''}>
          Apply
        </button>
      </form>

      <button onClick={onBackfill} disabled={busy} title="Fetch hourly data for the past 30 days from Open-Meteo">
        Load past 30 days
      </button>
    </section>
  );
}
