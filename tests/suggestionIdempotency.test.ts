/**
 * `clientKey` idempotency, at the only level where it still exists.
 *
 * The game's offline queue used to resend the same `clientKey` to
 * `POST /api/suggestions` when the first answer was lost, and the server turned
 * that into no second row, no second Discord message and no second
 * `suggestion:new`. That route is gone — a suggestion from the device goes straight
 * to the owner's Telegram chat and never becomes a row here.
 *
 * What did not go with it: the column, the partial unique index, the migration that
 * adds both to an existing database, and `createSuggestionOnce()`/`normalizeClientKey`
 * in the store. A row imported from `backup/dashboard.json` still carries a
 * `clientKey`, so the index still decides who wins a duplicate and the migration
 * still has to run on the owner's database, which is months old and cannot be
 * thrown away and recreated. That is what is tested here.
 */
import { mkdtempSync, rmSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { CLIENT_KEY_MAX, Store, normalizeClientKey } from '../server/db';

const tempDirs: string[] = [];

function tempDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

afterEach(() => {
  // The store handles are never closed here — SQLite in Node has no cheap "close",
  // and `rmSync` under an open connection is the kind of failure that hides the
  // real one. These are temp directories; the OS reclaims them.
  for (const dir of tempDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const text = 'Die Lobby sollte den letzten Gewinn des Tages zeigen';

describe('normalizeClientKey', () => {
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

  it('legt mit einem Schlüssel genau eine Zeile an und melde created', () => {
    const store = new Store(tempDir('singular80-idem-store-'));
    const first = store.createSuggestionOnce(input('sug-2026-09-26-7'));
    expect(first.created).toBe(true);
    expect(first.suggestion.id).toBeGreaterThan(0);
    expect(first.suggestion.clientKey).toBe('sug-2026-09-26-7');
    expect(store.getSuggestion(first.suggestion.id)!.clientKey).toBe('sug-2026-09-26-7');
    expect(store.listSuggestions()).toHaveLength(1);
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

  it('antwortet beim Wiederholen mit dem aktuellen Zustand, nicht mit dem alten', () => {
    // The row read back is the row in the database, so a status change in between is
    // what a retry sees — never the state the first attempt computed.
    const store = new Store(tempDir('singular80-idem-status-'));
    const first = store.createSuggestionOnce(input('k-status')).suggestion;
    store.updateSuggestionStatus(first.id, 'implemented');
    const second = store.createSuggestionOnce(input('k-status'));
    expect(second.created).toBe(false);
    expect(second.suggestion.id).toBe(first.id);
    expect(second.suggestion.status).toBe('implemented');
    expect(store.listSuggestions()).toHaveLength(1);
  });

  it('lässt einen neuen Schlüssel weiterhin einen neuen Vorschlag anlegen', () => {
    const store = new Store(tempDir('singular80-idem-distinct-'));
    const a = store.createSuggestionOnce(input('a')).suggestion;
    const b = store.createSuggestionOnce(input('b')).suggestion;
    expect(b.id).not.toBe(a.id);
    expect(store.listSuggestions()).toHaveLength(2);
  });

  it('lässt viele Vorschläge ohne Schlüssel zu (partieller Index)', () => {
    const store = new Store(tempDir('singular80-idem-null-'));
    for (let i = 0; i < 3; i += 1) store.createSuggestionOnce(input(null));
    store.createSuggestionOnce(input(undefined));
    expect(store.listSuggestions()).toHaveLength(4);
  });

  it('behandelt einen leeren Schlüssel wie einen fehlenden', () => {
    const store = new Store(tempDir('singular80-idem-empty-'));
    const a = store.createSuggestionOnce(input('')).suggestion;
    const b = store.createSuggestionOnce(input('   '));
    expect(b.suggestion.id).not.toBe(a.id);
    expect(a.clientKey).toBeNull();
    expect(b.suggestion.clientKey).toBeNull();
    expect(store.listSuggestions()).toHaveLength(2);
  });

  it('behandelt nur Leerzeichen als Leerraum, nicht als neuen Schlüssel', () => {
    const store = new Store(tempDir('singular80-idem-trim-'));
    const a = store.createSuggestionOnce(input('mit rand')).suggestion;
    const b = store.createSuggestionOnce(input('  mit rand  '));
    expect(b.created).toBe(false);
    expect(b.suggestion.id).toBe(a.id);
    expect(b.suggestion.clientKey).toBe('mit rand');
    expect(store.listSuggestions()).toHaveLength(1);
  });

  it('ignoriert Werte, die keine Zeichenkette sind, ohne Fehler', () => {
    const store = new Store(tempDir('singular80-idem-junk-'));
    for (const bad of [42, true, null, { id: 7 }, ['x'], 1.5]) {
      const res = store.createSuggestionOnce(input(bad));
      // Ignored, not rejected: each is its own suggestion, like a client build that
      // does not know the field.
      expect(res.created).toBe(true);
      expect(res.suggestion.clientKey).toBeNull();
    }
    expect(store.listSuggestions()).toHaveLength(6);
  });

  it('ignoriert einen zu langen Schlüssel, statt ihn zu kürzen', () => {
    const store = new Store(tempDir('singular80-idem-long-'));
    const long = 'k'.repeat(CLIENT_KEY_MAX + 1);
    const a = store.createSuggestionOnce(input(long)).suggestion;
    const b = store.createSuggestionOnce(input(long)).suggestion;
    expect(a.clientKey).toBeNull();
    // Truncating would let two keys with a common 64-char prefix collapse into one
    // row and hand a retry somebody else's suggestion.
    expect(b.id).not.toBe(a.id);
    expect(store.listSuggestions()).toHaveLength(2);
  });

  it('nimmt einen Schlüssel mit genau 64 Zeichen an', () => {
    const store = new Store(tempDir('singular80-idem-max-'));
    const key = 'k'.repeat(CLIENT_KEY_MAX);
    const a = store.createSuggestionOnce(input(key));
    const b = store.createSuggestionOnce(input(key));
    expect(a.suggestion.clientKey).toBe(key);
    expect(b.created).toBe(false);
    expect(b.suggestion.id).toBe(a.suggestion.id);
    expect(store.listSuggestions()).toHaveLength(1);
  });

  it('gewinnt gegen einen zweiten Prozess auf derselben Datei', () => {
    // Two `Store`s on one file stand in for two server processes (or two retries in
    // flight). Only the unique index stops the second; a read-then-write in the
    // route would have inserted a duplicate here.
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
    // The catch only knows the uniqueness conflict. Anything else — a closed
    // database, a broken file — must reach the caller instead of looking like a replay.
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
    // Both old rows have NULL, which a plain UNIQUE would have rejected.
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
    // Migration must be idempotent: the second open must not throw "duplicate column".
    const again = new Store(dataDir);
    const res = again.createSuggestionOnce({ text: 'Einmal', author: 'Spiel', source: 'game', category: 'ui', canonicalId: null, clientKey: 'dauerhaft' });
    expect(res.created).toBe(false);
    expect(again.listSuggestions()).toHaveLength(3);
  });
});
