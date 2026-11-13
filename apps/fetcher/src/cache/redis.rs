use super::Cache;
use anyhow::Result;
use redis::{AsyncCommands, aio::ConnectionManager};
use std::time::Duration;

/// Redis: `GET` / `SET key val EX ttl`. `ConnectionManager` reconnects by itself.
pub struct Redis(ConnectionManager);

impl Redis {
    pub async fn connect(url: &str) -> Result<Self> {
        Ok(Self(
            ConnectionManager::new(redis::Client::open(url)?).await?,
        ))
    }
}

#[async_trait::async_trait]
impl Cache for Redis {
    async fn get(&self, key: &str) -> Result<Option<Vec<u8>>> {
        Ok(self.0.clone().get(key).await?)
    }

    async fn set(&self, key: &str, value: &[u8], ttl: Duration) -> Result<()> {
        // Redis rejects EX 0, so the minimum is 1 s.
        Ok(self
            .0
            .clone()
            .set_ex(key, value, ttl.as_secs().max(1))
            .await?)
    }
}
