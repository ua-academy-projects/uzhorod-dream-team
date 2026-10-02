import { useState, useEffect, useMemo } from 'react';
import { useLocationParameters, useLocationHistory } from '../hooks/useApi';
import { Button } from './ui/button';
import { Calendar } from './ui/calendar';
import { Popover, PopoverContent, PopoverTrigger } from './ui/popover';
import { format, subDays } from 'date-fns';
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

interface ChartPaneProps {
  locationId: number;
}

export function ChartPane({ locationId }: ChartPaneProps) {
  const { data: parameters, isLoading: isParamsLoading } = useLocationParameters(locationId);
  const [selectedParameter, setSelectedParameter] = useState<string | null>(null);
  const [isParamOpen, setIsParamOpen] = useState(false);

  // Set default parameter when they load
  useEffect(() => {
    if (parameters && parameters.length > 0 && (!selectedParameter || !parameters.find(p => p.name === selectedParameter))) {
      setSelectedParameter(parameters[0].name);
    }
  }, [parameters, selectedParameter]);

  // Date Range State
  const [dateRange, setDateRange] = useState<{ from: Date; to: Date }>({
    from: subDays(new Date(), 7),
    to: new Date()
  });

  const setQuickRange = (days: number) => {
    setDateRange({ from: subDays(new Date(), days), to: new Date() });
  };

  const { data: history, isLoading: isHistoryLoading } = useLocationHistory(
    locationId,
    selectedParameter,
    dateRange.from.toISOString(),
    dateRange.to.toISOString()
  );

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

  const activeUnit = parameters?.find(p => p.name === selectedParameter)?.unit || '';

  if (isParamsLoading) {
    return <div className="flex h-full items-center justify-center">Loading parameters...</div>;
  }

  if (!parameters || parameters.length === 0) {
    return <div className="flex h-full items-center justify-center">No parameters found for this location.</div>;
  }

  return (
    <div className="flex flex-col h-full w-full">
      <div className="mb-6 flex flex-col xl:flex-row justify-between items-start xl:items-center gap-4">
        {/* Parameters Dropdown (Custom Popover) */}
        <div className="w-full xl:w-56">
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
                    className="justify-start font-normal px-2 py-1.5 h-auto text-sm"
                    onClick={() => {
                      setSelectedParameter(p.name);
                      setIsParamOpen(false);
                    }}
                  >
                    {p.name}
                  </Button>
                ))}
              </div>
            </PopoverContent>
          </Popover>
        </div>

        {/* Date Controls */}
        <div className="flex flex-wrap items-center gap-2">
          <Button variant="outline" size="sm" onClick={() => setQuickRange(1)}>24h</Button>
          <Button variant="outline" size="sm" onClick={() => setQuickRange(7)}>7d</Button>
          <Button variant="outline" size="sm" onClick={() => setQuickRange(30)}>30d</Button>
          
          <Popover>
            <PopoverTrigger render={<Button variant="outline" size="sm" className={cn("justify-start text-left font-normal", !dateRange && "text-muted-foreground")} />}>
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
            <PopoverContent className="w-auto p-0 bg-popover border border-border shadow-md" align="end">
              <Calendar
                mode="range"
                defaultMonth={dateRange?.from}
                selected={{ from: dateRange.from, to: dateRange.to }}
                onSelect={(range) => {
                  if (range?.from) {
                    setDateRange({ from: range.from, to: range.to || new Date() });
                  }
                }}
                numberOfMonths={2}
              />
            </PopoverContent>
          </Popover>
        </div>
      </div>

      {/* Chart Area */}
      <div className="flex-1 min-h-[400px] w-full bg-white dark:bg-zinc-950 p-4 rounded-lg border border-border flex items-center justify-center">
        {isHistoryLoading ? (
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
