use crate::{
    models::{Poi, Req},
    overpass::Attempt,
};
use anyhow::{Result, bail};
use serde::Serialize;
use std::{
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;

pub const FETCHED: &str = "poi.fetched";
pub const FAILED: &str = "fetch.failed";
pub const TOPICS: [&str; 2] = [FETCHED, FAILED];
const SCHEMA: u8 = 1;

pub mod pgmq;
pub mod rabbit;

/// Message queue (RabbitMQ, pgmq, ...).
#[async_trait::async_trait]
pub trait Queue: Send + Sync {
    async fn publish(&self, topic: &str, payload: &[u8]) -> Result<()>;
}

/// Picks the backend by the `QUEUE_URL` scheme: `amqp(s)://` — RabbitMQ, `postgres(ql)://` — pgmq.
/// Without `QUEUE_URL` publishing is disabled. Each backend creates the queues from `TOPICS` itself.
pub async fn from_env() -> Result<Option<Arc<dyn Queue>>> {
    let Ok(url) = std::env::var("QUEUE_URL") else {
        return Ok(None);
    };
    let queue: Arc<dyn Queue> = match url.split_once("://").map(|(scheme, _)| scheme) {
        Some("amqp" | "amqps") => Arc::new(rabbit::Rabbit::connect(&url).await?),
        Some("postgres" | "postgresql") => Arc::new(pgmq::Pgmq::connect(&url).await?),
        _ => bail!("QUEUE_URL: expected amqp(s):// or postgres(ql):// scheme"),
    };
    Ok(Some(queue))
}

/// Body of `poi.fetched`: the result of a successful request (may be empty).
#[derive(Serialize)]
pub struct Fetched {
    pub elements: Vec<Poi>,
}

/// Body of `fetch.failed`: all endpoints exhausted.
#[derive(Serialize)]
pub struct Failed {
    pub error: String,
    pub attempts: Vec<Attempt>,
}

/// Envelope: `msg_id` for idempotency on the consumer side, `at` is unix seconds.
#[derive(Serialize)]
struct Msg<T> {
    msg_id: Uuid,
    schema: u8,
    at: u64,
    #[serde(flatten)]
    req: Req,
    #[serde(flatten)]
    body: T,
}

/// Fire-and-forget: publishing does not block the client response, an error is only logged.
pub fn publish<T: Serialize + Send + 'static>(
    queue: &Option<Arc<dyn Queue>>,
    topic: &'static str,
    req: Req,
    body: T,
) {
    let Some(queue) = queue.clone() else { return };
    tokio::spawn(async move {
        let at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        let msg = Msg {
            msg_id: Uuid::new_v4(),
            schema: SCHEMA,
            at,
            req,
            body,
        };
        let res = match serde_json::to_vec(&msg) {
            Ok(bytes) => queue.publish(topic, &bytes).await,
            Err(e) => Err(e.into()),
        };
        if let Err(e) = res {
            eprintln!("publish to {topic} failed: {e:#}");
        }
    });
}
