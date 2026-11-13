use anyhow::{Result, bail};
use fetcher::{
    api::{self, AppState},
    cache, mq,
    overpass::HTTP_TIMEOUT,
};
use std::{sync::Arc, time::Duration};

const DEFAULT_CACHE_TTL_S: u64 = 3600;
const DEFAULT_OVERPASS_URL: &str = "https://overpass-api.de/api/interpreter";

fn endpoints_from_env() -> Result<Arc<[String]>> {
    let endpoints: Arc<[String]> = std::env::var("OVERPASS_URLS")
        .unwrap_or_else(|_| DEFAULT_OVERPASS_URL.into())
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
        .collect();

    if endpoints.is_empty() {
        bail!("OVERPASS_URLS contains no endpoints");
    }
    Ok(endpoints)
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = dotenvy::dotenv();
    let endpoints = endpoints_from_env()?;
    println!("overpass endpoints: {endpoints:?}");

    let queue = mq::from_env().await?;
    println!(
        "queue: {}",
        if queue.is_some() {
            "enabled"
        } else {
            "disabled (QUEUE_URL not set)"
        }
    );

    // if there is no cache, `from_env` has already printed the reason
    let cache = cache::from_env().await?;
    if cache.is_some() {
        println!("cache: enabled");
    }
    let ttl_s = std::env::var("CACHE_TTL_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_CACHE_TTL_S);

    let http = reqwest::Client::builder()
        .user_agent("poi-fetcher/0.1")
        .timeout(HTTP_TIMEOUT)
        .build()?;

    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8080);

    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port)).await?;
    println!("listening on :{port}");
    axum::serve(
        listener,
        api::router(AppState {
            http,
            endpoints,
            queue,
            cache,
            ttl: Duration::from_secs(ttl_s),
        }),
    )
    .await?;
    Ok(())
}
