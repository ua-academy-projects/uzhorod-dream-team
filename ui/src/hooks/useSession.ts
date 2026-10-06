import { useEffect, useState, useSyncExternalStore } from 'react';
import { api } from '../lib/api';
import { SessionStore } from '../lib/sessionStore';
import { reconcilePreferences } from '../lib/sessionPreferences';
import { useLocationParameters } from './useApi';
import type { Location } from '../types/api';

export function useSession(locations: Location[] | undefined) {
  const [store] = useState(() => new SessionStore(api));
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const { preferences, isLoading } = snapshot;
  const validLocation = locations?.some(location => location.id === preferences.locationId);
  const { data: parameters } = useLocationParameters(!isLoading && validLocation ? preferences.locationId : null);

  useEffect(() => {
    store.start();
    window.addEventListener('focus', store.retry);
    return () => {
      store.stop();
      window.removeEventListener('focus', store.retry);
    };
  }, [store]);

  useEffect(() => {
    if (isLoading || !locations) return;
    store.update(reconcilePreferences(preferences, locations, parameters));
  }, [isLoading, locations, parameters, preferences, store]);

  return { ...snapshot, update: store.update };
}
