import {
  CartesianGrid, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis,
} from 'recharts';
import type { HistoryPoint } from '../api/client.ts';
import { formatDayMonth, formatMoment, formatPrice, formatPricePrecise } from './format.ts';

const compact = new Intl.NumberFormat('en-US', { notation: 'compact', maximumFractionDigits: 1 });

type Row = { t: number; price: number };

function ChartTooltip({ active, payload }: { active?: boolean; payload?: { payload: Row }[] }) {
  const row = active ? payload?.[0]?.payload : undefined;
  if (!row) return null;
  return (
    <div className="chart-tooltip">
      <strong>{formatPricePrecise(row.price)}</strong>
      <span>{formatMoment(new Date(row.t).toISOString())}</span>
    </div>
  );
}

export function PriceChart({ points }: { points: HistoryPoint[] }) {
  const rows: Row[] = points.map((p) => ({ t: Date.parse(p.observedAt), price: p.price }));
  const prices = rows.map((r) => r.price);
  const low = Math.min(...prices);
  const high = Math.max(...prices);

  return (
    <section className="panel" aria-label="Bitcoin price over the last 7 days">
      <div className="chart" style={{ width: '100%', height: 320 }}>
        <ResponsiveContainer>
          <LineChart data={rows} margin={{ top: 8, right: 12, bottom: 4, left: 4 }}>
            <CartesianGrid vertical={false} />
            <XAxis
              dataKey="t"
              type="number"
              scale="time"
              domain={['dataMin', 'dataMax']}
              tickFormatter={formatDayMonth}
              tickLine={false}
              minTickGap={48}
            />
            <YAxis
              width={64}
              domain={['auto', 'auto']}
              tickFormatter={(v: number) => compact.format(v)}
              tickLine={false}
              axisLine={false}
            />
            <Tooltip content={<ChartTooltip />} />
            <Line
              type="monotone"
              dataKey="price"
              dot={false}
              strokeWidth={2}
              isAnimationActive={false}
            />
          </LineChart>
        </ResponsiveContainer>
      </div>
      <p className="panel__caption">
        <span>7-day history, {rows.length} observations</span>
        <span>
          low {formatPrice(low)} · high {formatPrice(high)}
        </span>
      </p>
    </section>
  );
}
