import { PriceChart } from './components/PriceChart.tsx';
import { PriceHero } from './components/PriceHero.tsx';
import { RefreshButton } from './components/RefreshButton.tsx';
import { StaleBanner } from './components/StaleBanner.tsx';
import { Empty, Failure, Loading } from './components/States.tsx';
import { usePrice } from './hooks/use-price.ts';
import { useTheme } from './hooks/use-theme.ts';
import { ThemeToggle } from './components/ThemeToggle.tsx';

export default function App() {
  const { status, latest, points, error, refreshing, refresh, retry } = usePrice();
  const { theme, setTheme } = useTheme();

  return (
    <main className="shell">
      <header className="topline">
        <h1>Bitcoin in US dollars</h1>
        <div className="topline__actions">
          <ThemeToggle theme={theme} onChange={setTheme} />
          {status === 'ready' && <RefreshButton onRefresh={refresh} busy={refreshing} />}
        </div>
      </header>

      {status === 'loading' && <Loading />}
      {status === 'empty' && <Empty onRetry={retry} />}
      {status === 'error' && <Failure message={error ?? 'Unknown error'} onRetry={retry} />}

      {status === 'ready' && latest && (
        <>
          <PriceHero price={latest.price} observedAt={latest.observedAt} />
          {latest.stale && (
            <StaleBanner observedAt={latest.observedAt} reason={latest.staleReason} />
          )}
          {points.length > 0 && <PriceChart points={points} />}
        </>
      )}
    </main>
  );
}
