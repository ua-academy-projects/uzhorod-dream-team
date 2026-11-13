use anyhow::{Result, bail};
use std::{sync::Arc, time::Duration};

pub mod pg;
pub mod redis;

/// Key-value response cache (Redis, Postgres hstore, ...). Values are JSON (UTF-8).
/// The key is built by `Req::cache_key`.
#[async_trait::async_trait]
pub trait Cache: Send + Sync {
    async fn get(&self, key: &str) -> Result<Option<Vec<u8>>>;
    async fn set(&self, key: &str, value: &[u8], ttl: Duration) -> Result<()>;
}

/// Which cache to bring up (or why none).
#[derive(Debug, PartialEq, Eq)]
pub enum Target {
    Off(&'static str),
    Redis(String),
    Pg(String),
}

/// There is no separate variable for the cache: the backend is paired with the queue by the `QUEUE_URL` scheme:
/// `amqp(s)://` (RabbitMQ) — Redis from `REDIS_URL`; `postgres(ql)://` (pgmq) — hstore in the same DB.
pub fn target(queue_url: Option<&str>, redis_url: Option<&str>) -> Result<Target> {
    let Some(queue_url) = queue_url else {
        return Ok(Target::Off("QUEUE_URL not set"));
    };
    Ok(
        match queue_url.split_once("://").map(|(scheme, _)| scheme) {
            Some("amqp" | "amqps") => match redis_url {
                Some(url) => Target::Redis(url.into()),
                None => Target::Off("REDIS_URL not set"),
            },
            Some("postgres" | "postgresql") => Target::Pg(queue_url.into()),
            _ => bail!("QUEUE_URL: expected amqp(s):// or postgres(ql):// scheme"),
        },
    )
}

/// Brings up the cache chosen by `target(QUEUE_URL, REDIS_URL)`; if there will be none, logs the reason.
pub async fn from_env() -> Result<Option<Arc<dyn Cache>>> {
    let queue_url = std::env::var("QUEUE_URL").ok();
    let redis_url = std::env::var("REDIS_URL").ok();
    let cache: Arc<dyn Cache> = match target(queue_url.as_deref(), redis_url.as_deref())? {
        Target::Off(why) => {
            println!("cache: disabled ({why})");
            return Ok(None);
        }
        Target::Redis(url) => Arc::new(redis::Redis::connect(&url).await?),
        Target::Pg(url) => Arc::new(pg::Pg::connect(&url).await?),
    };
    Ok(Some(cache))
}

#[cfg(test)]
mod tests {
    use super::*;

    const AMQP: &str = "amqp://u:p@mq:5672/%2f";
    const PG: &str = "postgres://u:p@db:5432/db";
    const REDIS: &str = "redis://:p@mq:6379";

    #[test]
    fn amqp_pairs_with_redis() {
        assert_eq!(
            target(Some(AMQP), Some(REDIS)).unwrap(),
            Target::Redis(REDIS.into())
        );
        assert_eq!(
            target(Some("amqps://u:p@mq/%2f"), Some(REDIS)).unwrap(),
            Target::Redis(REDIS.into())
        );
    }

    #[test]
    fn amqp_without_redis_url_disables_cache() {
        assert_eq!(
            target(Some(AMQP), None).unwrap(),
            Target::Off("REDIS_URL not set")
        );
    }

    #[test]
    fn postgres_uses_hstore_in_the_queue_db_and_ignores_redis_url() {
        assert_eq!(
            target(Some(PG), Some(REDIS)).unwrap(),
            Target::Pg(PG.into())
        );
        assert_eq!(target(Some(PG), None).unwrap(), Target::Pg(PG.into()));
    }

    #[test]
    fn no_queue_means_no_cache() {
        assert_eq!(
            target(None, Some(REDIS)).unwrap(),
            Target::Off("QUEUE_URL not set")
        );
    }

    #[test]
    fn unknown_scheme_is_an_error() {
        assert!(target(Some("http://x"), None).is_err());
        assert!(target(Some("nonsense"), None).is_err());
    }
}
