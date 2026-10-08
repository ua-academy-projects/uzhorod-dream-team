export const formatDateTime = (value) =>
  new Date(value).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });

export const formatNumber = (value, unit, digits = 1) =>
  value === null || value === undefined ? '—' : `${Number(value).toFixed(digits)}${unit}`;
