-- +goose Up
CREATE TABLE locations (
    id INT PRIMARY KEY,
    name TEXT NOT NULL,
    lat DOUBLE PRECISION NOT NULL,
    lon DOUBLE PRECISION NOT NULL
);

CREATE TABLE parameters (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    unit TEXT NOT NULL
);

CREATE TABLE measurements (
    location_id INT NOT NULL REFERENCES locations(id),
    parameter_id INT NOT NULL REFERENCES parameters(id),
    value DOUBLE PRECISION NOT NULL,
    timestamp TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (location_id, parameter_id, timestamp)
);

CREATE INDEX idx_measurements_location_id ON measurements(location_id);
CREATE INDEX idx_measurements_parameter_id ON measurements(parameter_id);
CREATE INDEX idx_measurements_timestamp ON measurements(timestamp);

-- +goose Down
DROP TABLE measurements;
DROP TABLE parameters;
DROP TABLE locations;
