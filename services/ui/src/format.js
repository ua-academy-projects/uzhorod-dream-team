export const formatTime = (ts) => ts ? new Date(ts * 1000).toLocaleTimeString() : ''

export const formatDateTime = (ts) => new Date(ts * 1000).toLocaleString([], {
  month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit'
})

export const formatSpan = (seconds) => {
  const s = Math.max(0, Math.round(seconds))
  const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60)
  if (d) return `${d}d ${h}h ${m}m`
  if (h) return `${h}h ${m}m ${s % 60}s`
  if (m) return `${m}m ${s % 60}s`
  return `${s}s`
}

export const fixed = (value, digits) => typeof value === 'number' ? value.toFixed(digits) : '0'
