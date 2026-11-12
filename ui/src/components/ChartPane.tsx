import { useState, useMemo, useSyncExternalStore } from 'react';
import { useLocationParameters, useLocationHistory } from '../hooks/useApi';
import { Button } from './ui/button';
import { Calendar } from './ui/calendar';
import { Popover, PopoverContent, PopoverTrigger } from './ui/popover';
import { format } from 'date-fns';
import { Calendar as CalendarIcon, ChevronDownIcon } from 'lucide-react';
import { Line } from 'react-chartjs-2';
import {
  Chart as ChartJS,
  CategoryScale,
  LinearScale,
  PointElement,
  LineElement,
  Title,
  Tooltip,
  Legend
} from 'chart.js';

// Register Chart.js components
ChartJS.register(
  CategoryScale,
  LinearScale,
  PointElement,
  LineElement,
  Title,
  Tooltip,
  Legend
);

import { cn } from "@/lib/utils";
import type { ObservationPeriod } from '../types/api';
import { observationRange } from '../lib/observationPeriod';

const OBSERVATION_PERIODS = [
  { days: 1, label: '24h' },
  { days: 7, label: '7d' },
  { days: 30, label: '30d' },
] as const;

function getParameterColor(param: string): string {
  if (!param) return 'rgb(170, 59, 255)';
  const colors: Record<string, string> = {
    'pm25': 'rgb(239, 68, 68)',
    'pm10': 'rgb(59, 130, 246)',
    'temperature': 'rgb(249, 115, 22)',
    'humidity': 'rgb(14, 165, 233)',
    'pressure': 'rgb(139, 92, 246)',
    'no2': 'rgb(234, 179, 8)',
    'so2': 'rgb(20, 184, 166)',
    'o3': 'rgb(168, 85, 247)',
    'co': 'rgb(100, 116, 139)',
  };
  const key = param.toLowerCase();
  if (colors[key]) return colors[key];

  let hash = 0;
  for (let i = 0; i < param.length; i++) {
    hash = param.charCodeAt(i) + ((hash << 5) - hash);
  }
  const c = (hash & 0x00FFFFFF).toString(16).toUpperCase();
  return '#' + '00000'.substring(0, 6 - c.length) + c;
}

const WIDE_QUERY = '(min-width: 640px)';

function useIsWide() {
  return useSyncExternalStore(
    notify => {
      const mq = window.matchMedia(WIDE_QUERY);
      mq.addEventListener('change', notify);
      return () => mq.removeEventListener('change', notify);
    },
    () => window.matchMedia(WIDE_QUERY).matches,
    () => true
  );
}

interface ChartPaneProps {
  locationId: number;
  selectedParameter: string | null;
  period: ObservationPeriod;
  onParameterChange: (parameter: string) => void;
  onPeriodChange: (period: ObservationPeriod) => void;
}

