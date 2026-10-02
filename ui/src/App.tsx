import { useState } from 'react';
import { useLocations } from './hooks/useApi';
import { MapPane } from './components/MapPane';
import { ChartPane } from './components/ChartPane';

function App() {
  const { data: locations, isLoading, isError } = useLocations();
  const [selectedLocationId, setSelectedLocationId] = useState<number | null>(null);

  if (isLoading) {
    return <div className="flex h-screen items-center justify-center font-semibold text-lg">Loading air quality data...</div>;
  }

  if (isError) {
    return <div className="flex h-screen items-center justify-center font-semibold text-lg text-red-500">Failed to load locations. Please check the backend.</div>;
  }

  return (
    <div className="flex h-screen w-full overflow-hidden bg-background text-foreground">
      {/* Left Pane: Map */}
      <div className="w-1/2 h-full border-r border-border shadow-md z-10 relative">
        <MapPane 
          locations={locations || []} 
          selectedLocationId={selectedLocationId}
          onSelectLocation={setSelectedLocationId}
        />
      </div>

      {/* Right Pane: Chart / Dashboard */}
      <div className="w-1/2 h-full bg-muted/20 p-6 overflow-y-auto">
        <div className="max-w-4xl mx-auto h-full flex flex-col">
          <header className="mb-6">
            <h1 className="text-3xl font-bold tracking-tight text-primary">Kyiv Air Quality</h1>
            <p className="text-muted-foreground mt-1">Real-time and historical air quality dynamics</p>
          </header>

          <main className="flex-1 bg-card rounded-xl border border-border shadow-sm p-6 flex flex-col items-center justify-center min-h-0">
            {selectedLocationId ? (
              <ChartPane locationId={selectedLocationId} />
            ) : (
              <div className="text-center text-muted-foreground flex flex-col items-center">
                <svg xmlns="http://www.w3.org/2000/svg" className="h-12 w-12 mb-4 text-muted-foreground/50" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z" />
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 11a3 3 0 11-6 0 3 3 0 016 0z" />
                </svg>
                <p className="text-lg font-medium text-foreground">No Location Selected</p>
                <p className="max-w-xs mt-2">Select a monitoring station on the map to view historical air quality metrics.</p>
              </div>
            )}
          </main>
        </div>
      </div>
    </div>
  );
}

export default App;
