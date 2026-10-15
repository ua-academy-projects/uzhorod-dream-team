// A bit longer than the Fetcher's own 15 s per-request timeout, so its error reply still arrives
export const REQUEST_TIMEOUT_MS = 20_000;
export const MAX_RECONNECT_DELAY_MS = 30_000;

/** Requests waiting for a reply, by correlationId. No broker here, so it can be unit-tested. */
export class PendingRequests {
  #waiting = new Map();

  /** Promise of the reply for `id`; rejects if none arrives within `timeoutMs`. */
  add(id, timeoutMs) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#waiting.delete(id);
        reject(new Error(`no reply from the Fetcher within ${timeoutMs / 1000}s`));
      }, timeoutMs);
      this.#waiting.set(id, { resolve, reject, timer });
    });
  }

  /** Resolves the request `id` with `reply`; false if nobody waits for it (anymore). */
  settle(id, reply) {
    const entry = this.#take(id);
    entry?.resolve(reply);
    return entry !== undefined;
  }

  /** Rejects the request `id` with `err` (e.g. it could not be sent). */
  fail(id, err) {
    this.#take(id)?.reject(err);
  }

  #take(id) {
    const entry = this.#waiting.get(id);
    if (!entry) return undefined;
    clearTimeout(entry.timer);
    this.#waiting.delete(id);
    return entry;
  }

  get size() {
    return this.#waiting.size;
  }
}

/** Turns a raw reply into { ok, ... }; anything that is not a reply object becomes an internal error. */
export function parseReply(raw) {
  try {
    const reply = typeof raw === 'string' ? JSON.parse(raw) : raw;
    if (reply && typeof reply === 'object' && typeof reply.ok === 'boolean') return reply;
  } catch {
    // fall through
  }
  return { ok: false, error: 'Invalid reply from the Fetcher', kind: 'internal' };
}
