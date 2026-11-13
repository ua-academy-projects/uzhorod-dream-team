use anyhow::Result;
use axum::{Json, Router, routing::post};
use fetcher::{
    api::{self, AppState},
    mq::Queue,
};
use serde_json::{Value, json};
use std::{sync::Arc, time::Duration};
use tokio::{net::TcpListener, sync::mpsc};

/// A queue that forwards what is published into a channel.
struct Recorder(mpsc::UnboundedSender<(String, Value)>);

#[async_trait::async_trait]
impl Queue for Recorder {
    async fn publish(&self, topic: &str, payload: &[u8]) -> Result<()> {
        self.0
            .send((topic.into(), serde_json::from_slice(payload)?))?;
        Ok(())
    }
}

async fn serve(app: Router) -> String {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(l, app).await });
    format!("http://{addr}")
}

/// Starts the fetcher with a mock Overpass (or a dead endpoint) and returns its URL and the queue receiver.
async fn setup(overpass: Option<Router>) -> (String, mpsc::UnboundedReceiver<(String, Value)>) {
    let endpoint = match overpass {
        Some(app) => format!("{}/api/interpreter", serve(app).await),
        None => "http://127.0.0.1:1/api/interpreter".into(), // connection refused
    };
    let (tx, rx) = mpsc::unbounded_channel();
    let state = AppState {
        http: reqwest::Client::new(),
        endpoints: Arc::from([endpoint]),
        queue: Some(Arc::new(Recorder(tx))),
        cache: None,
        ttl: Duration::from_secs(60),
    };
    (serve(api::router(state)).await, rx)
}

const Q: &str = "/pois?lat=50.4651&lon=30.5156&radius=1000&type=pharmacy";

#[tokio::test]
async fn success_publishes_poi_fetched() {
    let mock = Router::new().route(
        "/api/interpreter",
        post(|| async {
            Json(json!({"elements":[
                {"type":"node","id":1,"lat":50.46,"lon":30.51,"tags":{"amenity":"pharmacy"}},
                {"type":"way","id":2,"center":{"lat":50.47,"lon":30.52}}]}))
        }),
    );
    let (url, mut rx) = setup(Some(mock)).await;

    let resp: Vec<Value> = reqwest::get(format!("{url}{Q}"))
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(resp.len(), 2);

    let (topic, msg) = rx.recv().await.unwrap();
    assert_eq!(topic, "poi.fetched");
    assert_eq!(
        (
            msg["schema"].as_u64(),
            msg["kind"].as_str(),
            msg["radius"].as_u64()
        ),
        (Some(1), Some("pharmacy"), Some(1000))
    );
    assert!(msg["msg_id"].is_string() && msg["at"].as_u64().unwrap() > 0);
    assert_eq!(msg["elements"].as_array().unwrap().len(), 2);
    assert_eq!(msg["elements"][1]["osm_type"], "way");
}

#[tokio::test]
async fn exhausted_endpoints_publish_fetch_failed() {
    let (url, mut rx) = setup(None).await;

    let status = reqwest::get(format!("{url}{Q}")).await.unwrap().status();
    assert_eq!(status, 502);

    let (topic, msg) = rx.recv().await.unwrap();
    assert_eq!(topic, "fetch.failed");
    assert_eq!(msg["kind"], "pharmacy");
    assert_eq!(msg["attempts"].as_array().unwrap().len(), 2); // ATTEMPTS_PER_ENDPOINT
    assert_eq!(
        msg["attempts"][0]["endpoint"],
        "http://127.0.0.1:1/api/interpreter"
    );
    assert!(
        msg["error"]
            .as_str()
            .unwrap()
            .contains("all overpass endpoints failed")
    );
}
