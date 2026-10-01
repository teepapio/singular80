/**
 * Routes for the runner's new controls: pause, policy, scope layout, run audit
 * and manual retry. Uses `app.inject`, so nothing binds a port.
 */
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, describe, expect, it } from 'vitest';
import { createApp } from '../server/app';
import { Store } from '../server/db';
import { classify } from '../src/shared/sorting';
import type { QueueState, RunRecord, ScopeManifest, SuggestionView } from '../src/shared/types';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const opened: { close: () => Promise<void>; dataDir: string; projectRoot: string }[] = [];
let previousBin: string | undefined;

afterEach(async () => {
  for (const app of opened.splice(0)) {
    await app.close();
    rmSync(app.dataDir, { recursive: true, force: true });
    rmSync(app.projectRoot, { recursive: true, force: true });
  }
  if (previousBin === undefined) delete process.env.OPENCODE_BIN;
  else process.env.OPENCODE_BIN = previousBin;
});

type Method = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

interface Api {
  get: <T>(path: string) => Promise<{ status: number; body: T }>;
  post: <T>(path: string, body?: unknown) => Promise<{ status: number; body: T }>;
  put: <T>(path: string, body: unknown) => Promise<{ status: number; body: T }>;
  close: () => Promise<void>;
  /** The server's own store — the way to seed a suggestion without a route. */
  store: Store;
  dataDir: string;
  projectRoot: string;
}

/**
 * Boots the API with a temp database; `runnerEnabled: false` skips the runner.
 *
 * `OPENCODE_BIN` points at a stub and `projectRoot` at a temp dir: the `implement`
 * route really enqueues a run, and without both it would start a real agent in the
 * real working tree.
 */
async function boot(runnerEnabled = true): Promise<Api> {
  const dataDir = mkdtempSync(join(tmpdir(), 'singular80-api-'));
  const projectRoot = mkdtempSync(join(tmpdir(), 'singular80-api-repo-'));
  const stub = join(projectRoot, 'opencode-stub');
  writeFileSync(stub, '#!/bin/sh\necho \'{"type":"text","part":{"text":"ok"}}\'\nexit 0\n');
  chmodSync(stub, 0o755);
  previousBin = process.env.OPENCODE_BIN;
  process.env.OPENCODE_BIN = stub;
  const app = createApp({
    dataDir,
    contentDir: join(root, 'content'),
    projectRoot,
    distDir: join(root, 'dist-does-not-exist'),
    runnerEnabled,
  });
  await app.ready();
  opened.push({ close: () => app.close(), dataDir, projectRoot });
  const store = (app as unknown as { _singular80: { store: Store } })._singular80.store;
  const call = async <T>(path: string, method: Method, payload?: string): Promise<{ status: number; body: T }> => {
    const res = await app.inject({
      path,
      method,
      ...(payload != null ? { headers: { 'content-type': 'application/json' }, payload } : {}),
    });
    return { status: res.statusCode, body: res.json() as T };
  };
  return {
    get: <T>(path: string) => call<T>(path, 'GET'),
    post: <T>(path: string, body?: unknown) =>
      call<T>(path, 'POST', body === undefined ? undefined : JSON.stringify(body)),
    put: <T>(path: string, body: unknown) => call<T>(path, 'PUT', JSON.stringify(body)),
    close: () => app.close(),
    store,
    dataDir,
    projectRoot,
  };
}

/**
 * A suggestion row, written straight into the store.
 *
 * `POST /api/suggestions` is gone: what a player types goes from the device into
 * the owner's Telegram chat and never becomes a row here, so there is no route left
 * to seed through. The store is the same one the server reads.
 */
function newSuggestion(api: Api, text: string): number {
  return api.store.createSuggestion({
    text,
    author: 'Api-Test',
    source: 'game',
    category: classify(text),
    canonicalId: null,
  }).id;
}

