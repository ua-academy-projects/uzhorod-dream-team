use crate::{
    cache::Cache,
    models::{PoiType, Req},
    mq::{self, Failed, Fetched, Queue},
    overpass,
};
use axum::{
    Router,
    extract::{Query, State},
    http::{StatusCode, header::CONTENT_TYPE},
    response::{IntoResponse, Response},
    routing::get,
};
use serde::Deserialize;
use std::{sync::Arc, time::Duration};

const MAX_RADIUS_M: u32 = 5000;

#[derive(Clone)]
pub struct AppState {
    pub http: reqwest::Client,
    pub endpoints: Arc<[String]>,
    pub queue: Option<Arc<dyn Queue>>,
    pub cache: Option<Arc<dyn Cache>>,
    pub ttl: Duration,
}

#[derive(Deserialize)]
struct Params {
    lat: f64,
    lon: f64,
    radius: u32,
    #[serde(rename = "type")]
    kind: PoiType,
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/pois", get(pois))
        .route("/healthz", get(|| async { "ok" }))
        .with_state(state)
}

async fn pois(State(st): State<AppState>, Query(p): Query<Params>) -> Result<Response, AppError> {
    if !(-90.0..=90.0).contains(&p.lat) || !(-180.0..=180.0).contains(&p.lon) {
        return Err(AppError::BadRequest("coordinates out of range"));
    }
    if !(1..=MAX_RADIUS_M).contains(&p.radius) {
        return Err(AppError::BadRequest("radius must be 1..=5000 m"));
    }
    let req = Req {
        kind: p.kind,
        lat: p.lat,
        lon: p.lon,
        radius: p.radius,
    }
    .rounded();
    let key = req.cache_key();

    // A cache error counts as a miss: the request must not fail because of the cache.
    if let Some(cache) = &st.cache {
        match cache.get(&key).await {
            Ok(Some(body)) => return Ok(json(body)),
            Ok(None) => {}
            Err(e) => eprintln!("cache get {key} failed: {e:#}"),
        }
    }

    match overpass::fetch(&st.http, &st.endpoints, req).await {
        Ok(pois) => {
            let body = serde_json::to_vec(&pois).map_err(anyhow::Error::from)?;
            if let Some(cache) = st.cache.clone() {
                let (body, ttl) = (body.clone(), st.ttl);
                tokio::spawn(async move {
                    if let Err(e) = cache.set(&key, &body, ttl).await {
                        eprintln!("cache set {key} failed: {e:#}");
                    }
                });
            }
            mq::publish(&st.queue, mq::FETCHED, req, Fetched { elements: pois });
            Ok(json(body))
        }
        Err(f) => {
            let body = Failed {
                error: f.to_string(),
                attempts: f.0.clone(),
            };
            mq::publish(&st.queue, mq::FAILED, req, body);
            Err(AppError::Upstream(f.into()))
        }
    }
}

fn json(body: Vec<u8>) -> Response {
    ([(CONTENT_TYPE, "application/json")], body).into_response()
}

enum AppError {
    BadRequest(&'static str),
    Upstream(anyhow::Error),
}

impl From<anyhow::Error> for AppError {
    fn from(e: anyhow::Error) -> Self {
        Self::Upstream(e)
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        match self {
            Self::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg).into_response(),
            Self::Upstream(e) => {
                eprintln!("upstream error: {e:#}");
                (StatusCode::BAD_GATEWAY, "upstream error").into_response()
            }
        }
    }
}