export function ChartPane({ locationId, selectedParameter, period, onParameterChange, onPeriodChange }: ChartPaneProps) {
  const isWide = useIsWide();
  const [isParamOpen, setIsParamOpen] = useState(false);
  const [periodAnchor, setPeriodAnchor] = useState(() => new Date());

  const selectedPeriod = period.kind === 'preset' ? period.days : null;
  const dateRange = useMemo(() => observationRange(period, periodAnchor), [period, periodAnchor]);
  const from = dateRange.from.toISOString();
  const to = dateRange.to.toISOString();

  const { data: parameters, isLoading: isParamsLoading } = useLocationParameters(locationId, from, to);
  const activeParameter = parameters?.find(parameter => parameter.name === selectedParameter);
  const validParameter = activeParameter?.has_data ? activeParameter.name : null;

  const { data: history, isLoading: isHistoryLoading } = useLocationHistory(locationId, validParameter, from, to);

  const chartData = useMemo(() => {
    if (!history) return null;
    const color = getParameterColor(selectedParameter || '');
    return {
      labels: history.map((d) => new Date(d.timestamp).toLocaleString(undefined, { 
        month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' 
      })),
      datasets: [
        {
          label: selectedParameter || 'Value',
          data: history.map((d) => d.value),
          borderColor: color,
          backgroundColor: color.replace(')', ', 0.5)').replace('rgb', 'rgba'),
          tension: 0.1,
          pointRadius: 2,
        }
      ]
    };
  }, [history, selectedParameter]);

  const activeUnit = activeParameter?.unit || '';

  if (isParamsLoading) {
    return <div className="flex h-full items-center justify-center">Loading parameters...</div>;
  }

  if (!parameters || parameters.length === 0) {
    return <div className="flex h-full items-center justify-center">No parameters found for this location.</div>;
  }

  return (
    <div className="flex w-full flex-col lg:h-full">
      <div className="mb-4 flex flex-col items-start justify-between gap-3 sm:mb-6 sm:flex-row sm:items-center sm:gap-4 lg:flex-col lg:items-start xl:flex-row xl:items-center">
        {/* Parameters Dropdown (Custom Popover) */}
        <div className="w-full sm:w-56">
          <Popover open={isParamOpen} onOpenChange={setIsParamOpen}>
            <PopoverTrigger render={<Button variant="outline" className="w-full justify-between bg-card hover:bg-accent/50 transition-colors" />}>
              <span className="truncate">{selectedParameter || "Select parameter..."}</span>
              <ChevronDownIcon className="ml-2 h-4 w-4 shrink-0 opacity-50" />
            </PopoverTrigger>
            <PopoverContent className="w-56 p-1 bg-popover border border-border rounded-lg shadow-md" align="start">
              <div className="flex flex-col max-h-[300px] overflow-y-auto">
                {parameters.map((p) => (
                  <Button
                    key={p.name}
                    variant={p.name === selectedParameter ? "secondary" : "ghost"}
                    className="justify-between font-normal px-2 py-1.5 h-auto text-sm"
                    disabled={!p.has_data}
                    onClick={() => {
                      onParameterChange(p.name);
                      setIsParamOpen(false);
                    }}
                  >
                    {p.name}
                    {!p.has_data && <span className="text-xs text-muted-foreground">no data</span>}
                  </Button>
                ))}
              </div>
            </PopoverContent>
          </Popover>
        </div>

        {/* Date Controls */}
        <div className="flex flex-wrap items-center gap-2 max-sm:w-full">
          {OBSERVATION_PERIODS.map(({ days, label }) => (
            <Button
              key={days}
              variant={selectedPeriod === days ? 'default' : 'outline'}
              size="sm"
              className="max-sm:h-9 max-sm:flex-1"
              aria-pressed={selectedPeriod === days}
              onClick={() => {
                setPeriodAnchor(new Date());
                onPeriodChange({ kind: 'preset', days });
              }}
            >
              {label}
            </Button>
          ))}
          
          <Popover>
            <PopoverTrigger render={<Button variant={selectedPeriod === null ? 'default' : 'outline'} size="sm" className={cn("justify-start text-left font-normal max-sm:h-9 max-sm:w-full", !dateRange && "text-muted-foreground")} />}>
              <CalendarIcon className="mr-2 h-4 w-4" />
              {dateRange?.from ? (
                dateRange.to ? (
                  <>
                    {format(dateRange.from, "LLL dd, y")} -{" "}
                    {format(dateRange.to, "LLL dd, y")}
                  </>
                ) : (
                  format(dateRange.from, "LLL dd, y")
                )
              ) : (
                <span>Pick a date</span>
              )}
            </PopoverTrigger>
            <PopoverContent className="w-auto max-w-[calc(100vw-1rem)] p-0 bg-popover border border-border shadow-md" align="end">
              <Calendar
                mode="range"
                defaultMonth={dateRange?.from}
                selected={{ from: dateRange.from, to: dateRange.to }}
                onSelect={(range) => {
                  if (range?.from) {
                    onPeriodChange({ kind: 'custom', from: range.from.toISOString(), to: (range.to || range.from).toISOString() });
                  }
                }}
                numberOfMonths={isWide ? 2 : 1}
              />
            </PopoverContent>
          </Popover>
        </div>
      </div>

      {/* Chart Area */}
      <div className="h-80 w-full bg-white p-2 sm:h-96 sm:p-4 lg:h-auto lg:min-h-[400px] lg:flex-1 dark:bg-zinc-950 rounded-lg border border-border flex items-center justify-center">
        {!selectedParameter ? (
          <div className="text-muted-foreground">Select a parameter to see its history.</div>
        ) : activeParameter && !activeParameter.has_data ? (
          <div className="text-center text-muted-foreground">
            No {selectedParameter} data for this period. Pick another period or parameter.
          </div>
        ) : isHistoryLoading ? (
          <div className="animate-pulse text-muted-foreground">Loading chart data...</div>
        ) : !chartData || chartData.datasets[0].data.length === 0 ? (
          <div className="text-muted-foreground">No data available for the selected range.</div>
        ) : (
          <Line
            data={chartData}
            options={{
              responsive: true,
              maintainAspectRatio: false,
              plugins: {
                legend: {
                  position: 'top' as const,
                },
                tooltip: {
                  mode: 'index',
                  intersect: false,
                },
              },
              scales: {
                y: {
                  title: {
                    display: true,
                    text: activeUnit,
                  },
                  beginAtZero: true,
                },
              },
            }}
          />
        )}
      </div>
    </div>
  );
}
