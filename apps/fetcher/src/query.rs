use crate::models::PoiType;

pub const SERVER_TIMEOUT_S: u64 = 10; // [timeout:N] in the Overpass query

/// `nwr` = node + way + relation; `out center` gives the center coordinates for way/relation.
pub fn build(kind: PoiType, lat: f64, lon: f64, radius: u32) -> String {
    let (k, v) = kind.tag();
    format!(
        r#"[out:json][timeout:{SERVER_TIMEOUT_S}];nwr["{k}"="{v}"](around:{radius},{lat},{lon});out center tags;"#
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn covers_all_element_kinds() {
        let q = build(PoiType::Pharmacy, 50.4651, 30.5156, 1000);
        assert_eq!(
            q,
            r#"[out:json][timeout:10];nwr["amenity"="pharmacy"](around:1000,50.4651,30.5156);out center tags;"#
        );
    }
}
