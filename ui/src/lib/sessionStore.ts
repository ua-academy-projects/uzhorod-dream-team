import type { SessionPreferences } from '../types/api';

interface SessionAPI {
  getSession(): Promise<SessionPreferences>;
  saveSession(preferences: SessionPreferences): Promise<SessionPreferences>;
}

export function defaultPreferences(): SessionPreferences {
  return { locationId: null, parameter: null, period: { kind: 'preset', days: 7 } };
}

export class SessionStore {
  private snapshot = { preferences: defaultPreferences(), isLoading: true, unavailable: false };
  private listeners = new Set<() => void>();
  private initialized = false;
  private changed = false;
  private dirty = false;
  private saving = false;
  private running = false;
  private initialization: Promise<void> | null = null;
  private debounce: ReturnType<typeof setTimeout> | undefined;
  private interval: ReturnType<typeof setInterval> | undefined;

  private api: SessionAPI;
  private debounceMs: number;
  private retryMs: number;

  constructor(api: SessionAPI, debounceMs = 300, retryMs = 30_000) {
    this.api = api;
    this.debounceMs = debounceMs;
    this.retryMs = retryMs;
  }

  getSnapshot = () => this.snapshot;

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  };

  start = () => {
    this.running = true;
    this.interval = setInterval(this.retry, this.retryMs);
    void this.retry();
  };

  stop = () => {
    this.running = false;
    clearTimeout(this.debounce);
    clearInterval(this.interval);
  };

  update = (change: Partial<SessionPreferences>) => {
    const preferences = { ...this.snapshot.preferences, ...change };
    if (JSON.stringify(preferences) === JSON.stringify(this.snapshot.preferences)) return;
    this.changed = true;
    this.dirty = true;
    this.publish({ preferences });
    this.schedule();
  };

  retry = async () => {
    if (!this.running) return;
    if (!this.initialized) await this.initialize();
    else if (this.dirty) await this.flush();
  };

  private publish(change: Partial<typeof this.snapshot>) {
    this.snapshot = { ...this.snapshot, ...change };
    this.listeners.forEach(listener => listener());
  }

  private initialize(): Promise<void> {
    if (this.initialization) return this.initialization;
    this.initialization = this.api.getSession().then(preferences => {
      this.initialized = true;
      if (!this.changed) this.publish({ preferences });
      this.publish({ unavailable: this.dirty ? this.snapshot.unavailable : false });
      if (this.dirty) this.schedule();
    }).catch(() => {
      this.publish({ unavailable: true });
    }).finally(() => {
      this.publish({ isLoading: false });
      this.initialization = null;
    });
    return this.initialization;
  }

  private schedule() {
    clearTimeout(this.debounce);
    if (this.running) this.debounce = setTimeout(() => { void this.flush(); }, this.debounceMs);
  }

  private async flush() {
    if (!this.running || this.saving || !this.dirty) return;
    if (!this.initialized) {
      await this.initialize();
      return;
    }
    this.saving = true;
    this.dirty = false;
    let succeeded = false;
    try {
      await this.api.saveSession(this.snapshot.preferences);
      succeeded = true;
      this.publish({ unavailable: false });
    } catch {
      this.dirty = true;
      this.publish({ unavailable: true });
    } finally {
      this.saving = false;
      if (this.dirty && succeeded) this.schedule();
    }
  }
}
