use crate::{
    models::{Element, Poi, Req},
    query::{self, SERVER_TIMEOUT_S},
};
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::{
    fmt,
    time::{Duration, Instant},
};

const ATTEMPTS_PER_ENDPOINT: u32 = 2;
const RETRY_DELAY: Duration = Duration::from_millis(500);
pub const HTTP_TIMEOUT: Duration = Duration::from_secs(SERVER_TIMEOUT_S + 2);

#[derive(Deserialize)]
struct Response {
    elements: Vec<Element>,
    remark: Option<String>,
}

/// Marker error (timeout / out of memory on the Overpass side) to tell it apart from other errors.
#[derive(Debug)]
struct Remark(String);

impl fmt::Display for Remark {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "overpass remark: {}", self.0)
    }
}

impl std::error::Error for Remark {}

/// A failed attempt against a single endpoint.
#[derive(Serialize, Clone, Debug)]
pub struct Attempt {
    pub endpoint: String,
    pub error: String,
}

/// All endpoints exhausted; keeps every failed attempt.
#[derive(Debug)]
pub struct Failure(pub Vec<Attempt>);

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.0.last() {
            Some(a) => write!(
                f,
                "all overpass endpoints failed ({} attempts), last: {}",
                self.0.len(),
                a.error
            ),
            None => write!(f, "no overpass endpoints configured"),
        }
    }
}

impl std::error::Error for Failure {}

/// Errors worth retrying, or worth trying another server for.
fn is_retryable(e: &anyhow::Error) -> bool {
    e.is::<Remark>()
        || e.downcast_ref::<reqwest::Error>().is_some_and(|re| {
            re.is_timeout()
                || re.is_connect()
                || matches!(re.status().map(|s| s.as_u16()), Some(429 | 502 | 503 | 504))
        })
}

async fn try_endpoint(http: &reqwest::Client, url: &str, query: &str) -> Result<Vec<Poi>> {
    let resp: Response = http
        .post(url)
        .form(&[("data", query)])
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    // a remark with non-empty elements is a partial response, not a failure.
    match resp.remark {
        Some(r) if resp.elements.is_empty() => Err(Remark(r).into()),
        _ => Ok(resp
            .elements
            .into_iter()
            .filter_map(Element::into_poi)
            .collect()),
    }
}

/// Tries the endpoints in turn, up to `ATTEMPTS_PER_ENDPOINT` attempts on each.
pub async fn fetch(
    http: &reqwest::Client,
    endpoints: &[String],
    req: Req,
) -> Result<Vec<Poi>, Failure> {
    let Req {
        kind,
        lat,
        lon,
        radius,
    } = req;
    let query = query::build(kind, lat, lon, radius);
    let mut attempts = Vec::new();

    for url in endpoints {
        for attempt in 1..=ATTEMPTS_PER_ENDPOINT {
            let started = Instant::now();
            match try_endpoint(http, url, &query).await {
                Ok(pois) => {
                    println!(
                        "{url}: ok, {kind:?} r={radius}m at {lat},{lon} -> {} pois in {} ms (attempt {attempt}/{ATTEMPTS_PER_ENDPOINT})",
                        pois.len(),
                        started.elapsed().as_millis(),
                    );
                    return Ok(pois);
                }
                Err(e) if is_retryable(&e) => {
                    eprintln!("{url}: attempt {attempt}/{ATTEMPTS_PER_ENDPOINT} failed: {e:#}");
                    attempts.push(Attempt {
                        endpoint: url.clone(),
                        error: format!("{e:#}"),
                    });
                    if attempt < ATTEMPTS_PER_ENDPOINT {
                        tokio::time::sleep(RETRY_DELAY).await;
                    }
                }
                Err(e) => {
                    eprintln!("{url}: non-retryable error, skipping endpoint: {e:#}");
                    attempts.push(Attempt {
                        endpoint: url.clone(),
                        error: format!("{e:#}"),
                    });
                    break;
                }
            }
        }
    }

    Err(Failure(attempts))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remark_is_retryable_other_errors_are_not() {
        assert!(is_retryable(&Remark("timeout".into()).into()));
        assert!(!is_retryable(&anyhow::anyhow!("bad json")));
    }
}
