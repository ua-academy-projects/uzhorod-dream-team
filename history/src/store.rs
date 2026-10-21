use crate::models::{Event, Failed, Fetched, Header};
use anyhow::Result;
use sqlx::{PgPool, Postgres, Transaction, postgres::PgPoolOptions, types::Json};

/// History in Postgres: `fetch_results` (a row per message) + `poi` (elements of `poi.fetched`).
#[derive(Clone)]
pub struct Store(PgPool);

impl Store {
    /// Connects and applies the migrations from `migrations/`.
    pub async fn connect(url: &str) -> Result<Self> {
        let pool = PgPoolOptions::new().max_connections(4).connect(url).await?;
        sqlx::migrate!("./migrations").run(&pool).await?;
        Ok(Self(pool))
    }

    pub fn from_pool(pool: PgPool) -> Self {
        Self(pool)
    }
}

/// Where the worker stores events. Kept separate from `Store` so the ack/nack/reject decisions
/// can be tested without Postgres.
#[async_trait::async_trait]
pub trait Sink: Send + Sync {
    /// Saves the event in a single transaction. Idempotent on `msg_id`: redelivery
    /// changes nothing. Returns `false` if it was a duplicate.
    async fn save(&self, event: &Event) -> Result<bool>;

    /// Whether the storage is available (for `/healthz`).
    async fn ping(&self) -> Result<()>;
}

#[async_trait::async_trait]
impl Sink for Store {
    async fn save(&self, event: &Event) -> Result<bool> {
        let mut tx = self.0.begin().await?;
        let inserted = match event {
            Event::Fetched(m) => save_fetched(&mut tx, m).await?,
            Event::Failed(m) => save_failed(&mut tx, m).await?,
        };
        tx.commit().await?;
        Ok(inserted)
    }

    async fn ping(&self) -> Result<()> {
        sqlx::query("select 1").execute(&self.0).await?;
        Ok(())
    }
}

const INSERT_RESULT: &str = "\
    insert into fetch_results \
        (msg_id, status, schema, kind, lat, lon, radius, fetched_at, poi_count, error, attempts) \
    values ($1, $2, $3, $4, $5, $6, $7, to_timestamp($8::float8), $9, $10, $11) \
    on conflict (msg_id) do nothing";

async fn insert_result(
    tx: &mut Transaction<'_, Postgres>,
    h: &Header,
    status: &str,
    poi_count: Option<i32>,
    error: Option<&str>,
    attempts: Option<&serde_json::Value>,
) -> Result<bool> {
    let done = sqlx::query(INSERT_RESULT)
        .bind(h.msg_id)
        .bind(status)
        .bind(h.schema)
        .bind(&h.kind)
        .bind(h.lat)
        .bind(h.lon)
        .bind(h.radius)
        .bind(h.at as f64)
        .bind(poi_count)
        .bind(error)
        .bind(attempts.map(Json))
        .execute(&mut **tx)
        .await?;
    Ok(done.rows_affected() == 1)
}

async fn save_fetched(tx: &mut Transaction<'_, Postgres>, m: &Fetched) -> Result<bool> {
    let count = m.elements.len() as i32;
    if !insert_result(tx, &m.head, "ok", Some(count), None, None).await? {
        return Ok(false);
    }
    if m.elements.is_empty() {
        return Ok(true);
    }
    let osm_types: Vec<&str> = m.elements.iter().map(|p| p.osm_type.as_str()).collect();
    let ids: Vec<i64> = m.elements.iter().map(|p| p.id).collect();
    let lats: Vec<f64> = m.elements.iter().map(|p| p.lat).collect();
    let lons: Vec<f64> = m.elements.iter().map(|p| p.lon).collect();
    let tags: Vec<Json<&serde_json::Map<String, serde_json::Value>>> =
        m.elements.iter().map(|p| Json(&p.tags)).collect();
    // one bulk insert; `on conflict` guards against duplicate elements inside a single message
    sqlx::query(
        "insert into poi (fetch_id, osm_type, osm_id, lat, lon, tags) \
         select $1, * from unnest($2::text[], $3::bigint[], $4::float8[], $5::float8[], $6::jsonb[]) \
         on conflict do nothing",
    )
    .bind(m.head.msg_id)
    .bind(osm_types)
    .bind(ids)
    .bind(lats)
    .bind(lons)
    .bind(tags)
    .execute(&mut **tx)
    .await?;
    Ok(true)
}

async fn save_failed(tx: &mut Transaction<'_, Postgres>, m: &Failed) -> Result<bool> {
    insert_result(
        tx,
        &m.head,
        "failed",
        None,
        Some(&m.error),
        Some(&m.attempts),
    )
    .await
}
