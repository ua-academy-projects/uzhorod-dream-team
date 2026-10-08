/** Client for the History service HTTP API. */
const BASE_URL = import.meta.env.VITE_API_URL || '';

async function request(path, options = {}) {
  const response = await fetch(`${BASE_URL}${path}`, {
    ...options,
    headers: { 'Content-Type': 'application/json', ...options.headers },
  });
  const body = await response.json().catch(() => null);
  if (response.ok && body === null) {
    // e.g. a static server answering /api/* with index.html because VITE_API_URL was not set at build time
    throw new Error('The API returned a non-JSON response. Check VITE_API_URL and rebuild the frontend.');
  }
  if (!response.ok) {
    const error = new Error(body?.error || `Request failed with status ${response.status}`);
    error.status = response.status;
    throw error;
  }
  return body;
}

/** Latest stored observation, or null if the database is still empty. */
export async function getLatest() {
  try {
    return await request('/api/weather/latest');
  } catch (err) {
    if (err.status === 404) return null;
    throw err;
  }
}

export function getHistory(from, to) {
  const params = new URLSearchParams({ from: from.toISOString(), to: to.toISOString() });
  return request(`/api/weather/history?${params}`);
}

/** Saved UI preferences of this browser ({ theme: 'light' | 'dark' | null }); identified by a cookie. */
export function getPreferences() {
  return request('/api/preferences');
}

export function savePreferences(prefs) {
  return request('/api/preferences', { method: 'PUT', body: JSON.stringify(prefs) });
}

export function triggerFetch() {
  return request('/api/weather/fetch', { method: 'POST' });
}

export function backfill(days) {
  return request('/api/weather/backfill', { method: 'POST', body: JSON.stringify({ days }) });
}
