import { useLocations } from './hooks/useApi';
import { useSession } from './hooks/useSession';
import { MapPane } from './components/MapPane';
import { ChartPane } from './components/ChartPane';

function App() {
  const { data: locations, isLoading, isError } = useLocations();
  const session = useSession(locations);
  const selectedLocationId = session.preferences.locationId;

  if (isLoading || session.isLoading) {
    return <div className="flex h-dvh items-center justify-center font-semibold text-lg">Loading air quality data...</div>;
  }

  if (isError) {
    return <div className="flex h-dvh items-center justify-center font-semibold text-lg text-red-500">Failed to load locations. Please check the backend.</div>;
  }

  return (
    <div className="flex min-h-dvh w-full flex-col bg-background text-foreground lg:h-dvh lg:flex-row lg:overflow-hidden">
      {/* Left Pane: Map */}
      <div className="relative z-10 h-[40dvh] min-h-64 w-full border-b border-border shadow-md lg:h-full lg:w-1/2 lg:border-b-0 lg:border-r">
        <MapPane 
          locations={locations || []} 
          selectedLocationId={selectedLocationId}
          onSelectLocation={locationId => session.update({ locationId })}
        />
      </div>

      {/* Right Pane: Chart / Dashboard */}
      <div className="w-full bg-muted/20 p-4 sm:p-6 lg:h-full lg:w-1/2 lg:overflow-y-auto">
        <div className="mx-auto flex max-w-4xl flex-col lg:h-full">
          <header className="mb-4 sm:mb-6">
            <h1 className="text-2xl font-bold sm:text-3xl tracking-tight text-primary">Kyiv Air Quality</h1>
            <p className="text-muted-foreground mt-1">Real-time and historical air quality dynamics</p>
            {session.unavailable && (
              <p role="status" className="mt-2 text-sm text-amber-700 dark:text-amber-400">
                Your selections cannot currently be saved. You can keep browsing.
              </p>
            )}
          </header>

          <main className="bg-card rounded-xl border border-border shadow-sm p-3 sm:p-6 flex flex-col items-center justify-center min-h-0 lg:flex-1">
            {selectedLocationId ? (
              <ChartPane
                locationId={selectedLocationId}
                selectedParameter={session.preferences.parameter}
                period={session.preferences.period}
                onParameterChange={parameter => session.update({ parameter })}
                onPeriodChange={period => session.update({ period })}
              />
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
