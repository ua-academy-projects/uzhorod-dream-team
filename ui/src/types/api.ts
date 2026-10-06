export interface Location {
  id: number;
  name: string;
  lat: number;
  lon: number;
  last_sync_time?: string;
}

export interface Parameter {
  name: string;
  unit: string;
}

export interface MeasurementData {
  value: number;
  timestamp: string;
}

export type ObservationPeriod =
  | { kind: 'preset'; days: 1 | 7 | 30 }
  | { kind: 'custom'; from: string; to: string };

export interface SessionPreferences {
  locationId: number | null;
  parameter: string | null;
  period: ObservationPeriod;
}
