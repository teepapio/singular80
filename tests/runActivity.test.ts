import { describe, expect, it } from 'vitest';
import {
  ACTIVITY_STALE_MS,
  ACTIVITY_WARN_MS,
  describeRunActivity,
  formatDuration,
  lastEventTimestamp,
  needsRunCleanup,
} from '../src/dashboard/runActivity';
import type { RunEvent } from '../src/shared/types';

const event = (t: number): RunEvent => ({ t, kind: 'text', text: 'x' });

describe('lastEventTimestamp', () => {
  it('liefert null ohne Events', () => {
    expect(lastEventTimestamp([])).toBeNull();
  });

  it('liefert den neuesten Zeitstempel', () => {
    expect(lastEventTimestamp([event(10), event(30), event(20)])).toBe(30);
  });
});

describe('formatDuration', () => {
  it('formatiert Sekunden, Minuten und Stunden', () => {
    expect(formatDuration(5_000)).toBe('5s');
    expect(formatDuration(65_000)).toBe('1 min 5s');
    expect(formatDuration(120_000)).toBe('2 min');
    expect(formatDuration(4_320_000)).toBe('1 h 12 min');
  });
});

describe('describeRunActivity', () => {
  const now = 1_000_000;

  it('meldet Aktivität bei frischer Ausgabe', () => {
    const status = describeRunActivity({ lastActivityAt: now - 3_000, startedAt: null, connected: true, now });
    expect(status.level).toBe('ok');
    expect(status.label).toContain('vor 3s');
  });

  it('nutzt die Startzeit, solange noch kein Event kam', () => {
    const status = describeRunActivity({ lastActivityAt: null, startedAt: now - 2_000, connected: true, now });
    expect(status.level).toBe('ok');
  });

  it('warnt nach längerer Stille', () => {
    const status = describeRunActivity({
      lastActivityAt: now - ACTIVITY_WARN_MS - 1,
      startedAt: null,
      connected: true,
      now,
    });
    expect(status.level).toBe('warn');
  });

  it('stuft sehr lange Stille als hängend ein', () => {
    const status = describeRunActivity({
      lastActivityAt: now - ACTIVITY_STALE_MS - 1,
      startedAt: null,
      connected: true,
      now,
    });
    expect(status.level).toBe('stale');
  });

  it('meldet eine fehlende Live-Verbindung', () => {
    const status = describeRunActivity({ lastActivityAt: now - 1_000, startedAt: null, connected: false, now });
    expect(status.level).toBe('offline');
  });

  it('warnt statt stale, wenn der Prozess nach langer Stille noch läuft', () => {
    const status = describeRunActivity({
      lastActivityAt: now - ACTIVITY_STALE_MS - 1,
      startedAt: null,
      connected: true,
      alive: true,
      now,
    });
    expect(status.level).toBe('warn');
    expect(status.label).toContain('Prozess läuft noch');
  });

  it('bevorzugt die Stale-Warnung gegenüber der Verbindungswarnung', () => {
    const status = describeRunActivity({
      lastActivityAt: now - ACTIVITY_STALE_MS,
      startedAt: null,
      connected: false,
      now,
    });
    expect(status.level).toBe('stale');
  });
});

describe('needsRunCleanup', () => {
  it('fordert kein Aufräumen ohne Auffälligkeit', () => {
    expect(needsRunCleanup({ runningCount: 1, capacity: 3 })).toBe(false);
    expect(needsRunCleanup({ runningCount: 0, capacity: 3 })).toBe(false);
  });

  it('hält mehrere laufende Runs für normal — das sind die Spuren', () => {
    // Drei Spuren, drei laufende Runs: der Normalfall, seit es Lanes gibt.
    // Die alte Regel ("mehr als einer ist ein Phantom") würde hier einen
    // lebenden Run abschießen.
    expect(needsRunCleanup({ runningCount: 3, capacity: 3 })).toBe(false);
    expect(needsRunCleanup({ runningCount: 2, capacity: 1 })).toBe(true);
  });

  it('fordert Aufräumen, wenn mehr Runs laufen als Spuren existieren', () => {
    expect(needsRunCleanup({ runningCount: 4, capacity: 3 })).toBe(true);
  });

  it('fordert Aufräumen, wenn ein Run keinen lebenden Prozess hat', () => {
    expect(needsRunCleanup({ runningCount: 1, capacity: 3, deadRunIds: ['run_1'] })).toBe(true);
  });
});
