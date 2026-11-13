use anyhow::{Result, bail};
use std::{sync::Arc, time::Duration};

// Topic names and the topic set must match the fetcher (`fetcher/src/mq/mod.rs`).
pub const FETCHED: &str = "poi.fetched";
pub const FAILED: &str = "fetch.failed";
pub const TOPICS: [&str; 2] = [FETCHED, FAILED];

pub mod pgmq;
pub mod rabbit;

/// Message source (RabbitMQ, pgmq, ...). The processing code knows only this trait.
#[async_trait::async_trait]
pub trait Consumer: Send + Sync {
    /// Up to `max` messages from `topic`; waits no longer than `wait`, an empty `Vec` means there is nothing.
    /// A received message must be closed with `ack`/`nack`/`reject`, otherwise it
    /// returns to the queue by itself (visibility timeout / channel drop).
    async fn receive(&self, topic: &str, max: usize, wait: Duration) -> Result<Vec<Delivery>>;
}

/// Backend-specific acknowledgement of a single message.
#[async_trait::async_trait]
pub(crate) trait Acker: Send + Sync {
    async fn ack(&self) -> Result<()>;
    async fn nack(&self) -> Result<()>;
    async fn reject(&self) -> Result<()>;
}

/// A single received message; the same for all backends.
pub struct Delivery {
    pub topic: String,
    pub payload: Vec<u8>,
    /// How many times the message has been delivered (including this attempt), if the backend knows:
    /// pgmq — `read_ct`, RabbitMQ — no (`None`).
    pub attempt: Option<u32>,
    acker: Box<dyn Acker>,
}

impl Delivery {
    pub(crate) fn new(
        topic: &str,
        payload: Vec<u8>,
        attempt: Option<u32>,
        acker: impl Acker + 'static,
    ) -> Self {
        Self {
            topic: topic.into(),
            payload,
            attempt,
            acker: Box::new(acker),
        }
    }

    /// Processed: remove from the queue.
    pub async fn ack(&self) -> Result<()> {
        self.acker.ack().await
    }

    /// Transient error: return to the queue for redelivery.
    pub async fn nack(&self) -> Result<()> {
        self.acker.nack().await
    }

    /// Poison message: do not deliver again (pgmq — to the archive, RabbitMQ — without requeue).
    pub async fn reject(&self) -> Result<()> {
        self.acker.reject().await
    }
}

/// Picks the backend by the URL scheme: `amqp(s)://` — RabbitMQ, `postgres(ql)://` — pgmq.
/// Each backend creates the queues from `TOPICS` itself.
pub async fn connect(url: &str) -> Result<Arc<dyn Consumer>> {
    Ok(match url.split_once("://").map(|(scheme, _)| scheme) {
        Some("amqp" | "amqps") => Arc::new(rabbit::Rabbit::connect(url).await?),
        Some("postgres" | "postgresql") => Arc::new(pgmq::Pgmq::connect(url).await?),
        _ => bail!("QUEUE_URL: expected amqp(s):// or postgres(ql):// scheme"),
    })
}