describe('GET /api/runner', () => {
  it('meldet Pause, Politik und leere Schlange', async () => {
    const api = await boot();
    const res = await api.get<QueueState & { runnerEnabled: boolean }>('/api/runner');
    expect(res.status).toBe(200);
    expect(res.body.runnerEnabled).toBe(true);
    expect(res.body.paused).toBe(false);
    expect(res.body.queue).toEqual([]);
    expect(res.body.policy.timeoutMinutes).toBe(45);
    expect(res.body.policy.retryLimit).toBe(1);
    expect(typeof res.body.activeRun).toBe('object');
  });

  it('antwortet auch mit deaktiviertem Runner', async () => {
    const api = await boot(false);
    const res = await api.get<QueueState & { runnerEnabled: boolean }>('/api/runner');
    expect(res.status).toBe(200);
    expect(res.body.runnerEnabled).toBe(false);
    expect(res.body.paused).toBe(false);
  });
});

describe('POST /api/runner/pause', () => {
  it('pausiert und setzt fort', async () => {
    const api = await boot();
    const on = await api.post<QueueState>('/api/runner/pause', { paused: true });
    expect(on.status).toBe(200);
    expect(on.body.paused).toBe(true);
    const state = await api.get<QueueState>('/api/runner');
    expect(state.body.paused).toBe(true);
    const off = await api.post<QueueState>('/api/runner/pause', { paused: false });
    expect(off.body.paused).toBe(false);
  });

  it('lehnt einen unbrauchbaren Wert ab', async () => {
    const api = await boot();
    const res = await api.post<{ error: string }>('/api/runner/pause', { paused: 'ja' });
    expect(res.status).toBe(400);
    expect(res.body.error).toContain('true oder false');
  });

  it('gibt 503 bei deaktiviertem Runner', async () => {
    const api = await boot(false);
    const res = await api.post<{ error: string }>('/api/runner/pause', { paused: true });
    expect(res.status).toBe(503);
  });
});

describe('GET /api/scopes', () => {
  it('liefert das Manifest mit Agenten und Besitz', async () => {
    const api = await boot();
    const res = await api.get<ScopeManifest>('/api/scopes');
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ok');
    const ids = res.body.scopes.map((s) => s.id);
    expect(ids).toContain('tetris');
    expect(ids).toContain('dashboard');
    expect(res.body.scopes.find((s) => s.id === 'meshes')?.own).toContain('godot/assets/meshes/**');
    expect(res.body.sharedFiles).toContain('package.json');
    expect(Array.isArray(res.body.problems)).toBe(true);
  });
});

describe('GET /api/suggestions/:id/scope', () => {
  it('sagt, welcher Scope zu einem Vorschlag gehört', async () => {
    const api = await boot();
    const id = newSuggestion(api, 'Tetris: die Level sollen schneller kommen');
    const res = await api.get<{ suggestion: SuggestionView; scope: { scopes: string[]; reason: string } }>(
      `/api/suggestions/${id}/scope`,
    );
    expect(res.status).toBe(200);
    expect(res.body.scope.scopes[0]).toBe('tetris');
    expect(res.body.scope.reason).toContain('tetris');
  });

  it('gibt 404 für unbekannte Vorschläge', async () => {
    const api = await boot();
    const res = await api.get<{ error: string }>('/api/suggestions/424242/scope');
    expect(res.status).toBe(404);
  });
});

describe('GET /api/runs/:id/scope', () => {
  it('liefert ein Audit für einen bekannten Run', async () => {
    const api = await boot();
    const id = newSuggestion(api, 'Pang: mehr Bälle');
    const started = await api.post<{ run: RunRecord }>(`/api/suggestions/${id}/implement`, {});
    const res = await api.get<{ runId: string; scopes: string[] }>(`/api/runs/${started.body.run.id}/scope`);
    expect(res.status).toBe(200);
    expect(res.body.runId).toBe(started.body.run.id);
    expect(res.body.scopes).toContain('pang');
  });

  it('gibt 404 für unbekannte Runs', async () => {
    const api = await boot();
    const res = await api.get<{ error: string }>('/api/runs/run_gibt_es_nicht/scope');
    expect(res.status).toBe(404);
  });

  it('gibt 503 bei deaktiviertem Runner', async () => {
    const api = await boot(false);
    const res = await api.get<{ error: string }>('/api/runs/x/scope');
    expect(res.status).toBe(503);
  });
});

