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
