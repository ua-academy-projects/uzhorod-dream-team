type Props = {
  onRefresh: () => void;
  busy: boolean;
};

export function RefreshButton({ onRefresh, busy }: Props) {
  return (
    <button type="button" className="button" onClick={onRefresh} disabled={busy} aria-busy={busy}>
      {busy ? 'Refreshing' : 'Refresh'}
    </button>
  );
}
