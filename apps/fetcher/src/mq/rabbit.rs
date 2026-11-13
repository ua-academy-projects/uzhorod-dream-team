use super::{Queue, TOPICS};
use anyhow::{Result, bail};
use lapin::{
    BasicProperties, Channel, Confirmation, Connection, ConnectionProperties,
    options::{BasicPublishOptions, ConfirmSelectOptions, QueueDeclareOptions},
    types::FieldTable,
};
use tokio::sync::Mutex;

/// RabbitMQ: publishes to the default exchange, routing key = queue name = topic.
/// The connection is re-established on the next publish after a drop.
pub struct Rabbit {
    url: String,
    conn: Mutex<(Connection, Channel)>,
}

/// Connection + channel with publisher confirms; declares durable queues from `TOPICS`.
async fn open(url: &str) -> Result<(Connection, Channel)> {
    let conn = Connection::connect(url, ConnectionProperties::default()).await?;
    let ch = conn.create_channel().await?;
    ch.confirm_select(ConfirmSelectOptions::default()).await?;
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
impl Queue for Rabbit {
    async fn publish(&self, topic: &str, payload: &[u8]) -> Result<()> {
        let confirm = self
            .channel()
            .await?
            .basic_publish(
                "".into(),
                topic.into(),
                BasicPublishOptions::default(),
                payload,
                BasicProperties::default().with_delivery_mode(2), // persistent
            )
            .await?
            .await?;
        if let Confirmation::Nack(_) = confirm {
            bail!("rabbitmq nacked message for {topic}");
        }
        Ok(())
    }
}
