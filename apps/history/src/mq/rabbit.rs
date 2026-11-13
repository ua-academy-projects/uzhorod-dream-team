use super::{Acker, Consumer, Delivery, TOPICS};
use anyhow::Result;
use lapin::{
    Channel, Connection, ConnectionProperties,
    options::{
        BasicAckOptions, BasicGetOptions, BasicNackOptions, BasicQosOptions, BasicRejectOptions,
        QueueDeclareOptions,
    },
    types::FieldTable,
};
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

const POLL_INTERVAL: Duration = Duration::from_millis(200);
const PREFETCH: u16 = 32;

/// RabbitMQ: reads from the queue named after the topic (default exchange, as in the fetcher publisher).
/// The connection is re-established on the next `receive` after a drop.
pub struct Rabbit {
    url: String,
    conn: Mutex<(Connection, Channel)>,
}

/// Connection + channel; declares the queues from `TOPICS` with the same parameters as the fetcher
/// (durable), otherwise RabbitMQ answers PRECONDITION_FAILED.
async fn open(url: &str) -> Result<(Connection, Channel)> {
    let conn = Connection::connect(url, ConnectionProperties::default()).await?;
    let ch = conn.create_channel().await?;
    ch.basic_qos(PREFETCH, BasicQosOptions::default()).await?;
    for topic in TOPICS {
        ch.queue_declare(
            topic.into(),
            QueueDeclareOptions::durable(),
            FieldTable::default(),
        )
        .await?;
    }
    Ok((conn, ch))
}

impl Rabbit {
    pub async fn connect(url: &str) -> Result<Self> {
        Ok(Self {
            url: url.into(),
            conn: Mutex::new(open(url).await?),
        })
    }

    /// A live channel; reopens it if the old one died.
    async fn channel(&self) -> Result<Channel> {
        let mut g = self.conn.lock().await;
        if !g.1.status().connected() {
            *g = open(&self.url).await?;
        }
        Ok(g.1.clone())
    }
}

#[async_trait::async_trait]
impl Consumer for Rabbit {
    /// Polls the queue via `basic_get`: waits up to `wait` for the first message,
    /// then takes only what is already in the queue.
    async fn receive(&self, topic: &str, max: usize, wait: Duration) -> Result<Vec<Delivery>> {
        let ch = self.channel().await?;
        let deadline = Instant::now() + wait;
        let mut out = Vec::new();
        while out.len() < max {
            match ch
                .basic_get(topic.into(), BasicGetOptions { no_ack: false })
                .await?
            {
                Some(msg) => {
                    let acker = RabbitAcker {
                        ch: ch.clone(),
                        tag: msg.delivery.delivery_tag,
                    };
                    // RabbitMQ does not count attempts, only the `redelivered` flag
                    out.push(Delivery::new(topic, msg.delivery.data, None, acker));
                }
                None if !out.is_empty() || Instant::now() >= deadline => break,
                None => tokio::time::sleep(POLL_INTERVAL).await,
            }
        }
        Ok(out)
    }
}

/// `delivery_tag` is valid only within the channel that delivered the message. After a reconnect
/// ack/nack returns an error: the broker redelivers the message by itself and the duplicate
/// is absorbed by idempotency on `msg_id`.
struct RabbitAcker {
    ch: Channel,
    tag: u64,
}

#[async_trait::async_trait]
impl Acker for RabbitAcker {
    async fn ack(&self) -> Result<()> {
        Ok(self
            .ch
            .basic_ack(self.tag, BasicAckOptions::default())
            .await?)
    }

    async fn nack(&self) -> Result<()> {
        let opts = BasicNackOptions {
            requeue: true,
            ..Default::default()
        };
        Ok(self.ch.basic_nack(self.tag, opts).await?)
    }

    /// Without requeue: the message disappears (the fetcher queues have no dead-letter exchange).
    async fn reject(&self) -> Result<()> {
        let opts = BasicRejectOptions { requeue: false };
        Ok(self.ch.basic_reject(self.tag, opts).await?)
    }
}
