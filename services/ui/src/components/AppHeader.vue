<template>
  <header class="card">
    <div>
      <h1>ISS Telemetry Tracker</h1>
      <div class="status-indicator">
        <span :class="online ? 'online' : 'offline'"></span>
        {{ online ? `Live Data (Sat ID: ${satelliteId || 'N/A'})` : 'Waiting for data...' }}
      </div>
    </div>
    <button class="pill-button" @click="emit('toggle-theme')">
      {{ isDarkMode ? '☀️ Light Mode' : '🌙 Dark Mode' }}
    </button>
  </header>
</template>

<script setup>
defineProps({
  online: { type: Boolean, required: true },
  satelliteId: { type: [Number, String], default: null },
  isDarkMode: { type: Boolean, required: true }
})

const emit = defineEmits(['toggle-theme'])
</script>

<style scoped>
header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; padding: 20px; }
.status-indicator { display: flex; align-items: center; gap: 8px; font-size: 14px; margin-top: 8px; color: var(--text-muted); }
.online, .offline { width: 10px; height: 10px; border-radius: 50%; }
.online { background: #22c55e; box-shadow: 0 0 8px #22c55e; }
.offline { background: #ef4444; box-shadow: 0 0 8px #ef4444; }
</style>