describe('POST /api/runs/:id/retry', () => {
  it('lehnt das Wiederholen eines unbekannten Runs ab', async () => {
    const api = await boot();
    const res = await api.post<{ error: string }>('/api/runs/run_fehlt/retry', {});
    expect(res.status).toBe(404);
  });

  it('lehnt das Fortsetzen ohne Sitzung ehrlich ab', async () => {
    const api = await boot();
    const id = await newSuggestion(api, 'Siedler: Handelsweg optimieren');
    const started = await api.post<{ run: RunRecord }>(`/api/suggestions/${id}/implement`, {});
    await api.post<{ run: RunRecord }>(`/api/runs/${started.body.run.id}/cancel`, {});
    const res = await api.post<{ error: string }>(`/api/runs/${started.body.run.id}/resume`, {});
    expect(res.status).toBe(409);
    expect(res.body.error).toContain('Wiederholen');
  });

  it('lehnt das Fortsetzen eines laufenden Runs ab', async () => {
    const api = await boot();
    const id = await newSuggestion(api, 'Siedler: Handelsweg optimieren');
    const started = await api.post<{ run: RunRecord }>(`/api/suggestions/${id}/implement`, {});
    const res = await api.post<{ error: string }>(`/api/runs/${started.body.run.id}/resume`, {});
    expect(res.status).toBe(409);
    expect(res.body.error).toContain('nicht abgeschlossen');
  });

  it('gibt 404 für einen unbekannten Run', async () => {
    const api = await boot();
    const res = await api.post<{ error: string }>('/api/runs/run_fehlt/resume', {});
    expect(res.status).toBe(404);
  });

  it('lehnt das Wiederholen eines laufenden Runs ab', async () => {
    const api = await boot();
    const id = newSuggestion(api, 'Siedler: Handelsweg optimieren');
    const started = await api.post<{ run: RunRecord }>(`/api/suggestions/${id}/implement`, {});
    const res = await api.post<{ error: string }>(`/api/runs/${started.body.run.id}/retry`, {});
    expect(res.status).toBe(409);
    expect(res.body.error).toContain('nicht abgeschlossen');
  });
});

