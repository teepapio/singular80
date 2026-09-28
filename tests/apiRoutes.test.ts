/**
 * The routes the dashboard and the game actually call, at the HTTP level.
 *
 * `api.test.ts` covers the runner's controls, `suggestionIdempotency.test.ts` the
 * offline retry; what was missing is everything a person clicks once: the vote
 * button (the only route a *player* ever uses), the content the game loads, the
 * run list, the split, the two "test" buttons and the read-only ends of the check
 * queue. The pure functions behind them are unit-tested; what is tested here is
 * that the route reaches them, and answers the way the panel expects.
 *
 * `app.inject` binds no port. `OPENCODE_BIN` points at a stub and `projectRoot` at
 * a temp directory, so the `implement` route — which really enqueues a run — cannot
 * start a real agent in the real working tree.
 */
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { createApp } from '../server/app';
import type { Store } from '../server/db';
import type { BusEvent, RunRecord, SuggestionView } from '../src/shared/types';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const opened: { close: () => Promise<void>; dir: string }[] = [];
let previousBin: string | undefined;
let previousWebhook: string | undefined;
let previousTelegram: Record<string, string | undefined> = {};

/**
 * A webhook or a bot token that happens to be exported on the machine would make
 * this suite post to a real Discord channel and start a real Telegram poll. Both
 * are cleared here and put back afterwards; the two "test" routes get their
 * webhook from the request instead, so they still have something to work with.
 */
function isolateChannels(): void {
  previousWebhook = process.env.DISCORD_WEBHOOK_URL;
  delete process.env.DISCORD_WEBHOOK_URL;
  for (const key of ['TELEGRAM_BOT_TOKEN', 'TELEGRAM_CHAT_ID', 'TELEGRAM_ALLOWED_USER_IDS']) {
    previousTelegram[key] = process.env[key];
    delete process.env[key];
  }
}

