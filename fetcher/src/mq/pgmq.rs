use super::{Queue, TOPICS};
use anyhow::Result;
use sqlx::{PgPool, postgres::PgPoolOptions};

/// pgmq: the queue lives in Postgres (the `pgmq` extension). The consumer reads via `pgmq.read`.
pub struct Pgmq(PgPool);

/// pgmq accepts only letters, digits and `_` in a queue name: `poi.fetched` -> `poi_fetched`.
fn queue_name(topic: &str) -> String {
    topic.replace('.', "_")
}

impl Pgmq {
    pub async fn connect(url: &str) -> Result<Self> {
        let pool = PgPoolOptions::new().max_connections(4).connect(url).await?;
        for topic in TOPICS {
            sqlx::query("select pgmq.create($1)")
                .bind(queue_name(topic))
                .execute(&pool)
                .await?;
        }
        Ok(Self(pool))
    }
}

#[async_trait::async_trait]
impl Queue for Pgmq {
    async fn publish(&self, topic: &str, payload: &[u8]) -> Result<()> {
        // `::text::jsonb`: the parameter is sent as text, Postgres validates the JSON itself.
        sqlx::query("select pgmq.send($1, $2::text::jsonb)")
            .bind(queue_name(topic))
            .bind(std::str::from_utf8(payload)?)
            .execute(&self.0)
            .await?;
        Ok(())
    }
}
