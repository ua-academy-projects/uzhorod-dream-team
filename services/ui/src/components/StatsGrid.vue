<template>
  <div class="stats-grid">
    <div class="card stat-card">
      <h3>Position</h3>
      <p>{{ fixed(latest.latitude, 4) }}°, {{ fixed(latest.longitude, 4) }}°</p>
    </div>
    <div class="card stat-card">
      <h3>Altitude & Velocity</h3>
      <p>{{ fixed(latest.altitude, 1) }} {{ units }}, {{ fixed(latest.velocity, 0) }} {{ units }}/h</p>
    </div>
    <div class="card stat-card">
      <h3>Visibility & Daynum</h3>
      <p class="capitalize">{{ latest.visibility || 'N/A' }} <span class="sub-text">(#{{ fixed(latest.daynum, 1) }})</span></p>
    </div>
    <div class="card stat-card">
      <h3>Solar Position</h3>
      <p>Lat: {{ fixed(latest.solar_lat, 2) }}°, Lon: {{ fixed(latest.solar_lon, 2) }}°</p>
    </div>
  </div>
</template>

<script setup>
import { computed } from 'vue'
import { fixed } from '../format'

const props = defineProps({
  latest: { type: Object, required: true }
})

const units = computed(() => props.latest.units || 'km')
</script>

<style scoped>
.stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px; margin-bottom: 20px; }
.stat-card { padding: 20px; text-align: center; }
.stat-card h3 { font-size: 12px; color: var(--text-muted); margin-bottom: 8px; text-transform: uppercase; }
.stat-card p { font-size: 18px; font-weight: bold; }
</style>
