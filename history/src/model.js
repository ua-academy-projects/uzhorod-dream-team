import { DataTypes } from 'sequelize';
import { sequelize } from './db/index.js';

export const WeatherObservation = sequelize.define(
  'WeatherObservation',
  {
    id: { type: DataTypes.INTEGER, primaryKey: true, autoIncrement: true },
    locationName: { type: DataTypes.STRING, allowNull: false },
    latitude: { type: DataTypes.DOUBLE, allowNull: false },
    longitude: { type: DataTypes.DOUBLE, allowNull: false },
    observedAt: { type: DataTypes.DATE, allowNull: false },
    temperature: DataTypes.REAL, // °C
    apparentTemperature: DataTypes.REAL, // °C
    humidity: DataTypes.REAL, // %
    precipitation: DataTypes.REAL, // mm
    windSpeed: DataTypes.REAL, // km/h
    windDirection: DataTypes.REAL, // degrees
    weatherCode: DataTypes.INTEGER, // WMO code
    source: { type: DataTypes.ENUM('current', 'historical'), allowNull: false },
  },
  {
    tableName: 'weather_observations',
    underscored: true,
    indexes: [{ unique: true, fields: ['location_name', 'observed_at'] }],
  },
);
