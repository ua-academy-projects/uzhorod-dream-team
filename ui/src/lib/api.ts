import type { Location, Parameter, MeasurementData, SessionPreferences } from '../types/api';

const API_URL = import.meta.env.VITE_API_URL || 'http://localhost:8081/api/v1';

async function fetchAPI<T>(endpoint: string, options?: RequestInit): Promise<T> {
  const res = await fetch(`${API_URL}${endpoint}`, { ...options, credentials: 'include' });
  if (!res.ok) {
    let errorMsg = res.statusText;
    try {
      const errBody = await res.json();
      if (errBody.error) errorMsg = errBody.error;
    } catch (e) {
      // ignore
    }
    throw new Error(errorMsg);
  }
  return res.json();
}

export const api = {
  getSession: () => fetchAPI<SessionPreferences>('/session', { signal: AbortSignal.timeout(3000) }),
  saveSession: (preferences: SessionPreferences) => fetchAPI<SessionPreferences>('/session', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(preferences),
    signal: AbortSignal.timeout(3000),
  }),
  getLocations: () => fetchAPI<Location[]>('/locations'),
  
  getLocationParameters: (id: number) => 
    fetchAPI<Parameter[]>(`/locations/${id}/parameters`),
    
  getLocationHistory: (id: number, parameter: string, from?: string, to?: string) => {
    const params = new URLSearchParams({ parameter });
    if (from) params.append('from', from);
    if (to) params.append('to', to);
    return fetchAPI<MeasurementData[]>(`/locations/${id}/history?${params.toString()}`);
  }
};
