<template>
  <div class="card map-container">
    <div ref="mapEl" class="map"></div>
  </div>
</template>

<script setup>
import { onBeforeUnmount, onMounted, ref, watch } from 'vue'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { splitAtDateline } from '../geo'

const props = defineProps({
  history: { type: Array, required: true },
  location: { type: Object, default: null },
  passes: { type: Object, default: null },
  followIss: { type: Boolean, required: true }
})

const emit = defineEmits(['select'])

const WORLD = L.latLngBounds([[-85.0511, -180], [85.0511, 180]])

const mapEl = ref(null)
let map = null
let issMarker, issTrack, userMarker, userCircle, lastPassLine, nextPassLine

const drawIss = () => {
  const latest = props.history[0]
  if (!map || !latest) return
  const pos = [latest.latitude, latest.longitude]
  issMarker.setLatLng(pos)
  if (props.followIss) map.panTo(pos, { animate: true, duration: 1 })
  issTrack.setLatLngs(splitAtDateline(props.history.map(h => [h.latitude, h.longitude])))
}

const drawLocation = () => {
  if (!map || !props.location) return
  const pos = [props.location.latitude, props.location.longitude]
  userMarker.setLatLng(pos).addTo(map)
  userCircle.setLatLng(pos).setRadius(props.location.radius_km * 1000).addTo(map)
}

const drawPasses = () => {
  if (!map) return
  lastPassLine.setLatLngs(props.passes?.last ? splitAtDateline(props.passes.last.track) : [])
  nextPassLine.setLatLngs(props.passes?.next ? splitAtDateline(props.passes.next.track) : [])
}

const focus = (latitude, longitude, zoom = 4) => map?.setView([latitude, longitude], zoom)

onMounted(() => {
  map = L.map(mapEl.value, { maxBounds: WORLD, maxBoundsViscosity: 1.0 }).setView([0, 0], 3)
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    noWrap: true,
    bounds: WORLD,
    attribution: '&copy; OpenStreetMap contributors'
  }).addTo(map)
  const fitMinZoom = () => map.setMinZoom(map.getBoundsZoom(WORLD, true))
  fitMinZoom()
  map.on('resize', fitMinZoom)
  map.on('click', (e) => emit('select', e.latlng.lat, e.latlng.lng))

  issMarker = L.circleMarker([0, 0], { radius: 8, color: '#ef4444', fillColor: '#ef4444', fillOpacity: 1 }).addTo(map)
  issTrack = L.polyline([], { color: '#ef4444', weight: 2, opacity: 0.7 }).addTo(map)
  userCircle = L.circle([0, 0], { radius: 1, color: '#3b82f6', weight: 1, fillOpacity: 0.08 })
  userMarker = L.circleMarker([0, 0], { radius: 6, color: '#ffffff', weight: 2, fillColor: '#3b82f6', fillOpacity: 1 })
  lastPassLine = L.polyline([], { color: '#64748b', weight: 4, opacity: 0.8 }).addTo(map)
  nextPassLine = L.polyline([], { color: '#f59e0b', weight: 4, opacity: 0.9, dashArray: '8 8' }).addTo(map)

  drawIss()
  drawLocation()
  drawPasses()
})

onBeforeUnmount(() => {
  map?.remove()
  map = null
})

watch(() => props.history, drawIss)
watch(() => props.location, drawLocation)
watch(() => props.passes, drawPasses)
watch(() => props.followIss, (follow) => { if (follow) drawIss() })

defineExpose({ focus })
</script>

<style scoped>
.map-container { overflow: hidden; height: 500px; }
.map { width: 100%; height: 100%; z-index: 1; cursor: crosshair; background: var(--bg-color); }
</style>
