CREATE TABLE IF NOT EXISTS price_points (
    id          BIGSERIAL PRIMARY KEY,
    coin        TEXT NOT NULL,
    vs_currency TEXT NOT NULL,
    price       NUMERIC(20, 8) NOT NULL,
    observed_at TIMESTAMPTZ NOT NULL,
    source      TEXT NOT NULL CHECK (source IN ('bootstrap', 'timer', 'on_demand')),
    fetched_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (coin, vs_currency, observed_at)
);

CREATE INDEX IF NOT EXISTS idx_price_points_lookup
    ON price_points (coin, vs_currency, observed_at DESC);
