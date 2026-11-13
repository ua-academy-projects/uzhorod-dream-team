use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Serialize, Deserialize, Clone, Copy, Debug)]
#[serde(rename_all = "snake_case")]
pub enum PoiType {
    Cafe,
    Restaurant,
    Pharmacy,
    Atm,
    Fuel,
    Bakery,
    Supermarket,
}

impl PoiType {
    pub fn tag(self) -> (&'static str, &'static str) {
        match self {
            Self::Cafe => ("amenity", "cafe"),
            Self::Restaurant => ("amenity", "restaurant"),
            Self::Pharmacy => ("amenity", "pharmacy"),
            Self::Atm => ("amenity", "atm"),
            Self::Fuel => ("amenity", "fuel"),
            Self::Bakery => ("shop", "bakery"),
            Self::Supermarket => ("shop", "supermarket"),
        }
    }
}

/// Request parameters: they go into the cache key, the Overpass query and the queue message.
#[derive(Serialize, Clone, Copy)]
pub struct Req {
    pub kind: PoiType,
    pub lat: f64,
    pub lon: f64,
    pub radius: u32,
}

impl Req {
    /// Coordinates rounded to 4 decimals (~11 m): nearby requests match both by key and by the query itself.
    pub fn rounded(self) -> Self {
        let r = |x: f64| (x * 1e4).round() / 1e4;
        Self {
            lat: r(self.lat),
            lon: r(self.lon),
            ..self
        }
    }

    pub fn cache_key(&self) -> String {
        format!(
            "pois:{}:{:.4}:{:.4}:{}",
            self.kind.tag().1,
            self.lat,
            self.lon,
            self.radius
        )
    }
}

#[derive(Deserialize)]
struct LatLon {
    lat: f64,
    lon: f64,
}

/// Overpass response element: a node has lat/lon, a way/relation has `center`.
#[derive(Deserialize)]
pub struct Element {
    #[serde(rename = "type")]
    osm_type: String,
    id: i64,
    lat: Option<f64>,
    lon: Option<f64>,
    center: Option<LatLon>,
    #[serde(default)]
    tags: HashMap<String, String>,
}

/// Flat object in the service response. `osm_type` is needed because ids of node/way/relation overlap.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Poi {
    pub osm_type: String,
    pub id: i64,
    pub lat: f64,
    pub lon: f64,
    pub tags: HashMap<String, String>,
}

impl Element {
    /// `None` if the element has no coordinates.
    pub fn into_poi(self) -> Option<Poi> {
        let (lat, lon) = match (self.lat, self.lon, self.center) {
            (Some(lat), Some(lon), _) => (lat, lon),
            (_, _, Some(c)) => (c.lat, c.lon),
            _ => return None,
        };
        Some(Poi {
            osm_type: self.osm_type,
            id: self.id,
            lat,
            lon,
            tags: self.tags,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nearby_requests_share_a_cache_key() {
        let req = |lat, lon| Req {
            kind: PoiType::Pharmacy,
            lat,
            lon,
            radius: 1000,
        };
        let key = |r: Req| r.rounded().cache_key();
        assert_eq!(
            key(req(50.46512, 30.51558)),
            "pois:pharmacy:50.4651:30.5156:1000"
        );
        assert_eq!(key(req(50.46512, 30.51558)), key(req(50.46509, 30.51555)));
        assert_ne!(key(req(50.46512, 30.51558)), key(req(50.4660, 30.51558)));
    }

    #[test]
    fn node_way_relation_to_poi() {
        let json = r#"[
            {"type":"node","id":1,"lat":50.1,"lon":30.1,"tags":{"name":"a"}},
            {"type":"way","id":2,"center":{"lat":50.2,"lon":30.2},"tags":{}},
            {"type":"relation","id":3,"center":{"lat":50.3,"lon":30.3}},
            {"type":"way","id":4}
        ]"#;
        let pois: Vec<Poi> = serde_json::from_str::<Vec<Element>>(json)
            .unwrap()
            .into_iter()
            .filter_map(Element::into_poi)
            .collect();
        let got: Vec<_> = pois
            .iter()
            .map(|p| (p.osm_type.as_str(), p.id, p.lat))
            .collect();
        assert_eq!(
            got,
            [("node", 1, 50.1), ("way", 2, 50.2), ("relation", 3, 50.3)]
        );
    }
}
