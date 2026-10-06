import type { Location, Parameter, SessionPreferences } from '../types/api';

export function reconcilePreferences(preferences: SessionPreferences, locations: Location[], parameters?: Parameter[]): SessionPreferences {
  if (preferences.locationId === null || !locations.some(location => location.id === preferences.locationId)) {
    return { ...preferences, locationId: null, parameter: null };
  }
  if (parameters && !parameters.some(parameter => parameter.name === preferences.parameter)) {
    return { ...preferences, parameter: parameters[0]?.name ?? null };
  }
  return preferences;
}
