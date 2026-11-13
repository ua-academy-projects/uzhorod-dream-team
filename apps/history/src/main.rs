use anyhow::{Context, Result};
use history::{
    http, mq,
    stats::Stats,
    store::{Sink, Store},
    worker,
};
use std::{io::IsTerminal, sync::Arc};
use tokio::{
    signal::unix::{SignalKind, signal},
    sync::watch,
};
use tracing_subscriber::EnvFilter;

const DEFAULT_PORT: u16 = 8081;

fn env(name: &str) -> Result<String> {
    std::env::var(name).with_context(|| format!("{name} is not set"))
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = dotenvy::dotenv();

    // no timestamps: journald adds its own; ANSI colors only on a terminal
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| "info,sqlx=error".into()),
        )
        .with_ansi(std::io::stdout().is_terminal())
        .without_time()
        .init();

    let store = Store::connect(&env("DATABASE_URL")?).await?;
    let consumer = mq::connect(&env("QUEUE_URL")?).await?;
    let sink: Arc<dyn Sink> = Arc::new(store);
    let stats = Arc::new(Stats::new(&mq::TOPICS));

    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(DEFAULT_PORT);
    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port)).await?;

    let (stop_tx, stop_rx) = watch::channel(false);
    let mut tasks: Vec<_> = mq::TOPICS
        .into_iter()
        .map(|topic| {
            tokio::spawn(worker::run(
                consumer.clone(),
                sink.clone(),
                stats.clone(),
                topic,
                stop_rx.clone(),
            ))
        })
        .collect();
    let mut http_stop = stop_rx.clone();
    tasks.push(tokio::spawn(async move {
        let served = axum::serve(listener, http::router(sink, stats))
            .with_graceful_shutdown(async move {
                let _ = http_stop.wait_for(|stop| *stop).await;
            })
            .await;
        if let Err(e) = served {
            tracing::error!("http server: {e:#}");
        }
    }));
    tracing::info!(topics = ?mq::TOPICS, port, "consuming");

    let mut term = signal(SignalKind::terminate())?;
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = term.recv() => {}
    }
    tracing::info!("shutting down");
    stop_tx.send(true)?;
    for t in tasks {
        t.await?;
    }
    Ok(())
}
