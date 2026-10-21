use super::Cache;
use anyhow::Result;
use sqlx::{PgPool, postgres::PgPoolOptions};
use std::time::Duration;

const PURGE_EVERY: Duration = Duration::from_secs(600);

/// Postgres: a row per key, `data` = hstore `{v: JSON text, exp: unix seconds}`.
/// hstore stores text, so values must be UTF-8 (our JSON is).
pub struct Pg(PgPool);

impl Pg {
    pub async fn connect(url: &str) -> Result<Self> {
        let pool = PgPoolOptions::new().max_connections(4).connect(url).await?;
        sqlx::raw_sql(
            "create extension if not exists hstore;
             create unlogged table if not exists cache (key text primary key, data hstore not null);",
        )
        .execute(&pool)
        .await?;

        // `get` ignores expired rows; here they are deleted so the table does not grow.
        let purge = pool.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(PURGE_EVERY).await;
                let sql = "delete from cache where (data->'exp')::bigint <= extract(epoch from now())::bigint";
                if let Err(e) = sqlx::query(sql).execute(&purge).await {
                    eprintln!("cache purge failed: {e:#}");
                }
            }
        });
        Ok(Self(pool))
    }
}

#[async_trait::async_trait]
impl Cache for Pg {
    async fn get(&self, key: &str) -> Result<Option<Vec<u8>>> {
        let row: Option<(String,)> = sqlx::query_as(
            "select data->'v' from cache
             where key = $1 and (data->'exp')::bigint > extract(epoch from now())::bigint",
        )
        .bind(key)
        .fetch_optional(&self.0)
        .await?;
        Ok(row.map(|(v,)| v.into_bytes()))
    }

    async fn set(&self, key: &str, value: &[u8], ttl: Duration) -> Result<()> {
        sqlx::query(
            "insert into cache (key, data)
             values ($1, hstore(array['v','exp'], array[$2, (extract(epoch from now())::bigint + $3)::text]))
             on conflict (key) do update set data = excluded.data",
        )
        .bind(key)
        .bind(std::str::from_utf8(value)?)
        .bind(ttl.as_secs() as i64)
        .execute(&self.0)
        .await?;
        Ok(())
    }
}
