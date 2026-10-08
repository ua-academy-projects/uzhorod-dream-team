import { formatDateTime, formatNumber } from '../format.js';

export default function CurrentWeather({ observation, onFetchNow, busy }) {
  return (
    <section className="card">
      <div className="card-header">
        <h2>Latest observation</h2>
        <button onClick={onFetchNow} disabled={busy}>
          Fetch now
        </button>
      </div>

      {observation ? (
        <>
          <div className="current">
            <div className="current-temp">{formatNumber(observation.temperature, '°C')}</div>
            <div>
              <div className="current-conditions">{observation.conditions}</div>
              <div className="muted">
                {observation.locationName} · {formatDateTime(observation.observedAt)}
              </div>
            </div>
          </div>
          <dl className="stats">
            <div>
              <dt>Feels like</dt>
              <dd>{formatNumber(observation.apparentTemperature, '°C')}</dd>
            </div>
            <div>
              <dt>Humidity</dt>
              <dd>{formatNumber(observation.humidity, '%', 0)}</dd>
            </div>
            <div>
              <dt>Precipitation</dt>
              <dd>{formatNumber(observation.precipitation, ' mm')}</dd>
            </div>
            <div>
              <dt>Wind</dt>
              <dd>
                {formatNumber(observation.windSpeed, ' km/h')} · {formatNumber(observation.windDirection, '°', 0)}
              </dd>
            </div>
          </dl>
        </>
      ) : (
        <p className="muted">No data yet. Click “Fetch now” or wait for the scheduler.</p>
      )}
    </section>
  );
}
