<template>
  <div class="card table-container">
    <table>
      <thead>
        <tr>
          <th>Time</th>
          <th>Lat/Lng</th>
          <th>Alt/Vel</th>
          <th>Visibility</th>
          <th>Footprint</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="item in history" :key="item.timestamp">
          <td>{{ formatTime(item.timestamp) }}</td>
          <td>{{ item.latitude.toFixed(2) }}, {{ item.longitude.toFixed(2) }}</td>
          <td>{{ item.altitude.toFixed(1) }} / {{ item.velocity.toFixed(0) }}</td>
          <td class="capitalize">{{ item.visibility }}</td>
          <td>{{ item.footprint.toFixed(1) }}</td>
        </tr>
      </tbody>
    </table>
  </div>
</template>

<script setup>
import { formatTime } from '../format'

defineProps({
  history: { type: Array, required: true }
})
</script>

<style scoped>
.table-container { height: 500px; overflow-y: auto; }
.table-container::-webkit-scrollbar { width: 8px; }
.table-container::-webkit-scrollbar-track { background: var(--bg-color); }
.table-container::-webkit-scrollbar-thumb { background: var(--border-color); border-radius: 4px; }
table { width: 100%; border-collapse: collapse; }
th, td { padding: 12px; text-align: left; border-bottom: 1px solid var(--border-color); font-size: 14px; }
th { background: var(--table-header); position: sticky; top: 0; font-weight: 600; text-transform: uppercase; font-size: 12px; color: var(--text-muted); z-index: 2; }
tr:hover { background: var(--row-hover); }
</style>
