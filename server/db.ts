import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import type { RunRecord, RunStatus, Settings, Suggestion, SuggestionStatus } from '../src/shared/types';

export const DEFAULT_SETTINGS: Settings = {
  discordWebhook: '',
  model: '',
  extraInstructions: '',
  autoApprove: false,
  autoApproveScore: 25,
  // 45 minutes: long enough for a godot import plus the scoped test run, short
  // enough that a hung agent does not block the queue over a weekend.
  runTimeoutMinutes: 45,
  retryLimit: 1,
  retryBackoffSeconds: 30,
};

/** Upper bounds for the runner policy, so one bad request cannot stop every run. */
export const SETTINGS_BOUNDS = {
  runTimeoutMinutes: { min: 0, max: 1440 },
  retryLimit: { min: 0, max: 5 },
  retryBackoffSeconds: { min: 0, max: 3600 },
} as const;

export type PolicyKey = keyof typeof SETTINGS_BOUNDS;

interface SuggestionRow {
  id: number;
  text: string;
  author: string;
  source: string;
  category: string;
  status: string;
  votes: number;
  canonical_id: number | null;
  created_at: number;
  updated_at: number;
  discord_message_id: string | null;
  run_id: string | null;
  parent_id: number | null;
  client_key: string | null;
}

interface RunRow {
  id: string;
  suggestion_id: number;
  status: string;
  session_id: string | null;
  prompt: string;
  exit_code: number | null;
  cost: number | null;
  tokens_input: number | null;
  tokens_output: number | null;
  commit_hash: string | null;
  result_summary: string | null;
  created_at: number;
  started_at: number | null;
  finished_at: number | null;
  log_path: string;
  attempt: number | null;
  max_attempts: number | null;
  retry_of: string | null;
  not_before: number | null;
  timeout_ms: number | null;
  scope: string | null;
  note: string | null;
  scope_issues: string | null;
}

function rowToSuggestion(row: SuggestionRow): Suggestion {
  return {
    id: row.id,
    text: row.text,
    author: row.author,
    source: row.source,
    category: row.category as Suggestion['category'],
    status: row.status as SuggestionStatus,
    votes: row.votes,
    canonicalId: row.canonical_id,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    discordMessageId: row.discord_message_id,
    runId: row.run_id,
    parentId: row.parent_id ?? null,
    clientKey: row.client_key ?? null,
  };
}

