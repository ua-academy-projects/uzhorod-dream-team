use anyhow::{Result, bail};
use serde::Deserialize;
use uuid::Uuid;

/// Envelope version this consumer can parse (see `SCHEMA` in the fetcher).
pub const SCHEMA: i16 = 1;

/// Common part of both messages: envelope + request parameters.
#[derive(Deserialize, Debug)]
pub struct Header {
    pub msg_id: Uuid,
    pub schema: i16,
    /// unix seconds
    pub at: i64,
    pub kind: String,
    pub lat: f64,
    pub lon: f64,
    pub radius: i32,
}

#[derive(Deserialize, Debug)]
pub struct Poi {
    pub osm_type: String,
    pub id: i64,
    pub lat: f64,
    pub lon: f64,
    pub tags: serde_json::Map<String, serde_json::Value>,
}

/// `poi.fetched`
#[derive(Deserialize, Debug)]
pub struct Fetched {
    #[serde(flatten)]
    pub head: Header,
    pub elements: Vec<Poi>,
}

/// `fetch.failed`; `attempts` is stored as is.
#[derive(Deserialize, Debug)]
pub struct Failed {
    #[serde(flatten)]
    pub head: Header,
    pub error: String,
    pub attempts: serde_json::Value,
}

#[derive(Debug)]
pub enum Event {
    Fetched(Fetched),
    Failed(Failed),
}

impl Event {
    pub fn msg_id(&self) -> Uuid {
        match self {
            Event::Fetched(m) => m.head.msg_id,
            Event::Failed(m) => m.head.msg_id,
        }
    }
}

/// Parses the payload by topic. An error here is permanent (redelivery won't help).
pub fn parse(topic: &str, payload: &[u8]) -> Result<Event> {
    let (event, schema) = match topic {
        crate::mq::FETCHED => {
            let m: Fetched = serde_json::from_slice(payload)?;
            let schema = m.head.schema;
            (Event::Fetched(m), schema)
        }
        crate::mq::FAILED => {
            let m: Failed = serde_json::from_slice(payload)?;
            let schema = m.head.schema;
            (Event::Failed(m), schema)
        }
        _ => bail!("unknown topic {topic}"),
    };
    if schema != SCHEMA {
        bail!("unsupported schema {schema}, expected {SCHEMA}");
    }
    Ok(event)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn head() -> serde_json::Value {
        json!({"msg_id": "6f1c2c3e-5b0f-4b6e-9d57-1c1f0f2f9a11", "schema": 1, "at": 1760000000,
               "kind": "pharmacy", "lat": 50.4651, "lon": 30.5156, "radius": 1000})
    }

    fn with(extra: serde_json::Value) -> Vec<u8> {
        let mut v = head();
        v.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        v.to_string().into_bytes()
    }

    #[test]
    fn parses_fetched() {
        let p = with(json!({"elements": [
            {"osm_type": "node", "id": 1, "lat": 50.46, "lon": 30.51, "tags": {"amenity": "pharmacy"}}
        ]}));
        let Event::Fetched(m) = parse(crate::mq::FETCHED, &p).unwrap() else {
            panic!("expected Fetched")
        };
        assert_eq!(m.head.kind, "pharmacy");
        assert_eq!(m.head.radius, 1000);
        assert_eq!(m.elements.len(), 1);
        assert_eq!(m.elements[0].tags["amenity"], "pharmacy");
    }

    #[test]
    fn parses_failed() {
        let p = with(json!({"error": "boom", "attempts": [{"endpoint": "e", "error": "x"}]}));
        let Event::Failed(m) = parse(crate::mq::FAILED, &p).unwrap() else {
            panic!("expected Failed")
        };
        assert_eq!(m.error, "boom");
        assert_eq!(m.attempts.as_array().unwrap().len(), 1);
    }

    #[test]
    fn rejects_unknown_schema() {
        let mut v: serde_json::Value =
            serde_json::from_slice(&with(json!({"elements": []}))).unwrap();
        v["schema"] = json!(2);
        let err = parse(crate::mq::FETCHED, v.to_string().as_bytes()).unwrap_err();
        assert!(err.to_string().contains("unsupported schema"));
    }

    #[test]
    fn rejects_garbage_and_unknown_topic() {
        assert!(parse(crate::mq::FETCHED, b"not json").is_err());
        assert!(parse("other", &with(json!({"elements": []}))).is_err());
    }
}
