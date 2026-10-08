/**
 * History service: stores observations produced by the Fetcher and reads them back.
 */
import { Op } from 'sequelize';
import config from './config.js';
import * as fetcher from './fetcherClient.js';
import { daysToCatchUp } from './catchUp.js';
import { describeWeatherCode } from './weatherCodes.js';
import { WeatherObservation } from './model.js';

const MAX_HISTORY_ROWS = 5000;
const DEFAULT_HISTORY_DAYS = 7;

// On a duplicate (location, observedAt), refresh the measured values
const UPDATABLE_FIELDS = [
  'temperature',
  'apparentTemperature',
  'humidity',
  'precipitation',
  'windSpeed',
  'windDirection',
  'weatherCode',
  'source',
  'updatedAt',
];

function toDto(row) {
  const data = row.get({ plain: true });
  return { ...data, conditions: describeWeatherCode(data.weatherCode) };
}

/** Invokes the Fetcher for current weather and stores (or refreshes) the result. */
export async function triggerFetch(location = config.location) {
  const observation = await fetcher.fetchCurrent(location);
  await WeatherObservation.bulkCreate([observation], { updateOnDuplicate: UPDATABLE_FIELDS });
  const saved = await WeatherObservation.findOne({
    where: { locationName: observation.locationName, observedAt: observation.observedAt },
  });
  return toDto(saved);
}

/**
 * Fetches hourly data for the past `days` days and stores it.
 * Existing rows (e.g. from scheduled fetches) are kept as they are.
 */
export async function backfill(days, location = config.location) {
  const observations = await fetcher.fetchRecentHistory(location, days);
  const before = await WeatherObservation.count({ where: { locationName: location.name } });
  await WeatherObservation.bulkCreate(observations, { ignoreDuplicates: true });
  const after = await WeatherObservation.count({ where: { locationName: location.name } });
  return { days, fetched: observations.length, inserted: after - before };
}

/**
 * Fills the gap since the last stored observation (or the initial window if the table is empty)
 * with hourly history from the Fetcher. Capped at the weather API's 92-day limit.
 */
export async function catchUp(location = config.location) {
  const latest = await WeatherObservation.max('observedAt', { where: { locationName: location.name } });
  const days = daysToCatchUp(latest ?? null, new Date(), {
    initialDays: config.initialBackfillDays,
    maxDays: fetcher.MAX_HISTORY_DAYS,
  });
  if (days === 0) return { days: 0, fetched: 0, inserted: 0 };
  return backfill(days, location);
}

export async function getLatest(location = config.location) {
  const row = await WeatherObservation.findOne({
    where: { locationName: location.name },
    order: [['observedAt', 'DESC']],
  });
  return row ? toDto(row) : null;
}

export async function getHistory({ from, to, limit } = {}, location = config.location) {
  const end = to ?? new Date();
  const start = from ?? new Date(end.getTime() - DEFAULT_HISTORY_DAYS * 24 * 3600 * 1000);
  const rows = await WeatherObservation.findAll({
    where: {
      locationName: location.name,
      observedAt: { [Op.between]: [start, end] },
    },
    order: [['observedAt', 'ASC']],
    limit: Math.min(limit ?? MAX_HISTORY_ROWS, MAX_HISTORY_ROWS),
  });
  return { location, from: start, to: end, count: rows.length, observations: rows.map(toDto) };
}