afterEach(async () => {
  for (const app of opened.splice(0)) {
    await app.close();
    rmSync(app.dir, { recursive: true, force: true });
  }
  if (previousBin === undefined) delete process.env.OPENCODE_BIN;
  else process.env.OPENCODE_BIN = previousBin;
  if (previousWebhook === undefined) delete process.env.DISCORD_WEBHOOK_URL;
  else process.env.DISCORD_WEBHOOK_URL = previousWebhook;
  for (const [key, value] of Object.entries(previousTelegram)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
  previousTelegram = {};
  vi.unstubAllGlobals();
});

type Method = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

interface Api {
  call: <T>(method: Method, path: string, body?: unknown) => Promise<{ status: number; body: T }>;
  get: <T>(path: string) => Promise<{ status: number; body: T }>;
  post: <T>(path: string, body?: unknown) => Promise<{ status: number; body: T }>;
  /** A new suggestion, created the way the game creates one. */
  suggestion: (text: string) => Promise<SuggestionView>;
  store: () => Store;
  events: () => BusEvent[];
  dir: string;
}

async function boot(): Promise<Api> {
  isolateChannels();
  const dir = mkdtempSync(join(tmpdir(), 'singular80-routes-'));
  const projectRoot = join(dir, 'repo');
  mkdirSync(projectRoot, { recursive: true });
  const stub = join(projectRoot, 'opencode-stub');
  writeFileSync(stub, '#!/bin/sh\necho \'{"type":"text","part":{"text":"ok"}}\'\nexit 0\n');
  chmodSync(stub, 0o755);
  previousBin = process.env.OPENCODE_BIN;
  process.env.OPENCODE_BIN = stub;
  const app = createApp({
    dataDir: dir,
    contentDir: join(root, 'content'),
    projectRoot,
    distDir: join(root, 'dist-does-not-exist'),
    runnerEnabled: true,
  });
  await app.ready();
  opened.push({ close: () => app.close(), dir });
  const internals = (app as unknown as {
    _singular80: { store: Store; bus: { on: (e: string, fn: (v: BusEvent) => void) => void } };
  })._singular80;
  const seen: BusEvent[] = [];
  internals.bus.on('event', (event) => seen.push(event));
  const call = async <T>(method: Method, path: string, body?: unknown) => {
    const res = await app.inject({
      path,
      method,
      ...(body !== undefined
        ? { headers: { 'content-type': 'application/json' }, payload: JSON.stringify(body) }
        : {}),
    });
    return { status: res.statusCode, body: res.json() as T };
  };
  return {
    call,
    get: <T>(path: string) => call<T>('GET', path),
    post: <T>(path: string, body?: unknown) => call<T>('POST', path, body),
    suggestion: async (text: string) => (await call<SuggestionView>('POST', '/api/suggestions', { text })).body,
    store: () => internals.store,
    events: () => seen,
    dir,
  };
}

describe('POST /api/suggestions/:id/vote', () => {
  it('zählt eine Stimme genau einmal', async () => {
    // The one route a player ever calls. `changed` exists because the dashboard
    // re-animates a vote that counted; a second vote from the same device must not
    // claim it did.
    const api = await boot();
    const view = await api.suggestion('Der Slime soll schneller werden');
    const first = await api.post<{ votes: number; changed: boolean }>(`/api/suggestions/${view.id}/vote`, {
      voterId: 'geraet-eins',
    });
    expect(first.status).toBe(200);
    expect(first.body).toEqual({ votes: 1, changed: true });

    const again = await api.post<{ votes: number; changed: boolean }>(`/api/suggestions/${view.id}/vote`, {
      voterId: 'geraet-eins',
    });
    expect(again.body).toEqual({ votes: 1, changed: false });

    const other = await api.post<{ votes: number; changed: boolean }>(`/api/suggestions/${view.id}/vote`, {
      voterId: 'geraet-zwei',
    });
    expect(other.body).toEqual({ votes: 2, changed: true });
  });

  it('schreibt in die Stimmtabelle und nicht nur in den Zähler', async () => {
    // A counter without a row is a vote the backup cannot restore, and one the
    // delete of a suggestion would leave behind.
    const api = await boot();
    const view = await api.suggestion('Pang: die Bälle sollen schneller fliegen');
    await api.post(`/api/suggestions/${view.id}/vote`, { voterId: 'geraet-eins' });
    await api.post(`/api/suggestions/${view.id}/vote`, { voterId: 'geraet-eins' });
    const rows = api.store().listVotes().filter((v) => v.suggestionId === view.id);
    expect(rows).toHaveLength(1);
    // Hashed, never the raw id: the backup goes into the repository.
    expect(rows[0].voterId).not.toBe('geraet-eins');
  });

  it('lässt die Stimme in den Score einfließen', async () => {
    // `decorate` is unit-tested; what is new here is that the route feeds it the
    // new count, so the list the panel reloads really reorders.
    const api = await boot();
    const view = await api.suggestion('Tetris: die Level sollen schneller kommen');
    const before = (await api.get<{ suggestions: SuggestionView[] }>('/api/suggestions')).body.suggestions[0];
    await api.post(`/api/suggestions/${view.id}/vote`, { voterId: 'geraet-eins' });
    const after = (await api.get<{ suggestions: SuggestionView[] }>('/api/suggestions')).body.suggestions[0];
    expect(after.votes).toBe(1);
    expect(after.breakdown.votes).toBe(3);
    expect(after.score).toBeGreaterThan(before.score);
  });

  it('meldet die Stimme im Bus, damit offene Panels sie sehen', async () => {
    const api = await boot();
    const view = await api.suggestion('Siedler: Handelsweg optimieren');
    await api.post(`/api/suggestions/${view.id}/vote`, { voterId: 'geraet-eins' });
    expect(api.events().map((e) => e.type)).toEqual(['suggestion:new', 'suggestion:vote']);
  });

  it('lehnt eine zu kurze voterId ab, statt sie zu speichern', async () => {
    const api = await boot();
    const view = await api.suggestion('Merge: die Steine sollen schneller fallen');
    for (const voterId of ['', '   ', 'kurz', undefined]) {
      const res = await api.post<{ error: string }>(`/api/suggestions/${view.id}/vote`, { voterId });
      expect(res.status, JSON.stringify(voterId)).toBe(400);
      expect(res.body.error).toContain('voterId');
    }
    expect(api.store().listVotes()).toHaveLength(0);
  });

  it('gibt 404 für einen unbekannten oder unbrauchbaren Vorschlag', async () => {
    const api = await boot();
    // `Number('abc')` is NaN, and a NaN key matches no row: it must read as "no
    // such suggestion" and not as a server error.
    for (const id of ['4242', 'abc', '1.5', '-3']) {
      const res = await api.post<{ error: string }>(`/api/suggestions/${id}/vote`, { voterId: 'geraet-eins' });
      expect(res.status, id).toBe(404);
    }
  });
});

describe('Cluster über HTTP', () => {
  it('hängt einen zweiten, fast gleichen Vorschlag an den ersten', async () => {
    // The same pair `sorting.test.ts` pins as "similar enough"; here it is the
    // route that has to carry the decision into the row, and the list that has to
    // show the cluster on *both* entries, not only on the newcomer.
    const api = await boot();
    const first = await api.suggestion('Füge einen Slime Gegner hinzu, der in kleine Slimes zerfällt');
    const second = await api.suggestion('Neuer Gegner: Slime der sich teilt');
    expect(second.canonicalId).toBe(first.id);
    const listed = (await api.get<{ suggestions: SuggestionView[] }>('/api/suggestions')).body.suggestions;
    expect(listed).toHaveLength(2);
    expect(listed.every((s) => s.clusterSize === 2)).toBe(true);
    expect(listed.every((s) => s.breakdown.cluster === 2)).toBe(true);
  });

  it('lässt unähnliche Texte getrennt', async () => {
    const api = await boot();
    await api.suggestion('Füge einen Slime Gegner hinzu');
    const other = await api.suggestion('Bitte die Lautstärke der Musik senken');
    expect(other.canonicalId).toBeNull();
  });
});

describe('GET /api/suggestions/:id', () => {
  it('liefert den Vorschlag mit seinen Läufen', async () => {
    const api = await boot();
    const view = await api.suggestion('Poker: Chips anders verteilen');
    const res = await api.get<{ suggestion: SuggestionView; runs: RunRecord[] }>(
      `/api/suggestions/${view.id}`,
    );
    expect(res.status).toBe(200);
    expect(res.body.suggestion.text).toBe('Poker: Chips anders verteilen');
    expect(res.body.runs).toEqual([]);
  });

  it('gibt 404 für einen unbekannten', async () => {
    const api = await boot();
    expect((await api.get('/api/suggestions/4242')).status).toBe(404);
  });
});

describe('GET und POST /api/suggestions/:id/split', () => {
  const TEXT = 'Neue Waffe hinzufügen\nNeuen Gegner einbauen';

  it('zeigt erst nur die Vorschau, ohne etwas anzulegen', async () => {
    const api = await boot();
    const view = await api.suggestion(TEXT);
    const res = await api.get<{ tasks: string[] }>(`/api/suggestions/${view.id}/split`);
    expect(res.status).toBe(200);
    expect(res.body.tasks).toEqual(['Neue Waffe hinzufügen', 'Neuen Gegner einbauen']);
    expect(api.store().listSuggestions()).toHaveLength(1);
  });

  it('legt je Teilauftrag eine eigene Zeile mit Elternbezug an', async () => {
    const api = await boot();
    const view = await api.suggestion(TEXT);
    const res = await api.post<{ parent: SuggestionView; created: SuggestionView[] }>(
      `/api/suggestions/${view.id}/split`,
    );
    expect(res.status).toBe(200);
    expect(res.body.created.map((c) => c.text)).toEqual([
      'Neue Waffe hinzufügen',
      'Neuen Gegner einbauen',
    ]);
    for (const child of res.body.created) {
      expect(child.parentId).toBe(view.id);
      expect(child.source).toBe('dashboard');
    }
    expect(api.store().listSuggestions()).toHaveLength(3);
  });

  it('lehnt einen Vorschlag ab, aus dem nichts herauszuholen ist', async () => {
    const api = await boot();
    const view = await api.suggestion('Bitte die Lautstärke leiser machen');
    const res = await api.post<{ error: string }>(`/api/suggestions/${view.id}/split`);
    expect(res.status).toBe(400);
    expect(res.body.error).toContain('Einzelaufträge');
  });

  it('nimmt eine eigene Liste, wenn eine geliefert wird', async () => {
    const api = await boot();
    const view = await api.suggestion('Irgendetwas');
    const res = await api.post<{ created: SuggestionView[] }>(`/api/suggestions/${view.id}/split`, {
      tasks: ['Erster Teil', 'Zweiter Teil'],
    });
    expect(res.status).toBe(200);
    expect(res.body.created.map((c) => c.text)).toEqual(['Erster Teil', 'Zweiter Teil']);
  });

  it('lehnt eine kaputte Liste ab, statt eine Zeile ohne Kinder anzulegen', async () => {
    const api = await boot();
    const view = await api.suggestion('Irgendetwas');
    for (const tasks of ['nope', [], ['nur einer'], [42]]) {
      const res = await api.post<{ error: string }>(`/api/suggestions/${view.id}/split`, { tasks });
      expect(res.status, JSON.stringify(tasks)).toBe(400);
    }
    expect(api.store().listSuggestions()).toHaveLength(1);
  });

  it('gibt 404 für einen unbekannten Vorschlag', async () => {
    const api = await boot();
    expect((await api.get('/api/suggestions/4242/split')).status).toBe(404);
    expect((await api.post('/api/suggestions/4242/split')).status).toBe(404);
  });
});

describe('GET /api/health', () => {
  it('meldet den Zustand, den die Statusseite anzeigt', async () => {
    const api = await boot();
    await api.suggestion('Neue Waffe hinzufügen');
    const res = await api.get<{
      ok: boolean;
      uptime: number;
      opencodeBin: string;
      opencodeFound: boolean;
      suggestions: number;
      activeRuns: RunRecord[];
    }>('/api/health');
    expect(res.status).toBe(200);
    expect(res.body.ok).toBe(true);
    expect(res.body.suggestions).toBe(1);
    expect(res.body.activeRuns).toEqual([]);
    expect(typeof res.body.uptime).toBe('number');
    // The stub this suite installed, not a guess about the owner's machine.
    expect(res.body.opencodeFound).toBe(true);
  });
});

describe('GET /api/content und POST /api/content/reload', () => {
  it('liefert den Pack, den das Spiel lädt', async () => {
    const api = await boot();
    const res = await api.get<{ enemies: { id: string }[]; weapons: { id: string }[]; version: number }>(
      '/api/content',
    );
    expect(res.status).toBe(200);
    expect(res.body.enemies.map((e) => e.id)).toContain('slime');
    expect(res.body.weapons.map((w) => w.id)).toContain('pistol');
    expect(res.body.version).toBeGreaterThan(0);
  });

  it('lädt neu und meldet es im Bus', async () => {
    // The dashboard's "Neu laden" button. The version has to change, otherwise the
    // game compares against the old one and keeps its content.
    const api = await boot();
    const before = (await api.get<{ version: number }>('/api/content')).body.version;
    const res = await api.post<{ version: number }>('/api/content/reload');
    expect(res.status).toBe(200);
    expect(res.body.version).toBe(before);
    expect(api.events().map((e) => e.type)).toEqual(['content:reloaded']);
  });
});

describe('GET /api/stats', () => {
  it('zählt Status, Stimmen und Cluster über alle Vorschläge', async () => {
    const api = await boot();
    const first = await api.suggestion('Tetris: eine neue Level-Serie');
    await api.suggestion('Tetris: noch eine Level-Serie');
    await api.post(`/api/suggestions/${first.id}/vote`, { voterId: 'geraet-eins' });
    const res = await api.get<{
      stats: { total: number; votes: number; implemented: number; byStatus: Record<string, number> };
      runs: RunRecord[];
    }>('/api/stats');
    expect(res.status).toBe(200);
    expect(res.body.stats.total).toBe(2);
    expect(res.body.stats.votes).toBe(1);
    expect(res.body.stats.byStatus.new).toBe(2);
    expect(res.body.runs).toEqual([]);
  });
});

describe('Die Run-Routen', () => {
  it('listet die Läufe und findet einen einzelnen', async () => {
    const api = await boot();
    const view = await api.suggestion('Pang: Bounce-Anzeige');
    const started = await api.post<{ run: RunRecord }>(`/api/suggestions/${view.id}/implement`, {});
    const list = await api.get<{ runs: RunRecord[] }>('/api/runs');
    expect(list.status).toBe(200);
    expect(list.body.runs.map((r) => r.id)).toContain(started.body.run.id);
    const one = await api.get<{ run?: RunRecord }>(`/api/runs/${started.body.run.id}`);
    expect(one.status).toBe(200);
  });

  it('gibt 404 für einen unbekannten Lauf', async () => {
    const api = await boot();
    expect((await api.get('/api/runs/run_gibt_es_nicht')).status).toBe(404);
  });

  it('bricht einen wartenden Lauf ab und meldet einen unbekannten', async () => {
    const api = await boot();
    // Paused first: the run must stay `queued`, so nothing spawns and the state
    // cannot change under the assertion.
    await api.post('/api/runner/pause', { paused: true });
    const view = await api.suggestion('Pang: Bounce-Anzeige');
    const started = await api.post<{ run: RunRecord }>(`/api/suggestions/${view.id}/implement`, {});
    const cancelled = await api.post<{ ok: boolean }>(`/api/runs/${started.body.run.id}/cancel`);
    expect(cancelled.status).toBe(200);
    expect(cancelled.body.ok).toBe(true);
    expect(api.store().getRun(started.body.run.id)!.status).toBe('cancelled');
    const missing = await api.post<{ error: string }>('/api/runs/run_fehlt/cancel');
    expect(missing.status).toBe(400);
    expect(missing.body.error).toBeTruthy();
  }, 30_000);

  it('räumt auf, ohne etwas zu beanspruchen, das nicht verwaist ist', async () => {
    const api = await boot();
    const res = await api.post<{ fixed: RunRecord[] }>('/api/runs/reconcile');
    expect(res.status).toBe(200);
    // Nothing is running, so the answer is an empty list — and the route must not
    // invent work while saying it cleaned up.
    expect(res.body.fixed).toEqual([]);
  });
});

describe('Die beiden Testknöpfe', () => {
  it('sagt es, wenn kein Discord-Webhook hinterlegt ist', async () => {
    const api = await boot();
    const res = await api.post<{ error: string }>('/api/discord/test');
    expect(res.status).toBe(400);
    expect(res.body.error).toContain('Kein Webhook');
  });

  it('lehnt einen Webhook außerhalb von Discord ab, ohne eine Anfrage zu senden', async () => {
    const api = await boot();
    // A host outside Discord's own domains: refused before any request goes out,
    // so this case needs no network and proves the gate is in front of the fetch.
    // 400, not 502: nothing was attempted, so nothing upstream failed.
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    const res = await api.post<{ error: string }>('/api/discord/test', {
      webhook: 'https://example.invalid/webhook',
    });
    expect(res.status).toBe(400);
    expect(res.body.error).toContain('example.invalid');
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('schickt die Testnachricht, wenn ein Webhook konfiguriert ist', async () => {
    const api = await boot();
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({ id: 'm1' }) });
    vi.stubGlobal('fetch', fetchMock);
    const res = await api.post<{ ok: boolean }>('/api/discord/test', {
      webhook: 'https://discord.com/api/webhooks/1/token',
    });
    expect(res.status).toBe(200);
    expect(res.body.ok).toBe(true);
    expect(String(fetchMock.mock.calls[0][0])).toContain('discord.com');
  });

  it('sagt es, wenn Telegram nicht konfiguriert ist, ohne zu raten', async () => {
    const api = await boot();
    const res = await api.post<{ error: string }>('/api/telegram/test');
    expect(res.status).toBe(400);
    expect(res.body.error).toContain('TELEGRAM_BOT_TOKEN');
  });

  it('schickt die Testnachricht, wenn Telegram konfiguriert ist', async () => {
    const api = await boot();
    // Set after the app exists, so no poll starts: the route reads the
    // environment at request time, and the app only looks at it when it boots.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({}) });
    vi.stubGlobal('fetch', fetchMock);
    const res = await api.post<{ ok: boolean }>('/api/telegram/test');
    expect(res.status).toBe(200);
    expect(res.body.ok).toBe(true);
    expect(JSON.parse((fetchMock.mock.calls[0][1] as { body: string }).body).text).toContain('verbunden');
  });
});

describe('Die Prüfwarteschlange über HTTP', () => {
  it('liefert den Katalog, aus dem die Knöpfe gebaut werden', async () => {
    const api = await boot();
    const res = await api.get<{ specs: { id: string; kind: string; title: string; probe: string }[] }>(
      '/api/checks/catalogue',
    );
    expect(res.status).toBe(200);
    expect(res.body.specs.length).toBeGreaterThan(0);
    for (const spec of res.body.specs) {
      expect(spec.id, 'eine Prüfung ohne id').toBeTruthy();
      expect(spec.kind, `${spec.id} ohne kind`).toBeTruthy();
      expect(spec.title, `${spec.id} ohne title`).toBeTruthy();
      expect(['static', 'device']).toContain(spec.probe);
    }
  });

  it('meldet eine leere Schlange über das temp-Verzeichnis', async () => {
    const api = await boot();
    const res = await api.get<{ paused: boolean; activeCheck: unknown; queue: unknown[]; recent: unknown[] }>(
      '/api/checks',
    );
    expect(res.status).toBe(200);
    expect(res.body.paused).toBe(false);
    expect(res.body.activeCheck).toBeNull();
    expect(res.body.queue).toEqual([]);
    expect(res.body.recent).toEqual([]);
  });

  it('lehnt eine kaputte specId ab, statt eine Prüfung zu erfinden', async () => {
    const api = await boot();
    for (const specId of ['', '   ', 42, null, undefined]) {
      const res = await api.post<{ error: string }>('/api/checks', { specId });
      expect(res.status, JSON.stringify(specId)).toBe(400);
    }
  });

  it('lehnt eine unbekannte specId ab', async () => {
    const api = await boot();
    const res = await api.post<{ error: string }>('/api/checks', { specId: 'gibt-es-nicht' });
    expect(res.status).toBe(400);
    expect(res.body.error).toBeTruthy();
  });

  it('gibt 404 für eine unbekannte Prüfung und 409 für eine ohne Befund', async () => {
    const api = await boot();
    expect((await api.get('/api/checks/chk_fehlt')).status).toBe(404);
    const cancel = await api.post<{ error: string }>('/api/checks/chk_fehlt/cancel');
    expect(cancel.status).toBe(404);
    const promote = await api.post<{ error: string }>('/api/checks/chk_fehlt/promote');
    expect(promote.status).toBe(409);
  });

  it('pausiert die Prüfwarteschlange und lehnt Unbrauchbares ab', async () => {
    const api = await boot();
    const on = await api.post<{ paused: boolean }>('/api/checks/pause', { paused: true });
    expect(on.status).toBe(200);
    expect(on.body.paused).toBe(true);
    const bad = await api.post<{ error: string }>('/api/checks/pause', { paused: 'ja' });
    expect(bad.status).toBe(400);
    expect(bad.body.error).toContain('true oder false');
  });
});
