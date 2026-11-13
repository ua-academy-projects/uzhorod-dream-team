-- One row per queue message; msg_id gives idempotency on redelivery.
create table fetch_results (
    msg_id      uuid primary key,
    status      text not null check (status in ('ok', 'failed')),
    schema      smallint not null,
    kind        text not null,
    lat         double precision not null,
    lon         double precision not null,
    radius      integer not null,
    fetched_at  timestamptz not null,
    received_at timestamptz not null default now(),
    poi_count   integer,   -- ok only
    error       text,      -- failed only
    attempts    jsonb      -- failed only
);

create index fetch_results_kind_fetched_at on fetch_results (kind, fetched_at desc);

create table poi (
    fetch_id uuid not null references fetch_results (msg_id) on delete cascade,
    osm_type text not null,
    osm_id   bigint not null,
    lat      double precision not null,
    lon      double precision not null,
    tags     jsonb not null default '{}',
    primary key (fetch_id, osm_type, osm_id)
);
