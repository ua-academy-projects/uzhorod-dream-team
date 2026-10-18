<template>
  <div class="charts-grid">
    <div v-for="chart in charts" :key="chart.key" class="card chart-container">
      <h3>{{ chart.title }}</h3>
      <div class="chart-wrapper">
        <Line v-if="history.length" :data="chart.data" :options="chartOptions" />
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed } from 'vue'
import { Chart as ChartJS, CategoryScale, LinearScale, PointElement, LineElement, Title, Tooltip, Filler } from 'chart.js'
import { Line } from 'vue-chartjs'
import { formatTime } from '../format'

ChartJS.register(CategoryScale, LinearScale, PointElement, LineElement, Title, Tooltip, Filler)

const props = defineProps({
  history: { type: Array, required: true },
  isDarkMode: { type: Boolean, required: true }
})

const SERIES = [
  { key: 'altitude', title: 'Altitude Trend', color: '#3b82f6', fill: 'rgba(59, 130, 246, 0.1)' },
  { key: 'velocity', title: 'Velocity Trend', color: '#8b5cf6', fill: 'rgba(139, 92, 246, 0.1)' },
  { key: 'footprint', title: 'Footprint Trend', color: '#10b981', fill: 'rgba(16, 185, 129, 0.1)' }
]

const chartOptions = computed(() => ({
  responsive: true,
  maintainAspectRatio: false,
  animation: { duration: 0 },
  scales: {
    x: { display: false },
    y: {
      grid: { color: props.isDarkMode ? '#334155' : '#e2e8f0' },
      ticks: { color: props.isDarkMode ? '#94a3b8' : '#64748b', font: { size: 10 } }
    }
  },
  plugins: { legend: { display: false }, tooltip: { mode: 'index', intersect: false } },
  elements: { point: { radius: 0 } }
}))

const charts = computed(() => {
  const points = [...props.history].reverse()
  const labels = points.map(p => formatTime(p.timestamp))
  return SERIES.map(s => ({
    key: s.key,
    title: s.title,
    data: {
      labels,
      datasets: [{
        borderColor: s.color,
        backgroundColor: s.fill,
        data: points.map(p => p[s.key]),
        fill: true,
        tension: 0.4,
        borderWidth: 2
      }]
    }
  }))
})
</script>

<style scoped>
.charts-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; margin-bottom: 20px; }
.chart-container { padding: 20px; }
.chart-container h3 { font-size: 14px; color: var(--text-muted); margin-bottom: 15px; text-transform: uppercase; }
.chart-wrapper { position: relative; height: 200px; width: 100%; }
</style>
