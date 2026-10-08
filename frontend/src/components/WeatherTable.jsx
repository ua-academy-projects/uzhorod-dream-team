import { formatDateTime, formatNumber } from '../format.js';

export default function WeatherTable({ observations }) {
  // Newest first reads better in a table
  const rows = [...observations].reverse();

  return (
    <section className="card">
      <h2>Observations ({rows.length})</h2>
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Time</th>
              <th className="num">Temp</th>
              <th className="num">Feels like</th>
              <th className="num">Humidity</th>
              <th className="num">Precip.</th>
              <th className="num">Wind</th>
              <th>Conditions</th>
              <th>Source</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((o) => (
              <tr key={o.id}>
                <td>{formatDateTime(o.observedAt)}</td>
                <td className="num">{formatNumber(o.temperature, '°C')}</td>
                <td className="num">{formatNumber(o.apparentTemperature, '°C')}</td>
                <td className="num">{formatNumber(o.humidity, '%', 0)}</td>
                <td className="num">{formatNumber(o.precipitation, ' mm')}</td>
                <td className="num">{formatNumber(o.windSpeed, ' km/h')}</td>
                <td>{o.conditions}</td>
                <td className="muted">{o.source}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}
