# Weather API: Open-Meteo

The app uses [Open-Meteo](https://open-meteo.com/), a free, open-source weather API.

## Why Open-Meteo

- **No API key and no sign-up** for non-commercial use, so there are no secrets to manage for the weather source.
- **Frequently updated data:** `current` values refresh every 15 minutes.
- **Free historical data:**
  - the forecast endpoint's `past_days` parameter returns hourly data for up to the last **92 days**, which is what this app uses for backfill;
  - a separate **Historical Weather API** (`archive-api.open-meteo.com/v1/archive`, ERA5 reanalysis) goes back to 1940. The app doesn't use it, but it would slot straight into the Fetcher service.

## Endpoints used

Base URL: `https://api.open-meteo.com/v1/forecast` (configurable with `OPEN_METEO_BASE_URL` in `fetcher/.env`).

Every request sends `latitude`, `longitude`, `timeformat=unixtime`, `timezone=GMT` and `wind_speed_unit=kmh`.
Timestamps are handled in UTC throughout, and the browser converts them to local time for display.

| Purpose | Extra parameters | Used by |
|---|---|---|
| Current weather | `current=<variables>` | Fetcher `current` request (RabbitMQ) ← `POST /api/weather/fetch` |
| Recent history (hourly) | `hourly=<variables>&past_days=N&forecast_days=1` | Fetcher `history` request (RabbitMQ) ← `POST /api/weather/backfill` |

Variables requested: `temperature_2m`, `relative_humidity_2m`, `apparent_temperature`, `precipitation`,
`wind_speed_10m`, `wind_direction_10m`, `weather_code` (a WMO code, which the app maps to text such as "Overcast").

Example:

```bash
curl 'https://api.open-meteo.com/v1/forecast?latitude=52.52&longitude=13.41&current=temperature_2m,weather_code&timeformat=unixtime&timezone=GMT'
```

## Free tier limitations

| Limitation | Impact on this app |
|---|---|
| **Non-commercial use only.** Commercial use needs a paid plan. | Fine for a demo. |
| **Rate limits:** about 10,000 calls/day, 5,000/hour, 600/minute. | An hourly scheduler makes 24 calls a day, well within the limits. |
| **Model data, not station measurements.** Values come from weather models at roughly 1–11 km resolution. | Readings can differ slightly from a nearby weather station. |
| **15-minute resolution for `current`.** Calling more often returns the same value. | The table's unique index on `(location_name, observed_at)` stops duplicate rows. |
| **`past_days` is capped at 92.** | The backfill endpoint rejects `days > 92`. |
| **The archive API lags about 5 days** behind real time. | Not used. Recent days come from `past_days` instead. |
| **Attribution required (CC BY 4.0).** | The UI header links to Open-Meteo. |
| **No SLA** on the free public endpoint. | Fetch errors are logged and returned as HTTP 502. The next scheduled run tries again. |
