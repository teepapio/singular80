import type { RunEvent } from '../shared/types';

/**
 * A quiet run is not necessarily a stuck run: builds and test suites can take a
 * while without producing any new output. Only after this much silence do we
 * show a warning.
 */
export const ACTIVITY_WARN_MS = 90_000;

/**
 * No output for this long almost certainly means the run is stuck or was
 * orphaned (e.g. the server restarted while opencode kept running).
 */
export const ACTIVITY_STALE_MS = 10 * 60_000;

export type RunActivityLevel = 'ok' | 'warn' | 'stale' | 'offline';

export interface RunActivityStatus {
  level: RunActivityLevel;
  /** German one-liner shown in the dashboard's run panel. */
  label: string;
}

/** Newest timestamp among the given run events, or null when there are none. */
export function lastEventTimestamp(events: readonly RunEvent[]): number | null {
  let latest: number | null = null;
  for (const event of events) {
    if (latest === null || event.t > latest) latest = event.t;
  }
  return latest;
}

/** Compact German duration, e.g. `12s`, `3 min 5s`, `1 h 12 min`. */
export function formatDuration(ms: number): string {
  const seconds = Math.max(0, Math.round(ms / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  const rest = seconds % 60;
  if (minutes < 60) return rest > 0 ? `${minutes} min ${rest}s` : `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  return `${hours} h ${minutes % 60} min`;
}

/**
 * Turns the raw "last activity" bookkeeping into a human-readable status that
 * tells the user whether a run is still alive or looks stuck.
 */
export function describeRunActivity(input: {
  /** Wall-clock time of the last received or synced event, or null. */
  lastActivityAt: number | null;
  /** Process start time, used until the very first event arrives. */
  startedAt: number | null;
  /** Whether the live SSE stream is currently connected. */
  connected: boolean;
  /** Whether the runner still knows a live process for this run (undefined = unknown). */
  alive?: boolean;
  /** Injectable clock for tests. */
  now?: number;
}): RunActivityStatus {
  const now = input.now ?? Date.now();
  const base = input.lastActivityAt ?? input.startedAt;
  if (base === null || base === undefined) {
    return { level: 'ok', label: input.alive === false ? 'Prozess nicht mehr aktiv · Run wurde beendet' : 'Aktiv · warte auf Ausgabe …' };
  }
  const silentMs = Math.max(0, now - base);
  const silent = formatDuration(silentMs);
  if (silentMs >= ACTIVITY_STALE_MS) {
    return input.alive === true
      ? {
          level: 'warn',
          label: `Seit ${silent} keine neue Ausgabe — der Prozess läuft noch (evtl. sehr langer Build/Test)`,
        }
      : {
          level: 'stale',
          label: `Seit ${silent} keine Ausgabe — Run hängt vermutlich oder wurde unterbrochen`,
        };
  }
  if (silentMs >= ACTIVITY_WARN_MS) {
    return {
      level: 'warn',
      label: input.alive === true
        ? `Seit ${silent} keine Ausgabe — Prozess läuft weiter, evtl. langer Build/Test`
        : `Seit ${silent} keine Ausgabe — evtl. langer Build/Test, sonst hängt der Run`,
    };
  }
  if (!input.connected) {
    return { level: 'offline', label: `Keine Live-Verbindung · letzte Ausgabe vor ${silent}` };
  }
  return { level: 'ok', label: `Aktiv · letzte Ausgabe vor ${silent}` };
}

/**
 * Tells whether the dashboard should ask the server to clean up stuck runs on
 * its own, without waiting for the user to click the cleanup button.
 *
 * Several running rows are *not* a reason on their own any more: the queue runs
 * one session per lane, so `runningCount === capacity` is the normal case and
 * the old "more than one is a phantom" rule would have wiped live runs. What
 * still is a reason is a run count the configured number of lanes cannot hold,
 * or a run the server has already reported as process-less.
 */
export function needsRunCleanup(input: {
  /** Number of runs currently marked as `running` in the database. */
  runningCount: number;
  /** Lanes the operator configured; how many runs may run at the same time. */
  capacity: number;
  /** Ids of running runs whose process the server no longer knows. */
  deadRunIds?: readonly string[];
}): boolean {
  if (input.deadRunIds && input.deadRunIds.length > 0) return true;
  return input.runningCount > Math.max(1, input.capacity);
}
