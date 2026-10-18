const BASE_URL = '/api'

const request = async (path, options = {}) => {
  const res = await fetch(`${BASE_URL}${path}`, { credentials: 'include', ...options })
  if (!res.ok) throw new Error(`${options.method || 'GET'} ${path}: HTTP ${res.status}`)
  return res
}

export const getHistory = async () => (await request('/history')).json()

export const getSettings = async () => (await request('/settings')).json()

export const saveSettings = async (settings) => {
  await request('/settings', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(settings)
  })
}

export const getPasses = async ({ latitude, longitude, radius_km }) => {
  const query = new URLSearchParams({ lat: latitude, lon: longitude, radius_km })
  return (await request(`/passes?${query}`)).json()
}
