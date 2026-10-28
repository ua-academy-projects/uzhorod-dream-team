type FailureProps = {
  message: string;
  onRetry: () => void;
};

export function Loading() {
  return (
    <div className="state" role="status">
      <h2>Loading the price</h2>
      <p>Reading stored history and checking how fresh the latest price is.</p>
    </div>
  );
}

export function Empty({ message, onRetry }: FailureProps) {
  return (
    <div className="state" role="status">
      <h2>No data yet</h2>
      <p>{message}</p>
      <button type="button" className="button" onClick={onRetry}>
        Try again
      </button>
    </div>
  );
}

export function Failure({ message, onRetry }: FailureProps) {
  return (
    <div className="state" role="alert">
      <h2>Could not load the price</h2>
      <p>{message}</p>
      <button type="button" className="button" onClick={onRetry}>
        Try again
      </button>
    </div>
  );
}
