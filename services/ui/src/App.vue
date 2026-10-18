<template>
  <div class="dashboard">
    <AppHeader
      :online="history.length > 0"
      :satellite-id="latest.id"
      :is-dark-mode="isDarkMode"
      @toggle-theme="toggleTheme"
    />
    <StatsGrid :latest="latest" />
    <TrendCharts :history="history" :is-dark-mode="isDarkMode" />
    <PassPanel
      v-model:followIss="followIss"
      :location="location"
      :passes="passes"
      :radius-km="radiusKm"
      :now-ts="nowTs"
      :can-geolocate="canGeolocate"
      @change-radius="changeRadius"
      @locate="useMyLocation"
    />
    <div class="content-grid">
      <IssMap
        ref="issMap"
        :history="history"
        :location="location"
        :passes="passes"
        :follow-iss="followIss"
        @select="setLocation"
      />
      <HistoryTable :history="history" />
    </div>
  </div>
</template>

<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { getHistory, getPasses, getSettings, saveSettings } from './api'
import { normalizeLongitude, round4 } from './geo'
import AppHeader from './components/AppHeader.vue'
import StatsGrid from './components/StatsGrid.vue'
import TrendCharts from './components/TrendCharts.vue'
import PassPanel from './components/PassPanel.vue'
import IssMap from './components/IssMap.vue'
import HistoryTable from './components/HistoryTable.vue'

const HISTORY_REFRESH_MS = 15000
const PASSES_REFRESH_MS = 60000

const history = ref([])
const isDarkMode = ref(false)
const location = ref(null)
const passes = ref(null)
const radiusKm = ref(1000)
const followIss = ref(true)
const nowTs = ref(Date.now() / 1000)
const issMap = ref(null)
const canGeolocate = window.isSecureContext && 'geolocation' in navigator
const timers = []

const latest = computed(() => history.value[0] || {})

const fetchHistory = async () => {
  try {
    history.value = await getHistory()
  } catch (e) {
    console.error('Failed to fetch history:', e)
  }
}

const fetchPasses = async () => {
  if (!location.value) return
  try {
    passes.value = await getPasses(location.value)
  } catch (e) {
    console.error('Failed to fetch passes:', e)
  }
}

const loadSettings = async () => {
  try {
    const settings = await getSettings()
    isDarkMode.value = settings.theme === 'dark'
    if (settings.location) {
      location.value = settings.location
      radiusKm.value = settings.location.radius_km
    }
  } catch (e) {
    console.error('Failed to load settings:', e)
  }
}

const persist = async (settings) => {
  try {
    await saveSettings(settings)
  } catch (e) {
    console.error('Failed to save settings:', e)
  }
}

const setLocation = (latitude, longitude) => {
  location.value = {
    latitude: round4(latitude),
    longitude: round4(normalizeLongitude(longitude)),
    radius_km: radiusKm.value
  }
  passes.value = null
  followIss.value = false
  persist({ location: location.value })
  fetchPasses()
}

const changeRadius = (radius) => {
  radiusKm.value = radius
  if (location.value) setLocation(location.value.latitude, location.value.longitude)
}

const useMyLocation = () => {
  navigator.geolocation.getCurrentPosition(
    ({ coords }) => {
      setLocation(coords.latitude, coords.longitude)
      issMap.value?.focus(coords.latitude, coords.longitude)
    },
    (e) => console.error('Geolocation failed:', e)
  )
}

const toggleTheme = () => {
  isDarkMode.value = !isDarkMode.value
  persist({ theme: isDarkMode.value ? 'dark' : 'light' })
}

watch(isDarkMode, (dark) => {
  document.body.className = dark ? 'dark-theme' : 'light-theme'
}, { immediate: true })

onMounted(async () => {
  await loadSettings()
  fetchHistory()
  fetchPasses()
  timers.push(
    setInterval(fetchHistory, HISTORY_REFRESH_MS),
    setInterval(fetchPasses, PASSES_REFRESH_MS),
    setInterval(() => { nowTs.value = Date.now() / 1000 }, 1000)
  )
})

onBeforeUnmount(() => timers.forEach(clearInterval))
</script>

<style scoped>
.dashboard { max-width: 1200px; margin: 0 auto; padding: 20px; }
.content-grid { display: grid; grid-template-columns: 1fr; gap: 20px; }
@media (min-width: 900px) { .content-grid { grid-template-columns: 1fr 1fr; } }
</style>
