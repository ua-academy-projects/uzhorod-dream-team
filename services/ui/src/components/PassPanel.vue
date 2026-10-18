<template>
  <div class="card pass-container">
    <div class="pass-header">
      <h3>Passes over your location</h3>
      <div class="pass-controls">
        <label>
          Radius
          <select :value="radiusKm" @change="emit('change-radius', Number($event.target.value))">
            <option v-for="r in RADIUS_OPTIONS" :key="r" :value="r">{{ r }} km</option>
          </select>
        </label>
        <button v-if="canGeolocate" class="pill-button" @click="emit('locate')">📍 My location</button>
        <button class="pill-button" @click="emit('update:followIss', !followIss)">
          {{ followIss ? '🛰️ Following ISS' : '🛰️ Follow ISS' }}
        </button>
      </div>
    </div>

    <p v-if="!location" class="pass-hint">Click on the map to set your location.</p>
    <template v-else>
      <p class="pass-hint">
        Your point: {{ location.latitude.toFixed(3) }}°, {{ location.longitude.toFixed(3) }}° · within {{ location.radius_km }} km
        <span v-if="passes?.overhead_now" class="overhead-badge">ISS is over your area now</span>
      </p>
      <div class="pass-grid">
        <div class="pass-card">
          <h4>Last pass <span class="sub-text">recorded</span></h4>
          <template v-if="passes?.last">
            <p class="pass-time">{{ formatDateTime(passes.last.closest) }}</p>
            <p class="countdown">{{ formatSpan(nowTs - passes.last.closest) }} ago</p>
            <p class="sub-text">
              {{ passes.last.min_distance_km.toFixed(0) }} km away · max elevation {{ passes.last.max_elevation_deg.toFixed(0) }}° ·
              <template v-if="passes.last.end > passes.last.start">{{ formatSpan(passes.last.end - passes.last.start) }} in range · </template>
              <span class="capitalize">{{ passes.last.visibility }}</span>
            </p>
          </template>
          <p v-else-if="passes" class="sub-text">No recorded passes within {{ location.radius_km }} km yet.</p>
          <p v-else class="sub-text">Loading…</p>
        </div>
        <div class="pass-card">
          <h4>Next pass <span class="sub-text">predicted</span></h4>
          <template v-if="passes?.next">
            <p class="pass-time">≈ {{ formatDateTime(passes.next.start) }}</p>
            <p class="countdown">{{ passes.next.start > nowTs ? `in ${formatSpan(passes.next.start - nowTs)}` : 'now' }}</p>
            <p class="sub-text">
              closest {{ passes.next.min_distance_km.toFixed(0) }} km at {{ formatTime(passes.next.closest) }} ·
              max elevation {{ passes.next.max_elevation_deg.toFixed(0) }}° · {{ formatSpan(passes.next.end - passes.next.start) }} in range
            </p>
          </template>
          <p v-else-if="passes?.model_error" class="sub-text">{{ passes.model_error }}</p>
          <p v-else-if="passes" class="sub-text">No pass within {{ location.radius_km }} km in the next 48 h.</p>
          <p v-else class="sub-text">Loading…</p>
        </div>
      </div>
      <p v-if="passes?.model" class="model-info">
        Orbit model fitted on {{ passes.model.points }} recorded positions over {{ passes.model.span_hours.toFixed(1) }} h ·
        period {{ passes.model.period_minutes.toFixed(2) }} min · inclination {{ passes.model.inclination_deg.toFixed(2) }}°
      </p>
    </template>
  </div>
</template>

<script setup>
import { formatDateTime, formatSpan, formatTime } from '../format'

const RADIUS_OPTIONS = [500, 1000, 1500, 2000]

defineProps({
  location: { type: Object, default: null },
  passes: { type: Object, default: null },
  radiusKm: { type: Number, required: true },
  followIss: { type: Boolean, required: true },
  nowTs: { type: Number, required: true },
  canGeolocate: { type: Boolean, default: false }
})

const emit = defineEmits(['change-radius', 'locate', 'update:followIss'])
</script>

<style scoped>
.pass-container { padding: 20px; margin-bottom: 20px; }
.pass-header { display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 12px; margin-bottom: 12px; }
.pass-header h3 { font-size: 14px; color: var(--text-muted); text-transform: uppercase; }
.pass-controls { display: flex; align-items: center; flex-wrap: wrap; gap: 10px; font-size: 14px; color: var(--text-muted); }
.pass-controls select { margin-left: 6px; padding: 6px 8px; border-radius: 6px; border: 1px solid var(--border-color); background: var(--row-hover); color: var(--text-main); }
.pass-hint { font-size: 14px; color: var(--text-muted); margin-bottom: 12px; display: flex; align-items: center; flex-wrap: wrap; gap: 10px; }
.overhead-badge { background: #f59e0b; color: #1e293b; font-weight: 600; padding: 2px 10px; border-radius: 12px; animation: pulse 1.5s ease-in-out infinite; }
@keyframes pulse { 50% { opacity: 0.6; } }
.pass-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 20px; }
.pass-card { background: var(--row-hover); border: 1px solid var(--border-color); border-radius: 8px; padding: 16px; }
.pass-card h4 { font-size: 12px; color: var(--text-muted); text-transform: uppercase; margin-bottom: 8px; }
.pass-time { font-size: 20px; font-weight: bold; }
.countdown { font-size: 16px; font-weight: 600; color: #f59e0b; margin: 4px 0 8px; }
.model-info { font-size: 12px; color: var(--text-muted); margin-top: 12px; }
</style>
