import { useQuery } from '@tanstack/react-query';
import { api } from '../lib/api';

export function useLocations() {
  return useQuery({
    queryKey: ['locations'],
    queryFn: api.getLocations,
  });
}

export function useLocationParameters(locationId: number | null) {
  return useQuery({
    queryKey: ['locations', locationId, 'parameters'],
    queryFn: () => api.getLocationParameters(locationId!),
    enabled: locationId !== null,
  });
}

export function useLocationHistory(locationId: number | null, parameter: string | null, from?: string, to?: string) {
  return useQuery({
    queryKey: ['locations', locationId, 'history', parameter, from, to],
    queryFn: () => api.getLocationHistory(locationId!, parameter!, from, to),
    enabled: locationId !== null && parameter !== null,
  });
}
