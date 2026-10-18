export const normalizeLongitude = (lon) => ((lon + 180) % 360 + 360) % 360 - 180

export const round4 = (value) => Math.round(value * 10000) / 10000

export const splitAtDateline = (track) => {
  const segments = []
  let prev = null
  for (const [lat, lon] of track) {
    if (prev === null || Math.abs(lon - prev) > 180) segments.push([])
    segments[segments.length - 1].push([lat, lon])
    prev = lon
  }
  return segments
}
