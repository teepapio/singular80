/**
 * Die Offline-Warteschlange des Spiels schickt denselben `clientKey` erneut,
 * wenn die Antwort auf den ersten Versuch verlorenging. Der Server darf daraus
 * keine zweite Zeile, keine zweite Discord-Nachricht und kein zweites
 * `suggestion:new` machen.
 *
 * `app.inject` statt `listen`: es bindet keinen Port. Der Runner bleibt aus,
 * `OPENCODE_BIN` zeigt trotzdem auf einen Stub und `projectRoot` auf ein
 * temporäres Verzeichnis — sonst könnte ein Test durch die Hintertür doch einen
 * echten Agenten im echten Arbeitsbaum starten.
 */
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { EventEmitter } from 'node:events';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createApp } from '../server/app';
import { CLIENT_KEY_MAX, Store, normalizeClientKey } from '../server/db';
import type { BusEvent, Suggestion, SuggestionView } from '../src/shared/types';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const tempDirs: string[] = [];
let previousBin: string | undefined;
let previousWebhook: string | undefined;

function tempDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

afterEach(() => {
  for (const dir of tempDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
  if (previousBin === undefined) delete process.env.OPENCODE_BIN;
  else process.env.OPENCODE_BIN = previousBin;
  if (previousWebhook === undefined) delete process.env.DISCORD_WEBHOOK_URL;
  else process.env.DISCORD_WEBHOOK_URL = previousWebhook;
  vi.restoreAllMocks();
});

beforeEach(() => {
  previousWebhook = process.env.DISCORD_WEBHOOK_URL;
  delete process.env.DISCORD_WEBHOOK_URL;
});

interface Api {
  post: (body: unknown) => Promise<{ status: number; headers: Record<string, unknown>; body: SuggestionView }>;
  put: <T>(path: string, body: unknown) => Promise<{ status: number; body: T }>;
  count: () => number;
  suggestion: (id: number) => Suggestion;
  events: () => BusEvent[];
  close: () => Promise<void>;
  store: Store;
}

/** Every call that would have posted to Discord, counted instead of sent. */
let webhookCalls = 0;
function stubDiscord(): void {
  webhookCalls = 0;
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
    const url = String(input instanceof URL ? input.toString() : (input as Request).url ?? input);
    if (url.includes('discord.com')) {
      webhookCalls += 1;
      return new Response(JSON.stringify({ id: `msg-${webhookCalls}` }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    }
    throw new Error(`unerwarteter Netzwerkzugriff in einem Test: ${url}`);
  });
}

async function boot(): Promise<Api> {
  const dataDir = tempDir('singular80-idem-');
  const projectRoot = tempDir('singular80-idem-repo-');
  const stub = join(projectRoot, 'opencode-stub');
  writeFileSync(stub, '#!/bin/sh\nexit 0\n');
  chmodSync(stub, 0o755);
  previousBin = process.env.OPENCODE_BIN;
  process.env.OPENCODE_BIN = stub;

  const app = createApp({
    dataDir,
    contentDir: join(root, 'content'),
    projectRoot,
    distDir: join(root, 'dist-does-not-exist'),
    runnerEnabled: false,
  });
  await app.ready();
  const store = (app as unknown as { _singular80: { store: Store } })._singular80.store;
  const bus = (app as unknown as { _singular80: { bus: EventEmitter } })._singular80.bus;
  const seen: BusEvent[] = [];
  bus.on('event', (event: BusEvent) => seen.push(event));
  const call = async <T>(path: string, method: 'GET' | 'POST' | 'PUT', payload?: unknown) => {
    const res = await app.inject({
      path,
      method,
      ...(payload !== undefined
        ? { headers: { 'content-type': 'application/json' }, payload: JSON.stringify(payload) }
        : {}),
    });
    return { status: res.statusCode, headers: res.headers as Record<string, unknown>, body: res.json() as T };
  };
  return {
    post: (body) => call<SuggestionView>('/api/suggestions', 'POST', body),
    put: <T>(path: string, body: unknown) => call<T>(path, 'PUT', body),
    count: () => store.listSuggestions().length,
    suggestion: (id) => store.getSuggestion(id)!,
    events: () => seen,
    close: () => app.close(),
    store,
  };
}

const text = 'Die Lobby sollte den letzten Gewinn des Tages zeigen';

describe('POST /api/suggestions mit clientKey', () => {
  it('legt beim ersten Absenden genau eine Zeile an', async () => {
    const api = await boot();
    const res = await api.post({ text, author: 'Spiel', clientKey: 'sug-2026-09-26-7' });
    expect(res.status).toBe(200);
    expect(res.body.id).toBeGreaterThan(0);
    expect(res.body.clientKey).toBe('sug-2026-09-26-7');
    expect(api.count()).toBe(1);
    expect(api.suggestion(res.body.id).clientKey).toBe('sug-2026-09-26-7');
    await api.close();
  });

  it('liefert beim Wiederholen dieselbe id und legt nichts Neues an', async () => {
    const api = await boot();
    const first = await api.post({ text, author: 'Spiel', clientKey: 'sug-doppelt' });
    const second = await api.post({ text, author: 'Spiel', clientKey: 'sug-doppelt' });
    expect(second.status).toBe(200);
    expect(second.body.id).toBe(first.body.id);
    expect(second.body.createdAt).toBe(first.body.createdAt);
    expect(api.count()).toBe(1);
    await api.close();
  });

  it('antwortet beim Wiederholen mit dem aktuellen Zustand, nicht mit dem alten', async () => {
    const api = await boot();
    const first = await api.post({ text, author: 'Spiel', clientKey: 'sug-status' });
    api.store.updateSuggestionStatus(first.body.id, 'implemented');
    const second = await api.post({ text, author: 'Spiel', clientKey: 'sug-status' });
    expect(second.body.id).toBe(first.body.id);
    expect(second.body.status).toBe('implemented');
    expect(api.count()).toBe(1);
    await api.close();
  });

  it('meldet beim Wiederholen weder Discord noch ein suggestion:new', async () => {
    const api = await boot();
    stubDiscord();
    await api.put('/api/settings', { discordWebhook: 'https://discord.com/api/webhooks/1/token' });

    const first = await api.post({ text, author: 'Spiel', clientKey: 'sug-silent' });
    expect(webhookCalls).toBe(1);
    expect(api.events().map((e) => e.type)).toEqual(['suggestion:new']);

    const second = await api.post({ text, author: 'Spiel', clientKey: 'sug-silent' });
    // No second post to Discord, no second event, and nothing was written: the
    // Discord message id of the first submit is still the one on the row.
    expect(webhookCalls).toBe(1);
    expect(api.events().map((e) => e.type)).toEqual(['suggestion:new']);
    expect(second.headers['x-suggestion-replay']).toBe('1');
    expect(second.body.discordMessageId).toBe('msg-1');
    expect(second.body.id).toBe(first.body.id);
    await api.close();
  });

  it('lässt einen neuen Schlüssel weiterhin einen neuen Vorschlag anlegen', async () => {
    const api = await boot();
    const a = await api.post({ text, author: 'Spiel', clientKey: 'a' });
    const b = await api.post({ text, author: 'Spiel', clientKey: 'b' });
    expect(b.body.id).not.toBe(a.body.id);
    expect(api.count()).toBe(2);
    await api.close();
  });
});

describe('POST /api/suggestions ohne clientKey', () => {
  it('verhält sich wie bisher: jeder Versuch ist ein eigener Vorschlag', async () => {
    const api = await boot();
    stubDiscord();
    await api.put('/api/settings', { discordWebhook: 'https://discord.com/api/webhooks/1/token' });
    const a = await api.post({ text, author: 'Dashboard' });
    const b = await api.post({ text, author: 'Dashboard' });
    expect(b.body.id).not.toBe(a.body.id);
    expect(b.body.clientKey).toBeNull();
    expect(api.count()).toBe(2);
    expect(webhookCalls).toBe(2);
    expect(api.events().map((e) => e.type)).toEqual(['suggestion:new', 'suggestion:new']);
    await api.close();
  });

  it('behandelt einen leeren Schlüssel wie einen fehlenden', async () => {
    const api = await boot();
    const a = await api.post({ text, clientKey: '' });
    const b = await api.post({ text, clientKey: '   ' });
    expect(b.body.id).not.toBe(a.body.id);
    expect(a.body.clientKey).toBeNull();
    expect(b.body.clientKey).toBeNull();
    expect(api.count()).toBe(2);
    await api.close();
  });

  it('behandelt nur Leerzeichen als Leerraum, nicht als neuen Schlüssel', async () => {
    const api = await boot();
    const a = await api.post({ text, clientKey: 'mit rand' });
    const b = await api.post({ text, clientKey: '  mit rand  ' });
    expect(b.body.id).toBe(a.body.id);
    expect(b.body.clientKey).toBe('mit rand');
    expect(api.count()).toBe(1);
    await api.close();
  });
});

describe('Unbrauchbarer clientKey', () => {
  it('ignoriert Werte, die keine Zeichenkette sind, ohne Fehler', async () => {
    const api = await boot();
    for (const bad of [42, true, null, { id: 7 }, ['x'], 1.5]) {
      const res = await api.post({ text, clientKey: bad });
      expect(res.status).toBe(200);
      expect(res.body.clientKey).toBeNull();
    }
    // Ignored, not rejected: every one of them is its own suggestion, exactly
    // like a client build that does not know the field.
    expect(api.count()).toBe(6);
    await api.close();
  });

  it('ignoriert einen zu langen Schlüssel, statt ihn zu kürzen', async () => {
    const api = await boot();
    const long = 'k'.repeat(CLIENT_KEY_MAX + 1);
    const a = await api.post({ text, clientKey: long });
    const b = await api.post({ text, clientKey: long });
    expect(a.body.clientKey).toBeNull();
    // Truncating would let two keys with a common 64-char prefix collapse into
    // one row and hand a retry somebody else's suggestion.
    expect(b.body.id).not.toBe(a.body.id);
    expect(api.count()).toBe(2);
    await api.close();
  });

  it('nimmt einen Schlüssel mit genau 64 Zeichen an', async () => {
    const api = await boot();
    const key = 'k'.repeat(CLIENT_KEY_MAX);
    const a = await api.post({ text, clientKey: key });
    const b = await api.post({ text, clientKey: key });
    expect(a.body.clientKey).toBe(key);
    expect(b.body.id).toBe(a.body.id);
    expect(api.count()).toBe(1);
    await api.close();
  });

  it('normalisiert Schlüssel deterministisch', () => {
    expect(normalizeClientKey(undefined)).toBeNull();
    expect(normalizeClientKey('')).toBeNull();
    expect(normalizeClientKey('   ')).toBeNull();
    expect(normalizeClientKey(7)).toBeNull();
    expect(normalizeClientKey({})).toBeNull();
    expect(normalizeClientKey(' abc ')).toBe('abc');
    expect(normalizeClientKey('k'.repeat(CLIENT_KEY_MAX))).toHaveLength(CLIENT_KEY_MAX);
    expect(normalizeClientKey('k'.repeat(CLIENT_KEY_MAX + 1))).toBeNull();
  });
});

describe('Store: Idempotenz auf Datenbankebene', () => {
  const input = (clientKey: unknown) => ({
    text,
    author: 'Spiel',
    source: 'game' as const,
    category: 'ui',
    canonicalId: null,
    clientKey,
  });

  it('meldet beim zweiten Aufruf created: false', () => {
    const store = new Store(tempDir('singular80-idem-store-'));
    const first = store.createSuggestionOnce(input('k1'));
    const second = store.createSuggestionOnce(input('k1'));
    expect(first.created).toBe(true);
    expect(second.created).toBe(false);
    expect(second.suggestion.id).toBe(first.suggestion.id);
    expect(store.listSuggestions()).toHaveLength(1);
  });

  it('lässt viele Vorschläge ohne Schlüssel zu (partieller Index)', () => {
    const store = new Store(tempDir('singular80-idem-null-'));
    for (let i = 0; i < 3; i += 1) store.createSuggestionOnce(input(null));
    store.createSuggestionOnce(input(undefined));
    expect(store.listSuggestions()).toHaveLength(4);
  });

  it('gewinnt gegen einen zweiten Prozess auf derselben Datei', () => {
    // Two `Store`s on one file stand in for two server processes (or two
    // retries in flight). The unique index is what stops the second one; a
    // read-then-write in the route would have inserted a duplicate here.
    const dataDir = tempDir('singular80-idem-race-');
    const first = new Store(dataDir);
    const second = new Store(dataDir);
    const a = first.createSuggestionOnce(input('race'));
    const b = second.createSuggestionOnce(input('race'));
    expect(a.created).toBe(true);
    expect(b.created).toBe(false);
    expect(b.suggestion.id).toBe(a.suggestion.id);
    expect(second.listSuggestions()).toHaveLength(1);
  });

  it('wirft einen anderen Datenbankfehler unverändert weiter', () => {
    const store = new Store(tempDir('singular80-idem-ddl-'));
    // The catch only knows about the uniqueness conflict. Anything else — a
    // closed database, a broken file — has to reach the caller instead of being
    // mistaken for a replay.
    store.db.close();
    expect(() => store.createSuggestionOnce(input('k'))).toThrow();
  });

  it('findet einen Vorschlag über seinen Schlüssel wieder', () => {
    const store = new Store(tempDir('singular80-idem-get-'));
    const { suggestion } = store.createSuggestionOnce(input('gefunden'));
    expect(store.getSuggestionByClientKey('gefunden')?.id).toBe(suggestion.id);
    expect(store.getSuggestionByClientKey('gibt-es-nicht')).toBeNull();
  });
});

describe('Migration einer alten Datenbank', () => {
  /** A database from before the offline queue existed: no `client_key` column. */
  function legacyStore(): { store: Store; dataDir: string } {
    const dataDir = tempDir('singular80-idem-legacy-');
    const db = new DatabaseSync(join(dataDir, 'singular80.db'));
    db.exec(`
      CREATE TABLE suggestions (
        id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, author TEXT NOT NULL DEFAULT 'Anonym',
        source TEXT NOT NULL DEFAULT 'game', category TEXT NOT NULL DEFAULT 'other', status TEXT NOT NULL DEFAULT 'new',
        votes INTEGER NOT NULL DEFAULT 0, canonical_id INTEGER, created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL, discord_message_id TEXT, run_id TEXT
      );
      CREATE TABLE votes (
        suggestion_id INTEGER NOT NULL, voter_id TEXT NOT NULL, created_at INTEGER NOT NULL,
        PRIMARY KEY (suggestion_id, voter_id)
      );
      CREATE TABLE runs (
        id TEXT PRIMARY KEY, suggestion_id INTEGER NOT NULL, status TEXT NOT NULL, session_id TEXT,
        prompt TEXT NOT NULL, exit_code INTEGER, cost REAL, tokens_input INTEGER, tokens_output INTEGER,
        commit_hash TEXT, created_at INTEGER NOT NULL, started_at INTEGER, finished_at INTEGER, log_path TEXT NOT NULL
      );
      CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      INSERT INTO suggestions (text, author, source, category, status, created_at, updated_at)
        VALUES ('Alter Vorschlag ohne Schlüssel', 'Alt', 'game', 'ui', 'implemented', 1000, 1000);
      INSERT INTO suggestions (text, author, source, category, status, created_at, updated_at)
        VALUES ('Noch einer ohne Schlüssel', 'Alt', 'dashboard', 'bug', 'new', 2000, 2000);
    `);
    db.close();
    return { store: new Store(dataDir), dataDir };
  }

  it('ergänzt die Spalte, ohne alte Zeilen zu verlieren', () => {
    const { store } = legacyStore();
    const all = store.listSuggestions();
    expect(all).toHaveLength(2);
    expect(all.every((s) => s.clientKey === null)).toBe(true);
    expect(all[0].text).toBe('Alter Vorschlag ohne Schlüssel');
    expect(all[0].status).toBe('implemented');
  });

  it('legt den partiellen Index an und lässt alte Zeilen ohne Schlüssel zu', () => {
    const { store } = legacyStore();
    const index = store.db
      .prepare("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'idx_suggestions_client_key'")
      .get() as { sql: string } | undefined;
    expect(index?.sql).toContain('UNIQUE');
    expect(index?.sql).toContain('client_key IS NOT NULL');
    // The two old rows both have NULL, which a plain UNIQUE would have rejected.
    expect(() => store.createSuggestionOnce({ text: 'Neu ohne Schlüssel', author: 'Neu', source: 'game', category: 'ui', canonicalId: null })).not.toThrow();
    expect(store.listSuggestions()).toHaveLength(3);
  });

  it('nimmt in der alten Datenbank Schlüssel an und erkennt Retrys', () => {
    const { store } = legacyStore();
    const first = store.createSuggestionOnce({
      text: 'Aus der Warteschlange', author: 'Spiel', source: 'game', category: 'ui', canonicalId: null,
      clientKey: 'post-migration',
    });
    const second = store.createSuggestionOnce({
      text: 'Aus der Warteschlange', author: 'Spiel', source: 'game', category: 'ui', canonicalId: null,
      clientKey: 'post-migration',
    });
    expect(second.created).toBe(false);
    expect(second.suggestion.id).toBe(first.suggestion.id);
    expect(store.listSuggestions()).toHaveLength(3);
  });

  it('überlebt ein zweites Öffnen derselben Datenbank', () => {
    const { store, dataDir } = legacyStore();
    store.createSuggestionOnce({ text: 'Einmal', author: 'Spiel', source: 'game', category: 'ui', canonicalId: null, clientKey: 'dauerhaft' });
    // Migration must be idempotent: the second open finds the column and the
    // index already there and must not throw "duplicate column".
    const again = new Store(dataDir);
    const res = again.createSuggestionOnce({ text: 'Einmal', author: 'Spiel', source: 'game', category: 'ui', canonicalId: null, clientKey: 'dauerhaft' });
    expect(res.created).toBe(false);
    expect(again.listSuggestions()).toHaveLength(3);
  });
});