function rowToRun(row: RunRow): RunRecord {
  const scopes = (row.scope ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  return {
    id: row.id,
    suggestionId: row.suggestion_id,
    status: row.status as RunStatus,
    sessionId: row.session_id,
    prompt: row.prompt,
    exitCode: row.exit_code,
    cost: row.cost,
    tokensInput: row.tokens_input,
    tokensOutput: row.tokens_output,
    commitHash: row.commit_hash,
    resultSummary: row.result_summary ?? '',
    createdAt: row.created_at,
    startedAt: row.started_at,
    finishedAt: row.finished_at,
    logPath: row.log_path,
    attempt: row.attempt ?? 1,
    maxAttempts: row.max_attempts ?? 1,
    retryOf: row.retry_of ?? null,
    notBefore: row.not_before ?? null,
    timeoutMs: row.timeout_ms ?? 0,
    scopes,
    scope: scopes[0] ?? null,
    note: row.note ?? null,
    scopeIssues: row.scope_issues ?? null,
  };
}

export interface CreateSuggestionInput {
  text: string;
  author: string;
  source: string;
  category: string;
  canonicalId: number | null;
  status?: SuggestionStatus;
  parentId?: number | null;
  /** Idempotency key of the client, see `normalizeClientKey`. */
  clientKey?: unknown;
}

export interface CreateSuggestionResult {
  suggestion: Suggestion;
  /** false = a suggestion with this `clientKey` already existed (an offline retry). */
  created: boolean;
}

/** Obergrenze für `clientKey` — Teil des Vertrags mit der Warteschlange im Spiel. */
export const CLIENT_KEY_MAX = 64;

/**
 * Macht den `clientKey` eines Vorschlag-Requests benutzbar — oder `null` für
 * „kein Schlüssel".
 *
 * Der Schlüssel bleibt dabei opak; der Server speichert ihn nur und erkennt
 * daran einen Retry. Alles, was keine brauchbare Zeichenkette ist, zählt als
 * *kein* Schlüssel: ein kaputter Request verhält sich damit exakt wie ein
 * älterer Client, der das Feld gar nicht kennt — kein 500, kein 400, einfach
 * ein normaler neuer Vorschlag.
 *
 * Ein zu langer Schlüssel wird bewusst verworfen und nicht gekürzt. Zwei
 * verschiedene Schlüssel mit denselben ersten 64 Zeichen landeten sonst in
 * derselben Zeile, und ein Retry bekäme den Vorschlag eines Fremden zu sehen —
 * eine doppelte Zeile ist das alte Verhalten und das kleinere Problem.
 */
export function normalizeClientKey(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  if (trimmed.length === 0 || trimmed.length > CLIENT_KEY_MAX) return null;
  return trimmed;
}

export class Store {
  readonly db: DatabaseSync;
  readonly dataDir: string;

  constructor(dataDir: string) {
    this.dataDir = dataDir;
    mkdirSync(dataDir, { recursive: true });
    mkdirSync(join(dataDir, 'runs'), { recursive: true });
    const file = join(dataDir, 'singular80.db');
    mkdirSync(dirname(file), { recursive: true });
    this.db = new DatabaseSync(file);
    this.db.exec('PRAGMA journal_mode = WAL;');
    this.migrate();
  }

  private migrate() {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS suggestions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text TEXT NOT NULL,
        author TEXT NOT NULL DEFAULT 'Anonym',
        source TEXT NOT NULL DEFAULT 'game',
        category TEXT NOT NULL DEFAULT 'other',
        status TEXT NOT NULL DEFAULT 'new',
        votes INTEGER NOT NULL DEFAULT 0,
        canonical_id INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        discord_message_id TEXT,
        run_id TEXT,
        parent_id INTEGER
      );
      CREATE INDEX IF NOT EXISTS idx_suggestions_created ON suggestions(created_at);
      CREATE TABLE IF NOT EXISTS votes (
        suggestion_id INTEGER NOT NULL,
        voter_id TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (suggestion_id, voter_id)
      );
      CREATE TABLE IF NOT EXISTS runs (
        id TEXT PRIMARY KEY,
        suggestion_id INTEGER NOT NULL,
        status TEXT NOT NULL,
        session_id TEXT,
        prompt TEXT NOT NULL,
        exit_code INTEGER,
        cost REAL,
        tokens_input INTEGER,
        tokens_output INTEGER,
        commit_hash TEXT,
        result_summary TEXT,
        created_at INTEGER NOT NULL,
        started_at INTEGER,
        finished_at INTEGER,
        log_path TEXT NOT NULL,
        attempt INTEGER NOT NULL DEFAULT 1,
        max_attempts INTEGER NOT NULL DEFAULT 1,
        retry_of TEXT,
        not_before INTEGER,
        timeout_ms INTEGER NOT NULL DEFAULT 0,
        scope TEXT,
        note TEXT,
        scope_issues TEXT
      );
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    `);
    // Older databases predate the `result_summary` column.
    try {
      this.db.exec('ALTER TABLE runs ADD COLUMN result_summary TEXT');
    } catch {
      /* column already exists */
    }
    // Older databases predate the `parent_id` column (split sub-tasks).
    try {
      this.db.exec('ALTER TABLE suggestions ADD COLUMN parent_id INTEGER');
    } catch {
      /* column already exists */
    }
    // Offline queue of the game: the client retries a suggestion with the same
    // `clientKey` when the first response got lost, and the retry must not
    // become a second row. Additive and nullable, so old rows keep reading as
    // "no key" and stay valid.
    try {
      this.db.exec('ALTER TABLE suggestions ADD COLUMN client_key TEXT');
    } catch (err) {
      if (!/duplicate column name/i.test((err as Error).message)) throw err;
    }
    // The index is the actual idempotency enforcement: it also holds when two
    // retries arrive at the same moment, or when a second process writes to the
    // same file — a read-then-write in the route cannot promise that. Partial on
    // purpose: a plain UNIQUE would allow only *one* suggestion without a key
    // ever (SQLite counts NULLs as equal), and almost every suggestion — the
    // dashboard, older client builds, split sub-tasks — still has none.
    this.db.exec(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_suggestions_client_key ON suggestions(client_key) WHERE client_key IS NOT NULL',
    );
    // Runner policy: retry attempts, hard timeout, scope bookkeeping. Every
    // column is additive and nullable/defaulted, so an old database keeps
    // working and old runs simply read back as "first attempt, no timeout".
    for (const ddl of [
      'ALTER TABLE runs ADD COLUMN attempt INTEGER NOT NULL DEFAULT 1',
      'ALTER TABLE runs ADD COLUMN max_attempts INTEGER NOT NULL DEFAULT 1',
      'ALTER TABLE runs ADD COLUMN retry_of TEXT',
      'ALTER TABLE runs ADD COLUMN not_before INTEGER',
      'ALTER TABLE runs ADD COLUMN timeout_ms INTEGER NOT NULL DEFAULT 0',
      'ALTER TABLE runs ADD COLUMN scope TEXT',
      'ALTER TABLE runs ADD COLUMN note TEXT',
      'ALTER TABLE runs ADD COLUMN scope_issues TEXT',
    ]) {
      try {
        this.db.exec(ddl);
      } catch (err) {
        // Only "duplicate column" is acceptable here; anything else means the
        // database is broken and the caller has to see it.
        if (!/duplicate column name/i.test((err as Error).message)) throw err;
      }
    }
  }

  createSuggestion(input: CreateSuggestionInput): Suggestion {
    return this.createSuggestionOnce(input).suggestion;
  }

  /**
   * Legt einen Vorschlag an — oder liefert den, den es zu `clientKey` schon
   * gibt.
   *
   * Die Idempotenz sitzt hier und nicht in der Route: ein „erst lesen, dann
   * schreiben" im Request erkennt zwei *gleichzeitig* eingetroffene Retrys
   * nicht, weil beide noch nichts sehen. Der partielle UNIQUE-Index entscheidet
   * stattdessen, welcher Versuch gewinnt; der Verlierer fängt die Verletzung und
   * liest die Gewinnerzeile zurück. Damit ist auch der Fall abgedeckt, in dem
   * ein zweiter Prozess auf derselben Datei schneller war.
   *
   * `created` ist die Antwort auf die einzige Frage, die die Route stellen muss:
   * darf ich Discord informieren und ein `suggestion:new` senden?
   */
  createSuggestionOnce(input: CreateSuggestionInput): CreateSuggestionResult {
    const clientKey = normalizeClientKey(input.clientKey);
    const now = Date.now();
    const stmt = this.db.prepare(
      `INSERT INTO suggestions (text, author, source, category, status, votes, canonical_id, created_at, updated_at, parent_id, client_key)
       VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?)`,
    );
    try {
      const result = stmt.run(
        input.text,
        input.author,
        input.source,
        input.category,
        input.status ?? 'new',
        input.canonicalId,
        now,
        now,
        input.parentId ?? null,
        clientKey,
      );
      return { suggestion: this.getSuggestion(Number(result.lastInsertRowid))!, created: true };
    } catch (err) {
      // Nur eine Eindeutigkeitsverletzung auf dem Schlüssel ist ein Retry.
      // Alles andere — eine kaputte Datenbank, eine fehlende Spalte — muss
      // unverändert nach außen durch.
      if (!clientKey || !isUniqueViolation(err)) throw err;
      const existing = this.getSuggestionByClientKey(clientKey);
      if (!existing) throw err;
      return { suggestion: existing, created: false };
    }
  }

  getSuggestion(id: number): Suggestion | null {
    const row = this.db.prepare('SELECT * FROM suggestions WHERE id = ?').get(id) as
      | SuggestionRow
      | undefined;
    return row ? rowToSuggestion(row) : null;
  }

  getSuggestionByClientKey(clientKey: string): Suggestion | null {
    const row = this.db
      .prepare('SELECT * FROM suggestions WHERE client_key = ?')
      .get(clientKey) as SuggestionRow | undefined;
    return row ? rowToSuggestion(row) : null;
  }

  listSuggestions(): Suggestion[] {
    const rows = this.db.prepare('SELECT * FROM suggestions ORDER BY created_at ASC, id ASC').all() as unknown as SuggestionRow[];
    return rows.map(rowToSuggestion);
  }

  updateSuggestionStatus(id: number, status: SuggestionStatus): Suggestion | null {
    this.db
      .prepare('UPDATE suggestions SET status = ?, updated_at = ? WHERE id = ?')
      .run(status, Date.now(), id);
    return this.getSuggestion(id);
  }

  setSuggestionDiscordMessage(id: number, messageId: string | null) {
    this.db
      .prepare('UPDATE suggestions SET discord_message_id = ?, updated_at = ? WHERE id = ?')
      .run(messageId, Date.now(), id);
  }

  setSuggestionRun(id: number, runId: string | null) {
    this.db
      .prepare('UPDATE suggestions SET run_id = ?, updated_at = ? WHERE id = ?')
      .run(runId, Date.now(), id);
  }

  addVote(suggestionId: number, voterId: string): { votes: number; changed: boolean } {
    const inserted = this.db
      .prepare('INSERT OR IGNORE INTO votes (suggestion_id, voter_id, created_at) VALUES (?, ?, ?)')
      .run(suggestionId, voterId, Date.now());
    if (Number(inserted.changes) > 0) {
      this.db
        .prepare('UPDATE suggestions SET votes = votes + 1, updated_at = ? WHERE id = ?')
        .run(Date.now(), suggestionId);
    }
    const row = this.db
      .prepare('SELECT votes FROM suggestions WHERE id = ?')
      .get(suggestionId) as { votes: number } | undefined;
    return { votes: row?.votes ?? 0, changed: Number(inserted.changes) > 0 };
  }

  createRun(run: RunRecord) {
    this.db
      .prepare(
        `INSERT INTO runs (id, suggestion_id, status, session_id, prompt, exit_code, cost, tokens_input, tokens_output, commit_hash, result_summary, created_at, started_at, finished_at, log_path, attempt, max_attempts, retry_of, not_before, timeout_ms, scope, note, scope_issues)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        run.id,
        run.suggestionId,
        run.status,
        run.sessionId,
        run.prompt,
        run.exitCode,
        run.cost,
        run.tokensInput,
        run.tokensOutput,
        run.commitHash,
        run.resultSummary,
        run.createdAt,
        run.startedAt,
        run.finishedAt,
        run.logPath,
        run.attempt,
        run.maxAttempts,
        run.retryOf,
        run.notBefore,
        run.timeoutMs,
        run.scopes.join(','),
        run.note,
        run.scopeIssues,
      );
  }

  updateRun(run: RunRecord) {
    this.db
      .prepare(
        `UPDATE runs SET status = ?, session_id = ?, exit_code = ?, cost = ?, tokens_input = ?, tokens_output = ?, commit_hash = ?, result_summary = ?, started_at = ?, finished_at = ?, attempt = ?, max_attempts = ?, retry_of = ?, not_before = ?, timeout_ms = ?, scope = ?, note = ?, scope_issues = ?
         WHERE id = ?`,
      )
      .run(
        run.status,
        run.sessionId,
        run.exitCode,
        run.cost,
        run.tokensInput,
        run.tokensOutput,
        run.commitHash,
        run.resultSummary,
        run.startedAt,
        run.finishedAt,
        run.attempt,
        run.maxAttempts,
        run.retryOf,
        run.notBefore,
        run.timeoutMs,
        run.scopes.join(','),
        run.note,
        run.scopeIssues,
        run.id,
      );
  }

  getRun(id: string): RunRecord | null {
    const row = this.db.prepare('SELECT * FROM runs WHERE id = ?').get(id) as RunRow | undefined;
    return row ? rowToRun(row) : null;
  }

  listRuns(limit = 50): RunRecord[] {
    const rows = this.db
      .prepare('SELECT * FROM runs ORDER BY created_at DESC LIMIT ?')
      .all(limit) as unknown as RunRow[];
    return rows.map(rowToRun);
  }

  getSettings(): Settings {
    const rows = this.db.prepare('SELECT key, value FROM settings').all() as unknown as {
      key: string;
      value: string;
    }[];
    const map = new Map(rows.map((r) => [r.key, r.value]));
    const raw = Object.fromEntries(map);
    return {
      discordWebhook: raw.discordWebhook ?? DEFAULT_SETTINGS.discordWebhook,
      model: raw.model ?? DEFAULT_SETTINGS.model,
      extraInstructions: raw.extraInstructions ?? DEFAULT_SETTINGS.extraInstructions,
      autoApprove: raw.autoApprove ? raw.autoApprove === 'true' : DEFAULT_SETTINGS.autoApprove,
      autoApproveScore: raw.autoApproveScore
        ? Number(raw.autoApproveScore)
        : DEFAULT_SETTINGS.autoApproveScore,
      runTimeoutMinutes: numberSetting(
        raw.runTimeoutMinutes,
        DEFAULT_SETTINGS.runTimeoutMinutes,
        SETTINGS_BOUNDS.runTimeoutMinutes,
      ),
      retryLimit: numberSetting(
        raw.retryLimit,
        DEFAULT_SETTINGS.retryLimit,
        SETTINGS_BOUNDS.retryLimit,
      ),
      retryBackoffSeconds: numberSetting(
        raw.retryBackoffSeconds,
        DEFAULT_SETTINGS.retryBackoffSeconds,
        SETTINGS_BOUNDS.retryBackoffSeconds,
      ),
    };
  }

  /**
   * The pause flag lives in the settings table and not in the runner's memory:
   * the queue is rebuilt from the database after a restart, and an operator who
   * paused the queue before a deploy expects it to still be paused afterwards.
   */
  getQueuePaused(): boolean {
    const row = this.db.prepare('SELECT value FROM settings WHERE key = ?').get('queuePaused') as
      | { value: string }
      | undefined;
    return row?.value === 'true';
  }

  setQueuePaused(paused: boolean): boolean {
    this.db
      .prepare(
        'INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      )
      .run('queuePaused', paused ? 'true' : 'false');
    return paused;
  }

  saveSettings(patch: Partial<Settings>): Settings {
    const stmt = this.db.prepare(
      'INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
    );
    for (const [key, value] of Object.entries(patch)) {
      if (value === undefined) continue;
      // Policy numbers are clamped on the way in: one bad request must not be
      // able to disable the timeout or create an endless retry loop.
      const bounds = SETTINGS_BOUNDS[key as PolicyKey];
      const stored = bounds && typeof value === 'number' ? clamp(value, bounds.min, bounds.max) : value;
      stmt.run(key, String(stored));
    }
    return this.getSettings();
  }
}

/** SQLite meldet einen verletzten UNIQUE-Index als SQLITE_CONSTRAINT_UNIQUE (2067). */
function isUniqueViolation(err: unknown): boolean {
  const sqlite = err as { errcode?: number; message?: string } | null;
  return sqlite?.errcode === 2067 || /UNIQUE constraint failed/i.test(sqlite?.message ?? '');
}

function clamp(value: number, min: number, max: number): number {
  if (!Number.isFinite(value)) return min;
  return Math.min(max, Math.max(min, value));
}

function numberSetting(
  raw: string | undefined,
  fallback: number,
  bounds: { min: number; max: number },
): number {
  if (raw === undefined) return fallback;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) return fallback;
  return clamp(parsed, bounds.min, bounds.max);
}
