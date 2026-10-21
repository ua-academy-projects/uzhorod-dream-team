use crate::{stats::Stats, store::Sink};
use axum::{Json, Router, extract::State, http::StatusCode, routing::get};
use serde_json::Value;
use std::sync::Arc;

#[derive(Clone)]
struct AppState {
    sink: Arc<dyn Sink>,
    stats: Arc<Stats>,
}

/// `GET /healthz` — 200 if the storage responds, otherwise 503; `GET /stats` — counters.
pub fn router(sink: Arc<dyn Sink>, stats: Arc<Stats>) -> Router {
    Router::new()
        .route("/healthz", get(healthz))
        .route("/stats", get(stats_json))
        .with_state(AppState { sink, stats })
}

async fn healthz(State(app): State<AppState>) -> StatusCode {
    match app.sink.ping().await {
        Ok(()) => StatusCode::OK,
        Err(e) => {
            tracing::warn!("healthz: storage unavailable: {e:#}");
            StatusCode::SERVICE_UNAVAILABLE
        }
    }
}

async fn stats_json(State(app): State<AppState>) -> Json<Value> {
    Json(app.stats.snapshot())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::Event;
    use anyhow::{Result, anyhow};
    use axum::{body::Body, http::Request};
    use tower::ServiceExt;

    struct Fake {
        up: bool,
    }

    #[async_trait::async_trait]
    impl Sink for Fake {
        async fn save(&self, _: &Event) -> Result<bool> {
            Ok(true)
        }
        async fn ping(&self) -> Result<()> {
            self.up.then_some(()).ok_or_else(|| anyhow!("down"))
        }
    }

    async fn get_status(up: bool, path: &str) -> (StatusCode, Vec<u8>) {
        let stats = Arc::new(Stats::new(&["a.b"]));
        stats
            .topic("a.b")
            .saved
            .fetch_add(3, std::sync::atomic::Ordering::Relaxed);
        let res = router(Arc::new(Fake { up }), stats)
            .oneshot(Request::get(path).body(Body::empty()).unwrap())
            .await
            .unwrap();
        let status = res.status();
        let body = axum::body::to_bytes(res.into_body(), usize::MAX)
            .await
            .unwrap();
        (status, body.to_vec())
    }

    #[tokio::test]
    async fn healthz_follows_storage() {
        assert_eq!(get_status(true, "/healthz").await.0, StatusCode::OK);
        assert_eq!(
            get_status(false, "/healthz").await.0,
            StatusCode::SERVICE_UNAVAILABLE
        );
    }

    #[tokio::test]
    async fn stats_returns_counters() {
        let (status, body) = get_status(true, "/stats").await;
        assert_eq!(status, StatusCode::OK);
        let v: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(v["a.b"]["saved"], 3);
        assert_eq!(v["a.b"]["rejected"], 0);
    }
}
