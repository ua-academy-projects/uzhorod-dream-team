use anyhow::{Result, bail};
use axum::{Json, Router, routing::post};
use fetcher::{
    api::{self, AppState},
    cache::{Cache, pg::Pg, redis::Redis},
};
use serde_json::json;
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::net::TcpListener;

/// In-memory cache; `broken` simulates an unavailable backend.
#[derive(Default)]
struct MemCache {
    map: Mutex<HashMap<String, Vec<u8>>>,
    broken: bool,
}

#[async_trait::async_trait]
impl Cache for MemCache {
    async fn get(&self, key: &str) -> Result<Option<Vec<u8>>> {
        if self.broken {
            bail!("cache down");
        }
        Ok(self.map.lock().unwrap().get(key).cloned())
    }
    async fn set(&self, key: &str, value: &[u8], _ttl: Duration) -> Result<()> {
        if self.broken {
            bail!("cache down");
        }
        self.map.lock().unwrap().insert(key.into(), value.to_vec());
        Ok(())
    }
}

async fn serve(app: Router) -> String {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(l, app).await });
    format!("http://{addr}")
}

/// Fetcher with a cache and a mock Overpass that counts requests (`ok = false` — always 500).
async fn setup(cache: Arc<MemCache>, ok: bool) -> (String, Arc<AtomicUsize>) {
    let calls = Arc::new(AtomicUsize::new(0));
    let c = calls.clone();
    let mock = Router::new().route(
        "/api/interpreter",
        post(move || async move {
            c.fetch_add(1, Ordering::SeqCst);
            if !ok {
                return Err(axum::http::StatusCode::INTERNAL_SERVER_ERROR);
            }
            Ok(Json(
                json!({"elements":[{"type":"node","id":1,"lat":50.46,"lon":30.51}]}),
            ))
        }),
    );
    let endpoint = format!("{}/api/interpreter", serve(mock).await);
    let state = AppState {
        http: reqwest::Client::new(),
        endpoints: Arc::from([endpoint]),
        queue: None,
        cache: Some(cache),
        ttl: Duration::from_secs(60),
    };
    (serve(api::router(state)).await, calls)
}

fn url(base: &str, lat: &str, lon: &str) -> String {
    format!("{base}/pois?lat={lat}&lon={lon}&radius=1000&type=pharmacy")
}

async fn get_body(url: &str) -> String {
    reqwest::get(url).await.unwrap().text().await.unwrap()
}

/// `set` in the handler runs in the background — wait until the entry appears.
async fn wait_cached(cache: &MemCache) {
    for _ in 0..50 {
        if !cache.map.lock().unwrap().is_empty() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("nothing was cached");
}

#[tokio::test]
async fn repeat_and_nearby_requests_skip_overpass() {
    let cache = Arc::new(MemCache::default());
    let (base, calls) = setup(cache.clone(), true).await;

    let first = get_body(&url(&base, "50.46512", "30.51558")).await;
    wait_cached(&cache).await;
    let second = get_body(&url(&base, "50.46512", "30.51558")).await;
    let nearby = get_body(&url(&base, "50.46509", "30.51555")).await; // same key after rounding

    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!((&first, &first), (&second, &nearby));
    assert!(first.contains(r#""osm_type":"node""#));
    assert_eq!(
        cache.map.lock().unwrap().keys().collect::<Vec<_>>(),
        ["pois:pharmacy:50.4651:30.5156:1000"]
    );

    // A different point means a different key, so Overpass is hit again.
    get_body(&url(&base, "50.4700", "30.5156")).await;
    assert_eq!(calls.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn broken_cache_does_not_fail_requests() {
    let cache = Arc::new(MemCache {
        broken: true,
        ..Default::default()
    });
    let (base, calls) = setup(cache, true).await;

    let resp = reqwest::get(url(&base, "50.4651", "30.5156"))
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    assert!(resp.text().await.unwrap().contains("node"));
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn failures_are_not_cached() {
    let cache = Arc::new(MemCache::default());
    let (base, _) = setup(cache.clone(), false).await;

    assert_eq!(
        reqwest::get(url(&base, "50.4651", "30.5156"))
            .await
            .unwrap()
            .status(),
        502
    );
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(cache.map.lock().unwrap().is_empty());
}

// ---- Real backends: `TEST_REDIS_URL` / `TEST_PG_URL`, run with `cargo test -- --ignored` ----

async fn roundtrip(c: &dyn Cache) {
    assert_eq!(c.get("t:missing").await.unwrap(), None);

    c.set(
        "t:key",
        r#"{"a":"Аптека"}"#.as_bytes(),
        Duration::from_secs(60),
    )
    .await
    .unwrap();
    assert_eq!(
        c.get("t:key").await.unwrap().unwrap(),
        r#"{"a":"Аптека"}"#.as_bytes()
    );

    c.set("t:key", b"[2]", Duration::from_secs(60))
        .await
        .unwrap(); // overwrite
    assert_eq!(c.get("t:key").await.unwrap().unwrap(), b"[2]");

    c.set("t:short", b"[]", Duration::from_secs(1))
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(2100)).await;
    assert_eq!(c.get("t:short").await.unwrap(), None); // expired
}

#[tokio::test]
#[ignore]
async fn redis_roundtrip_and_ttl() {
    let url = std::env::var("TEST_REDIS_URL").expect("TEST_REDIS_URL");
    roundtrip(&Redis::connect(&url).await.unwrap()).await;
}

#[tokio::test]
#[ignore]
async fn postgres_hstore_roundtrip_and_ttl() {
    let url = std::env::var("TEST_PG_URL").expect("TEST_PG_URL");
    roundtrip(&Pg::connect(&url).await.unwrap()).await;
}
