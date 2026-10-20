import {
  CartesianGrid,
  Legend,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';
import { formatDateTime } from '../format.js';

const HOUR_MS = 3_600_000;
const TICK_STEP_HOURS = [1, 3, 6, 12, 24, 48, 7 * 24, 14 * 24];
const MAX_TICKS = 8;

/**
 * Ticks on round local times (midnights, or every N hours from midnight) instead of
 * recharts' even split of the data range, which starts at the first point's odd hour.
 */
function timeTicks(min, max) {
  const step = TICK_STEP_HOURS.find((h) => (max - min) / (h * HOUR_MS) <= MAX_TICKS) ?? TICK_STEP_HOURS.at(-1);
  const t = new Date(min);
  t.setHours(0, 0, 0, 0);
  const ticks = [];
  while (t.getTime() <= max) {
    if (t.getTime() >= min) ticks.push(t.getTime());
    if (step < 24) t.setHours(t.getHours() + step);
    else t.setDate(t.getDate() + step / 24);
  }
  return ticks;
}

// Midnight shows the date, other ticks the time of day
function formatTick(ts) {
  const date = new Date(ts);
  return date.getHours() === 0 && date.getMinutes() === 0
    ? date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
    : date.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
}

/**
 * One line chart with a single y-axis. Temperature and humidity use different
 * units, so they are rendered as two separate charts rather than one dual-axis chart.
 */
function TimeSeriesChart({ data, series, unit, domain }) {
  return (
    <ResponsiveContainer width="100%" height={260}>
      <LineChart data={data} margin={{ top: 8, right: 16, bottom: 0, left: 0 }}>
        <CartesianGrid stroke="var(--grid)" vertical={false} />
        <XAxis
          dataKey="ts"
          type="number"
          scale="time"
          domain={['dataMin', 'dataMax']}
          ticks={timeTicks(data[0].ts, data.at(-1).ts)}
          tickFormatter={formatTick}
          stroke="var(--text-muted)"
          tick={{ fontSize: 12 }}
          minTickGap={40}
        />
        <YAxis
          unit={unit}
          domain={domain}
          stroke="var(--text-muted)"
          tick={{ fontSize: 12 }}
          width={56}
          allowDecimals={false}
        />
        <Tooltip
          labelFormatter={formatDateTime}
          formatter={(value, name) => [value === null ? '—' : `${value}${unit}`, name]}
          contentStyle={{ background: 'var(--surface)', border: '1px solid var(--border)', color: 'var(--text)' }}
        />
        {series.length > 1 && (
          <Legend
            verticalAlign="top"
            height={28}
            formatter={(value) => <span style={{ color: 'var(--text)' }}>{value}</span>}
          />
        )}
        {series.map((s) => (
          <Line
            key={s.key}
            dataKey={s.key}
            name={s.name}
            stroke={s.color}
            strokeWidth={2}
            dot={false}
            activeDot={{ r: 4 }}
            connectNulls
            isAnimationActive={false}
          />
        ))}
      </LineChart>
    </ResponsiveContainer>
  );
}

export default function WeatherChart({ observations }) {
  if (observations.length === 0) return null;

  const data = observations.map((o) => ({
    ts: new Date(o.observedAt).getTime(),
    temperature: o.temperature,
    apparentTemperature: o.apparentTemperature,
    humidity: o.humidity,
  }));

  return (
    <section className="card">
      <h2>Temperature</h2>
      <TimeSeriesChart
        data={data}
        unit="°C"
        domain={['auto', 'auto']}
        series={[
          { key: 'temperature', name: 'Temperature', color: 'var(--series-1)' },
          { key: 'apparentTemperature', name: 'Feels like', color: 'var(--series-2)' },
        ]}
      />
      <h2>Relative humidity</h2>
      <TimeSeriesChart
        data={data}
        unit="%"
        domain={[0, 100]}
        series={[{ key: 'humidity', name: 'Humidity', color: 'var(--series-1)' }]}
      />
    </section>
  );
}
