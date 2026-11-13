use super::{Acker, Consumer, Delivery, TOPICS};
use anyhow::Result;
use sqlx::{PgPool, postgres::PgPoolOptions, types::Json};
use std::time::Duration;

/// For how many seconds a message stays invisible after `read` if it is not acknowledged.
const VISIBILITY_TIMEOUT_S: i32 = 30;
const POLL_INTERVAL_MS: i32 = 250;

/// pgmq: the queue lives in Postgres (the `pgmq` extension).
pub struct Pgmq(PgPool);

/// pgmq accepts only letters, digits and `_` in a queue name: `poi.fetched` -> `poi_fetched`
/// (the same as in the fetcher publisher).
fn queue_name(topic: &str) -> String {
    topic.replace('.', "_")
}

impl Pgmq {
    pub async fn connect(url: &str) -> Result<Self> {
        let pool = PgPoolOptions::new().max_connections(4).connect(url).await?;
        for topic in TOPICS {
            // idempotent: if the fetcher has already created the queue, nothing happens
            sqlx::query("select pgmq.create($1)")
                .bind(queue_name(topic))
                .execute(&pool)
                .await?;
        }
        Ok(Self(pool))
    }
}

#[async_trait::async_trait]
impl Consumer for Pgmq {
    async fn receive(&self, topic: &str, max: usize, wait: Duration) -> Result<Vec<Delivery>> {
        let queue = queue_name(topic);
        let rows: Vec<(i64, i32, Json<serde_json::Value>)> = sqlx::query_as(
            "select msg_id, read_ct, message from pgmq.read_with_poll($1, $2, $3, $4, $5)",
        )
        .bind(&queue)
        .bind(VISIBILITY_TIMEOUT_S)
        .bind(max as i32)
        .bind(wait.as_secs().max(1) as i32)
        .bind(POLL_INTERVAL_MS)
        .fetch_all(&self.0)
        .await?;

        rows.into_iter()
            .map(|(msg_id, read_ct, Json(message))| {
                let acker = PgmqAcker {
                    pool: self.0.clone(),
                    queue: queue.clone(),
                    msg_id,
                };
                Ok(Delivery::new(
                    topic,
                    serde_json::to_vec(&message)?,
                    Some(read_ct as u32),
                    acker,
                ))
            })
            .collect()
    }
}

struct PgmqAcker {
    pool: PgPool,
    queue: String,
    msg_id: i64,
}

#[async_trait::async_trait]
impl Acker for PgmqAcker {
    async fn ack(&self) -> Result<()> {
        sqlx::query("select pgmq.delete($1, $2)")
            .bind(&self.queue)
            .bind(self.msg_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// Makes the message visible right away, without waiting for the visibility timeout to end.
    async fn nack(&self) -> Result<()> {
        sqlx::query("select pgmq.set_vt($1, $2, 0)")
            .bind(&self.queue)
            .bind(self.msg_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// The message moves to the archive table `pgmq.a_<queue>`.
    async fn reject(&self) -> Result<()> {
        sqlx::query("select pgmq.archive($1, $2)")
            .bind(&self.queue)
            .bind(self.msg_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}
