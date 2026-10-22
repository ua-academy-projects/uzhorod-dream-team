import { useEffect, useRef, useState } from 'react'
import {
  createChart,
  CandlestickSeries,
  type CandlestickData,
  type Time,
} from 'lightweight-charts'
import { Calendar } from './components/ui/calendar'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from './components/ui/dialog'
import { CalendarDays, ChevronDown } from 'lucide-react'
import { api } from './services/api'
import './App.css'
import { ThemeToggle } from './components/themeToggle'
import { useSettingsContext } from './store/settings.context'

const formatDate = (date: Date) => {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')

  return `${year}-${month}-${day}`
}

const toChartTime = (openTime: string): Time => {
  return Math.floor(new Date(openTime).getTime() / 1000) as Time
}

const toChartBar = (bar: any): CandlestickData => ({
  time: toChartTime(bar.openTime),
  open: bar.open,
  high: bar.high,
  low: bar.low,
  close: bar.close,
})

function App() {  
  const [date, setDate] = useState<Date>(new Date())
  const [secondsToUpdate, setSecondsToUpdate] = useState<number | null>(null)
  const { isDarkTheme } = useSettingsContext()

  const chartContainerRef = useRef<HTMLDivElement>(null)
  const chartRef = useRef<any>(null)
  const seriesRef = useRef<any>(null)

  const dataRef = useRef<CandlestickData[]>([])

  useEffect(() => {
    if (!chartContainerRef.current) return

    const chart = createChart(chartContainerRef.current, {
      width: chartContainerRef.current.clientWidth,
      height: 500,

      layout: {
        background: { color: '#ffffff' },
        textColor: '#777783',
        attributionLogo: false,
      },

      grid: {
        vertLines: { color: '#eeeef2' },
        horzLines: { color: '#eeeef2' },
      },

      rightPriceScale: {
        borderColor: '#e3e3e8',
      },

      timeScale: {
        borderColor: '#e3e3e8',
        timeVisible: true,
        secondsVisible: false,

        tickMarkFormatter: (time: any) => {
          const date = new Date(Number(time) * 1000)

          return new Intl.DateTimeFormat('uk-UA', {
            timeZone: 'Europe/Kyiv',
            hour: '2-digit',
            minute: '2-digit',
          }).format(date)
        },
      },

      localization: {
        timeFormatter: (time: any) => {
          const date = new Date(Number(time) * 1000)
          return new Intl.DateTimeFormat('uk-UA', {
            timeZone: 'Europe/Kyiv',
            hour: '2-digit',
            minute: '2-digit',
          }).format(date)
        },
      }
    })
    chartRef.current = chart

    const series = chart.addSeries(CandlestickSeries, {
      upColor: '#6d4aff',
      downColor: '#ff4d6d',
      borderVisible: false,
      wickUpColor: '#6d4aff',
      wickDownColor: '#ff4d6d',
    })

    seriesRef.current = series
    dataRef.current = []

    const loadHistory = async () => {
      try {
        const bars = await api.getHistory(
          'ETHUSD',
          formatDate(date)
        )

        console.log(
          'HISTORY LAST:',
          bars[bars.length - 1]?.openTime
        )

        const data: CandlestickData[] = bars.map(toChartBar)

        dataRef.current = data
        series.setData(data)

        chart.timeScale().scrollToRealTime()
      } catch (error) {
        console.error('Failed to load history:', error)
      }
    }

    loadHistory()

    const handleResize = () => {
      if (!chartContainerRef.current) return

      chart.applyOptions({
        width: chartContainerRef.current.clientWidth,
      })
    }

    window.addEventListener('resize', handleResize)

    return () => {
      window.removeEventListener('resize', handleResize)
      chart.remove()
      chartRef.current = null
      seriesRef.current = null
      dataRef.current = []
    }
  }, [date])

  useEffect(() => {
    const chart = chartRef.current
    const series = seriesRef.current
    if (!chart || !series) return

    const palette = isDarkTheme
      ? {
          background: '#17171e',
          text: '#a5a5b3',
          grid: '#2b2b35',
          border: '#353540',
          up: '#8b72ff',
          down: '#ff617c',
        }
      : {
          background: '#ffffff',
          text: '#777783',
          grid: '#eeeef2',
          border: '#e3e3e8',
          up: '#6d4aff',
          down: '#ff4d6d',
        }

    chart.applyOptions({
      layout: {
        background: { color: palette.background },
        textColor: palette.text,
      },
      grid: {
        vertLines: { color: palette.grid },
        horzLines: { color: palette.grid },
      },
      rightPriceScale: {
        borderColor: palette.border,
      },
      timeScale: {
        borderColor: palette.border,
      },
    })
    series.applyOptions({
      upColor: palette.up,
      downColor: palette.down,
      wickUpColor: palette.up,
      wickDownColor: palette.down,
    })
  }, [isDarkTheme])

  useEffect(() => {
    const now = new Date()

    const isToday =
      date.getFullYear() === now.getFullYear() &&
      date.getMonth() === now.getMonth() &&
      date.getDate() === now.getDate()

    if (!isToday) {
      setSecondsToUpdate(null)
      return
    }

    let timeout: ReturnType<typeof setTimeout>
    let countdown: ReturnType<typeof setInterval>

    const schedule = () => {
      const now = new Date()

      const nextMinute = new Date(now)
      nextMinute.setSeconds(0, 0)
      nextMinute.setMinutes(nextMinute.getMinutes() + 1)

      const target = new Date(nextMinute.getTime() + 10_000)

      const updateCountdown = () => {
        const remaining = Math.max(
          1,
          Math.ceil(
            (target.getTime() - Date.now()) / 1000
          )
        )

        setSecondsToUpdate(remaining)
      }

      updateCountdown()

      countdown = setInterval(updateCountdown, 250)

      timeout = setTimeout(async () => {
        clearInterval(countdown)

        try {
          const bars = await api.getCurrent('ETHUSD')

          if (bars.length === 0) {
            throw new Error('Current bar response is empty')
          }

          console.log(
            'CURRENT:',
            bars.map((bar) => bar.openTime)
          )

          const previous = bars.at(-2)
          const current = bars.at(-1)

          /*
           * getCurrent() returns the last two bars.
           *
           * We cannot call series.update(previous), because
           * previous is usually not the last bar in the chart.
           *
           * Instead, synchronize the last two bars inside our
           * local data and set the complete data back.
           */

          const currentData = [...dataRef.current]

          if (previous) {
            const previousTime = toChartTime(previous.openTime)

            const previousIndex = currentData.findIndex(
              (bar) => bar.time === previousTime
            )

            const previousBar = toChartBar(previous)

            if (previousIndex >= 0) {
              currentData[previousIndex] = previousBar
            } else {
              currentData.push(previousBar)
            }
          }

          if (current) {
            const currentTime = toChartTime(current.openTime)

            const currentIndex = currentData.findIndex(
              (bar) => bar.time === currentTime
            )

            const currentBar = toChartBar(current)

            if (currentIndex >= 0) {
              currentData[currentIndex] = currentBar
            } else {
              currentData.push(currentBar)
            }
          }

          currentData.sort((a, b) => {
            return Number(a.time) - Number(b.time)
          })

          dataRef.current = currentData

          seriesRef.current?.setData(currentData)
        } catch (error) {
          console.error(
            'Failed to load current bar:',
            error
          )
        }

        schedule()
      }, target.getTime() - Date.now())
    }

    schedule()

    return () => {
      clearTimeout(timeout)
      clearInterval(countdown)
    }
  }, [date])

  return (
    <div className="app">
      <header className="header">
        <div className="symbol">
          <div className="symbol-icon">
            <img src="/logo.png" alt="eth_logo" />
          </div>

          <div className="symbol-info">
            <div className="symbol-name">ETHUSD</div>
            <div className="symbol-description">
              Ethereum / US Dollar
            </div>
          </div>
        </div>

        <div className="header-end">
          <ThemeToggle />

          <Dialog>
            <DialogTrigger className="date-button">
              <CalendarDays size={17} strokeWidth={2} />

              <span>
                {date.toLocaleDateString('en-GB', {
                  day: '2-digit',
                  month: 'short',
                  year: 'numeric',
                })}
              </span>

              <ChevronDown size={15} strokeWidth={2} />
            </DialogTrigger>

            <DialogContent className="date-dialog">
              <DialogHeader>
                <DialogTitle>Select date</DialogTitle>
              </DialogHeader>
              <Calendar
                mode="single"
                selected={date}
                onSelect={(selectedDate) => {
                  if (selectedDate) {
                    setDate(selectedDate)
                  }
                }}
                disabled={[
                  {
                    before: new Date(2026, 9, 1),
                  },
                  {
                    after: new Date(2026, 9, 16),
                    before: new Date(2026, 9, 19),
                  },
                  {
                    after: new Date(),
                  },
                ]}
              />
            </DialogContent>
          </Dialog>
        </div>
      </header>

      <main className="content">
        <div className="chart-card">
          <div className="chart-header">
            <span>ETHUSD</span>

            <span className="live">
              ● Live

              {secondsToUpdate !== null && (
                <span className="update-timer">
                  · Update in {secondsToUpdate}s
                </span>
              )}
            </span>
          </div>

          <div
            ref={chartContainerRef}
            className="chart"
          />
        </div>
      </main>
    </div>
  )
}

export default App