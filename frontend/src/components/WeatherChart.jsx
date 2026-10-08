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

const formatTick = (ts) =>
  new Date(ts).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });

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