describe('Migration einer bestehenden Datenbank', () => {
  it('ergänzt die neuen Run-Spalalten in einer alten Datenbank', () => {
    // A deployment that has been running for weeks has a `runs` table without
    // the policy columns. Opening it must not throw and must not lose rows.
    const dataDir = mkdtempSync(join(tmpdir(), 'singular80-migration-'));
    const db = new DatabaseSync(join(dataDir, 'singular80.db'));
    db.exec(`
      CREATE TABLE suggestions (
        id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, author TEXT NOT NULL DEFAULT 'Anonym',
        source TEXT NOT NULL DEFAULT 'game', category TEXT NOT NULL DEFAULT 'other', status TEXT NOT NULL DEFAULT 'new',
        votes INTEGER NOT NULL DEFAULT 0, canonical_id INTEGER, created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL, discord_message_id TEXT, run_id TEXT
      );
      CREATE TABLE runs (
        id TEXT PRIMARY KEY, suggestion_id INTEGER NOT NULL, status TEXT NOT NULL, session_id TEXT,
        prompt TEXT NOT NULL, exit_code INTEGER, cost REAL, tokens_input INTEGER, tokens_output INTEGER,
        commit_hash TEXT, created_at INTEGER NOT NULL, started_at INTEGER, finished_at INTEGER, log_path TEXT NOT NULL
      );
      CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      INSERT INTO runs (id, suggestion_id, status, prompt, created_at, log_path)
        VALUES ('run_alt', 1, 'failed', 'p', 1, '/tmp/alt.jsonl');
      INSERT INTO settings (key, value) VALUES ('model', 'gpt-alt');
    `);
    db.close();

    const store = new Store(dataDir);
    try {
      const old = store.getRun('run_alt')!;
      // New columns read back as "first attempt, no timeout, no scope", not null.
      expect(old.attempt).toBe(1);
      expect(old.maxAttempts).toBe(1);
      expect(old.timeoutMs).toBe(0);
      expect(old.scopes).toEqual([]);
      expect(old.note).toBeNull();
      // Und die Spalte, mit der "Fortsetzen" erst funktioniert: ein alter Lauf hat
      // keine Sitzung zum Fortsetzen, also `null` und nicht undefined.
      expect(old.resumesSession).toBeNull();
      expect(store.getSettings().model).toBe('gpt-alt');
      expect(store.getQueuePaused()).toBe(false);
    } finally {
      // The handle is closed before the directory goes: a `rmSync` under an open
      // SQLite connection is the kind of failure that hides the real one, and a
      // failing assertion used to skip the cleanup entirely.
      store.db.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});

describe('Runner-Politik in den Einstellungen', () => {
  it('liefert die Vorgabewerte', async () => {
    const api = await boot();
    const res = await api.get<{ runTimeoutMinutes: number; retryLimit: number; retryBackoffSeconds: number }>(
      '/api/settings',
    );
    expect(res.body.runTimeoutMinutes).toBe(45);
    expect(res.body.retryLimit).toBe(1);
    expect(res.body.retryBackoffSeconds).toBe(30);
  });

  it('speichert Zahlen und Zeichenketten', async () => {
    const api = await boot();
    const saved = await api.put<{ runTimeoutMinutes: number; retryLimit: number; retryBackoffSeconds: number }>(
      '/api/settings',
      { runTimeoutMinutes: 12, retryLimit: '3', retryBackoffSeconds: 90 },
    );
    expect(saved.body.runTimeoutMinutes).toBe(12);
    expect(saved.body.retryLimit).toBe(3);
    expect(saved.body.retryBackoffSeconds).toBe(90);
    const read = await api.get<{ runTimeoutMinutes: number; retryLimit: number }>('/api/settings');
    expect(read.body.runTimeoutMinutes).toBe(12);
    expect(read.body.retryLimit).toBe(3);
  });

  it('begrenzt unsinnige Werte', async () => {
    const api = await boot();
    const res = await api.put<{ runTimeoutMinutes: number; retryLimit: number; retryBackoffSeconds: number }>(
      '/api/settings',
      { runTimeoutMinutes: 99_999, retryLimit: 500, retryBackoffSeconds: -20 },
    );
    expect(res.body.runTimeoutMinutes).toBe(1440);
    // Die Obergrenze fuer Wiederholungen ist 20, seit der Besitzer mehr Versuche
    // wollte; 500 wird immer noch abgeschnitten.
    expect(res.body.retryLimit).toBe(20);
    expect(res.body.retryBackoffSeconds).toBe(0);
  });

  it('ignoriert unbrauchbare Typen statt sie zu speichern', async () => {
    const api = await boot();
    await api.put('/api/settings', { runTimeoutMinutes: 20 });
    const res = await api.put<{ runTimeoutMinutes: number }>('/api/settings', { runTimeoutMinutes: 'bald' });
    expect(res.body.runTimeoutMinutes).toBe(20);
  });
});

describe('POST /api/tasks', () => {
  it('legt einen Betreiberauftrag an und stellt ihn sofort in die Schlange', async () => {
    const api = await boot();
    // Pause first so the run cannot start and shift the values under the test.
    await api.post('/api/runner/pause', { paused: true });
    const res = await api.post<{ run: RunRecord; suggestion: SuggestionView }>('/api/tasks', {
      text: 'Pang: die Bälle sollen schneller fliegen',
    });
    expect(res.status).toBe(200);
    // No voting round: starts approved, without a player and without Discord.
    expect(res.body.suggestion.status).toBe('approved');
    expect(res.body.suggestion.source).toBe('operator');
    expect(res.body.suggestion.author).toBe('Betreiber');
    expect(res.body.run.suggestionId).toBe(res.body.suggestion.id);
    expect(res.body.run.status).toBe('queued');
  });

  it('lehnt leere und zu lange Aufträge ab', async () => {
    const api = await boot();
    expect((await api.post<{ error: string }>('/api/tasks', { text: 'ab' })).status).toBe(400);
    expect((await api.post<{ error: string }>('/api/tasks', { text: 'x'.repeat(4001) })).status).toBe(400);
  });

  it('gibt 503 bei deaktiviertem Runner', async () => {
    const api = await boot(false);
    const res = await api.post<{ error: string }>('/api/tasks', { text: 'Mach irgendwas' });
    expect(res.status).toBe(503);
  });
});

describe('PUT /api/settings (Spuren)', () => {
  it('speichert die Zahl der Spuren und begrenzt sie', async () => {
    const api = await boot();
    expect((await api.get<{ maxParallelRuns: number }>('/api/settings')).body.maxParallelRuns).toBe(3);
    const saved = await api.put<{ maxParallelRuns: number }>('/api/settings', { maxParallelRuns: 5 });
    expect(saved.body.maxParallelRuns).toBe(5);
    // 0 lanes would mean "no run ever starts" — the clamp has to prevent that.
    const clamped = await api.put<{ maxParallelRuns: number }>('/api/settings', { maxParallelRuns: 0 });
    expect(clamped.body.maxParallelRuns).toBe(1);
    const high = await api.put<{ maxParallelRuns: number }>('/api/settings', { maxParallelRuns: 99 });
    expect(high.body.maxParallelRuns).toBe(8);
  });
});

describe('Backup im Repository', () => {
  it('schreibt die Historie ins Repo und meldet sie identisch zurück', async () => {
    const api = await boot();
    newSuggestion(api, 'Tetris: mehr Bälle am Stück');
    const written = await api.post<{ ok: boolean; path: string; counts: { suggestions: number } }>(
      '/api/backup/write',
      {},
    );
    expect(written.body.ok).toBe(true);
    expect(written.body.path).toBe('backup/dashboard.json');
    expect(written.body.counts.suggestions).toBe(1);
    const status = await api.get<{ exists: boolean; headline: string }>('/api/backup');
    expect(status.body.exists).toBe(true);
    expect(status.body.headline).toContain('identisch');
  });

  it('liest die Datei zurück, ohne doppelt anzulegen', async () => {
    const api = await boot();
    newSuggestion(api, 'Poker: Chips anders verteilen');
    await api.post('/api/backup/write', {});
    const first = await api.post<{ report: { suggestionsAdded: number } }>('/api/backup/read', {});
    expect(first.body.report.suggestionsAdded).toBe(0);
    const second = await api.post<{ report: { suggestionsAdded: number } }>('/api/backup/read', {});
    expect(second.body.report.suggestionsAdded).toBe(0);
  });

  it('gibt 404, wenn noch keine Datei da ist', async () => {
    const api = await boot();
    const res = await api.post<{ error: string }>('/api/backup/read', {});
    expect(res.status).toBe(404);
    expect(res.body.error).toContain('backup/dashboard.json');
  });

  it('lehnt eine kaputte Datei ab, statt sie zu mischen', async () => {
    const api = await boot();
    await api.post('/api/backup/write', {});
    writeFileSync(join(api.projectRoot, 'backup', 'dashboard.json'), '{ kaputt');
    const res = await api.post<{ error: string }>('/api/backup/read', {});
    expect(res.status).toBe(400);
    // The status says the same, so the panel cannot show "all fine".
    const status = await api.get<{ error: string | null }>('/api/backup');
    expect(status.body.error).toContain('gültiges JSON');
  });
});
