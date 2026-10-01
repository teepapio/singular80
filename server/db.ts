import { DatabaseSync } from 'node:sqlite';
import { createHash } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import type {
  CheckRecord,
  RunRecord,
  RunStatus,
  Settings,
  Suggestion,
  SuggestionStatus,
} from '../src/shared/types';

export const DEFAULT_SETTINGS: Settings = {
  discordWebhook: '',
  model: '',
  extraInstructions: '',
  // 45 minutes: long enough for a godot import plus the scoped test run, short
  // enough that a hung agent does not block the queue over a weekend.
  runTimeoutMinutes: 45,
  retryLimit: 1,
  retryBackoffSeconds: 30,
  // Three lanes: enough to work on three different games at once, few enough
  // that the agents do not fight over CPU, disk and the shared git index.
  maxParallelRuns: 3,
};

/** Upper bounds for the runner policy, so one bad request cannot stop every run. */
export const SETTINGS_BOUNDS = {
  runTimeoutMinutes: { min: 0, max: 1440 },
  // 20, nicht 5: der Besitzer will öfter wiederholen lassen. Die Wartezeit wächst
  // ohnehin (doppelt pro Versuch, gedeckelt bei `MAX_BACKOFF_MS`), also ist die
  // Zahl hier eine Obergrenze und kein Versprechen, dass Versuch 20 noch etwas
  // bringt — die Deckel sind das, was einen Endloslauf verhindert.
  retryLimit: { min: 0, max: 20 },
  retryBackoffSeconds: { min: 0, max: 3600 },
  // 1 is the old serial queue and is always allowed; the ceiling is a machine
  // limit, not a taste question — every lane is a full opencode session.
  maxParallelRuns: { min: 1, max: 8 },
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
  telegram_message_id: string | null;
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
  worktree_path: string | null;
  worktree_branch: string | null;
  lane: number | null;
  resumes_session: string | null;
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

interface CheckRow {
  id: string;
  spec_id: string;
  kind: string;
  probe: string;
  status: string;
  title: string;
  scope: string | null;
  targets: string | null;
  limits: string | null;
  created_at: number;
  started_at: number | null;
  finished_at: number | null;
  counts: string | null;
  findings: string | null;
  summary: string | null;
  promoted_suggestion_id: number | null;
  log_path: string;
  note: string | null;
}

/** JSON columns are written by this class alone, so a parse failure is a bug, not input. */
function parseJson<T>(raw: string | null, fallback: T): T {
  if (raw === null) return fallback;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

function rowToCheck(row: CheckRow): CheckRecord {
  return {
    id: row.id,
    specId: row.spec_id,
    kind: row.kind as CheckRecord['kind'],
    probe: row.probe as CheckRecord['probe'],
    status: row.status as CheckRecord['status'],
    title: row.title,
    scope: parseJson<string[]>(row.scope, []),
    targets: parseJson<string[]>(row.targets, []),
    limits: parseJson<CheckRecord['limits']>(row.limits, null),
    createdAt: row.created_at,
    startedAt: row.started_at,
    finishedAt: row.finished_at,
    counts: parseJson(row.counts, { fail: 0, warn: 0, info: 0 }),
    findings: parseJson(row.findings, []),
    summary: row.summary ?? '',
    promotedSuggestionId: row.promoted_suggestion_id,
    logPath: row.log_path,
    note: row.note,
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
    lane: row.lane ?? null,
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
    worktreePath: row.worktree_path ?? null,
    worktreeBranch: row.worktree_branch ?? null,
    resumesSession: row.resumes_session ?? null,
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

/** Upper bound for `clientKey` — part of the contract with the in-game queue. */
export const CLIENT_KEY_MAX = 64;

/**
 * Makes a request's `clientKey` usable, or `null` for "no key".
 *
 * The key stays opaque; the server only stores it and recognizes a retry by it.
 * Anything that is not a usable string counts as *no* key, so a broken request
 * behaves exactly like an older client that does not know the field — no 500, no
 * 400, just an ordinary new suggestion.
 *
 * An over-long key is deliberately dropped, not truncated: two different keys
 * with the same first 64 characters would land in the same row, and a retry
 * would see someone else's suggestion. A duplicate row is the old behaviour and
 * the smaller problem.
 */
export function normalizeClientKey(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  if (trimmed.length === 0 || trimmed.length > CLIENT_KEY_MAX) return null;
  return trimmed;
}

/**
 * A voter id as it is stored: sha256, truncated to 16 hex characters.
 *
 * `voterId` identifies a device, and it travels straight into
 * `backup/dashboard.json` — a file that belongs in a **public** repository. Read
 * verbatim, that file answers a question nobody should be able to ask: which
 * suggestions came from the same device. A hash keeps the two properties the
 * column needs — equality and the (suggestion_id, voter_id) primary key — and
 * gives up the part that makes it useful for correlation.
 *
 * Hashing happens here, once, at the edges: `addVote` and `importVotes` write
 * the hashed form, and `listVotes` — the only way the backup gets a voter — hands
 * it out. Live database and repository file therefore agree by construction.
 *
 * Already-hashed values pass through unchanged. That is what makes a merge of an
 * older backup idempotent: a file written before this change still carries raw
 * ids and gets hashed on the way in, and a file written after it carries hashes
 * that must not be hashed a second time into a different string.
 */
export function hashVoterId(raw: string): string {
  const value = (raw ?? '').trim();
  if (value === '') return '';
  if (/^[0-9a-f]{16}$/.test(value)) return value;
  return createHash('sha256').update(value).digest('hex').slice(0, 16);
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

  /**
   * Runs `fn` in one transaction, and rolls it back if it throws.
   *
   * SQLite gives each statement atomicity on its own; what it does not give is
   * atomicity *between* statements. A delete that first removes the votes and
   * then fails on the run rows leaves a suggestion that says it has two votes and
   * a row of one, and no way back short of a backup. Synchronous by design: this
   * is `node:sqlite`, so there is nothing to await inside the callback.
   */
  tx<T>(fn: () => T): T {
    this.db.exec('BEGIN IMMEDIATE');
    let result: T;
    try {
      result = fn();
    } catch (err) {
      // A rollback can itself fail (a closed database, a nested transaction that
      // was never committed). The original error is the one worth reporting.
      try {
        this.db.exec('ROLLBACK');
      } catch {
        /* the original error carries the news */
      }
      throw err;
    }
    this.db.exec('COMMIT');
    return result;
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
        telegram_message_id TEXT,
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
      -- The deployed-version check queue. Deliberately its own table instead of
      -- a "kind" column on "runs": "runs" is wired to suggestions, Discord, the
      -- dashboard and the restart recovery, and a check is not a suggestion. A
      -- bug in one queue must not be able to take the other down.
      CREATE TABLE IF NOT EXISTS checks (
        id TEXT PRIMARY KEY,
        spec_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        probe TEXT NOT NULL,
        status TEXT NOT NULL,
        title TEXT NOT NULL,
        scope TEXT,
        targets TEXT,
        limits TEXT,
        created_at INTEGER NOT NULL,
        started_at INTEGER,
        finished_at INTEGER,
        counts TEXT,
        findings TEXT,
        summary TEXT,
        promoted_suggestion_id INTEGER,
        log_path TEXT NOT NULL,
        note TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_checks_created ON checks(created_at);
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
    // The Telegram message carrying this suggestion, so the outcome is written
    // *into* that message instead of appended as another one. The chat then
    // holds one line per task instead of growing with every status change.
    try {
      this.db.exec('ALTER TABLE suggestions ADD COLUMN telegram_message_id TEXT');
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
    // Both columns are read on nearly every dashboard request: `canonical_id`
    // groups the cluster for scoring, filtering and the scope preview, and
    // `suggestion_id` is how a single suggestion's run history is fetched. Both
    // were full table scans over every suggestion and every run ever written.
    this.db.exec('CREATE INDEX IF NOT EXISTS idx_suggestions_canonical ON suggestions(canonical_id)');
    this.db.exec('CREATE INDEX IF NOT EXISTS idx_runs_suggestion ON runs(suggestion_id)');
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
      // The lane a run occupies. Nullable on purpose: a queued run has no lane
      // yet, and a run from before parallel queues existed reads back as null
      // rather than pretending it was in slot 1.
      'ALTER TABLE runs ADD COLUMN lane INTEGER',
      // Where an isolated run works, and which branch it commits to. Both null
      // for a run in the shared tree, which is the default and what a database
      // from before worktrees existed reads back as.
      'ALTER TABLE runs ADD COLUMN worktree_path TEXT',
      'ALTER TABLE runs ADD COLUMN worktree_branch TEXT',
      'ALTER TABLE runs ADD COLUMN resumes_session TEXT',
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
   * Creates a suggestion, or returns the one that already exists for `clientKey`.
   *
   * The idempotency lives here and not in the route: a read-then-write in the
   * request misses two retries that arrive *simultaneously*, because neither sees
   * anything yet. The partial unique index decides the winner instead; the loser
   * catches the violation and reads the winning row back. That also covers the
   * case where a second process was faster on the same file.
   *
   * `created` answers the only question the route has to ask: may I notify Discord
   * and emit a `suggestion:new`?
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
      // Only a uniqueness violation on the key is a retry. Anything else — a
      // broken database, a missing column — has to pass through unchanged.
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

  /**
   * Deletes a suggestion and its traces: votes and runs belong to it, and without
   * this they would leave rows whose suggestion no longer exists.
   *
   * Two things are **not** deleted, because they are work of their own: children
   * from a split (`parent_id`) and the remaining members of a cluster. Children
   * are reparented to `NULL` and the cluster gets a new leading suggestion —
   * otherwise the dashboard would show entries whose number nobody ever saw.
   *
   * Returns `false` if the suggestion does not exist, so the route answers 404
   * instead of 500.
   */
  deleteSuggestion(id: number): boolean {
    // One transaction, read included: the read decides *what* is deleted, so it
    // belongs to the same unit of work. Half of this used to be enough to leave
    // a cluster pointing at a suggestion that is already gone.
    return this.tx(() => {
      const target = this.getSuggestion(id);
      if (!target) return false;
      const canonical = target.canonicalId ?? id;
      this.db.prepare('DELETE FROM votes WHERE suggestion_id = ?').run(id);
      this.db.prepare('DELETE FROM runs WHERE suggestion_id = ?').run(id);
      this.db.prepare('UPDATE suggestions SET parent_id = NULL WHERE parent_id = ?').run(id);
      const siblings = this.db
        .prepare('SELECT id FROM suggestions WHERE (canonical_id = ? OR id = ?) AND id != ? ORDER BY id')
        .all(canonical, canonical, id) as { id: number }[];
      if (siblings.length) {
        const heir = siblings[0].id;
        this.db.prepare('UPDATE suggestions SET canonical_id = ? WHERE id = ?').run(heir, heir);
        this.db
          .prepare('UPDATE suggestions SET canonical_id = ? WHERE canonical_id = ?')
          .run(heir, canonical);
      }
      this.db.prepare('DELETE FROM suggestions WHERE id = ?').run(id);
      return true;
    });
  }

  /**
   * The Telegram message that carries a suggestion, so the outcome can be written
   * into that message instead of appended as another one.
   *
   * Kept out of the shared `Suggestion` type on purpose: it is a detail of this
   * machine's chat, not a property of the idea, and `src/shared/` is not ours to
   * change. The repository backup therefore does not carry it either, and a
   * suggestion re-announced on another machine gets a new message.
   */
  getSuggestionTelegramMessage(id: number): string | null {
    const row = this.db.prepare('SELECT telegram_message_id FROM suggestions WHERE id = ?').get(id) as
      | { telegram_message_id: string | null }
      | undefined;
    return row?.telegram_message_id ?? null;
  }

  setSuggestionTelegramMessage(id: number, messageId: string | null) {
    this.db
      .prepare('UPDATE suggestions SET telegram_message_id = ?, updated_at = ? WHERE id = ?')
      .run(messageId, Date.now(), id);
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

  /**
   * Counts one vote. `changed` is false for a repeat from the same voter — the
   * primary key decides, and the counter follows the table instead of being
   * incremented blindly.
   *
   * The insert and the counter update are one transaction: a failure between
   * them would leave a vote in the table that the suggestion's counter does not
   * know about, and the dashboard would show a number one too low forever.
   */
  addVote(suggestionId: number, voterId: string): { votes: number; changed: boolean } {
    const voter = hashVoterId(voterId);
    return this.tx(() => {
      const inserted = this.db
        .prepare('INSERT OR IGNORE INTO votes (suggestion_id, voter_id, created_at) VALUES (?, ?, ?)')
        .run(suggestionId, voter, Date.now());
      const changed = Number(inserted.changes) > 0;
      if (changed) {
        this.db
          .prepare('UPDATE suggestions SET votes = votes + 1, updated_at = ? WHERE id = ?')
          .run(Date.now(), suggestionId);
      }
      const row = this.db
        .prepare('SELECT votes FROM suggestions WHERE id = ?')
        .get(suggestionId) as { votes: number } | undefined;
      return { votes: row?.votes ?? 0, changed };
    });
  }

  /** Every vote, oldest first. The backup needs them: a vote count alone cannot
   * tell "nobody voted" from "the voters are lost", and only the second one is
   * worth restoring.
   *
   * The ids come out hashed (`hashVoterId`) even when the row still holds an old
   * raw value, so a file written from an old database cannot leak one either. */
  listVotes(): { suggestionId: number; voterId: string; createdAt: number }[] {
    const rows = this.db
      .prepare('SELECT suggestion_id, voter_id, created_at FROM votes ORDER BY suggestion_id ASC, voter_id ASC')
      .all() as unknown as { suggestion_id: number; voter_id: string; created_at: number }[];
    return rows.map((r) => ({
      suggestionId: r.suggestion_id,
      voterId: hashVoterId(r.voter_id),
      createdAt: r.created_at,
    }));
  }

  /**
   * Inserts a suggestion under its *existing* id, or changes nothing.
   *
   * This exists for the repository backup, where the id is the whole point: the
   * same suggestion has to keep the same number on every machine, otherwise
   * "Vorschlag #42" means two different things after a pull. `INSERT OR IGNORE`
   * makes the call idempotent, so reading the same file twice is harmless.
   */
  importSuggestion(s: Suggestion): boolean {
    const result = this.db
      .prepare(
        `INSERT OR IGNORE INTO suggestions (id, text, author, source, category, status, votes, canonical_id, created_at, updated_at, discord_message_id, run_id, parent_id, client_key)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        s.id,
        s.text,
        s.author,
        s.source,
        s.category,
        s.status,
        s.votes,
        s.canonicalId,
        s.createdAt,
        s.updatedAt,
        s.discordMessageId,
        s.runId,
        s.parentId ?? null,
        s.clientKey ?? null,
      );
    return Number(result.changes) > 0;
  }

  /** Writes a whole suggestion row over an existing one, id included. */
  overwriteSuggestion(s: Suggestion): void {
    this.db
      .prepare(
        `UPDATE suggestions SET text = ?, author = ?, source = ?, category = ?, status = ?, votes = ?, canonical_id = ?, created_at = ?, updated_at = ?, discord_message_id = ?, run_id = ?, parent_id = ?, client_key = ?
         WHERE id = ?`,
      )
      .run(
        s.text,
        s.author,
        s.source,
        s.category,
        s.status,
        s.votes,
        s.canonicalId,
        s.createdAt,
        s.updatedAt,
        s.discordMessageId,
        s.runId,
        s.parentId ?? null,
        s.clientKey ?? null,
        s.id,
      );
  }

  /** Inserts votes, ignoring the ones already present. Returns how many were new.
   *
   * Ids from a file written before hashing existed are hashed here, so a merge
   * never mixes a raw id and its hashed twin for the same device. */
  importVotes(votes: readonly { suggestionId: number; voterId: string; createdAt: number }[]): number {
    const stmt = this.db.prepare(
      'INSERT OR IGNORE INTO votes (suggestion_id, voter_id, created_at) VALUES (?, ?, ?)',
    );
    let added = 0;
    for (const vote of votes) {
      // A vote for a suggestion this database does not have would be invisible
      // and would distort the count if the suggestion arrives later.
      if (!this.getSuggestion(vote.suggestionId)) continue;
      const result = stmt.run(vote.suggestionId, hashVoterId(vote.voterId), vote.createdAt);
      added += Number(result.changes) > 0 ? 1 : 0;
    }
    return added;
  }

  /**
   * Recomputes `suggestions.votes` from the votes table. The counter is a cache
   * of the table, and an import writes the table directly — without this, a
   * restored suggestion would show zero votes next to its voters.
   */
  recountVotes(): void {
    this.db.exec(
      `UPDATE suggestions SET votes = (SELECT COUNT(*) FROM votes WHERE votes.suggestion_id = suggestions.id)`,
    );
  }

  createRun(run: RunRecord) {
    this.db
      .prepare(
        `INSERT INTO runs (id, suggestion_id, status, session_id, prompt, exit_code, cost, tokens_input, tokens_output, commit_hash, result_summary, created_at, started_at, finished_at, log_path, attempt, max_attempts, retry_of, not_before, timeout_ms, scope, note, scope_issues, lane, worktree_path, worktree_branch, resumes_session)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
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
        run.lane,
        run.worktreePath,
        run.worktreeBranch,
        run.resumesSession,
      );
  }

  updateRun(run: RunRecord) {
    this.db
      .prepare(
        `UPDATE runs SET status = ?, session_id = ?, exit_code = ?, cost = ?, tokens_input = ?, tokens_output = ?, commit_hash = ?, result_summary = ?, started_at = ?, finished_at = ?, attempt = ?, max_attempts = ?, retry_of = ?, not_before = ?, timeout_ms = ?, scope = ?, note = ?, scope_issues = ?, lane = ?, worktree_path = ?, worktree_branch = ?, resumes_session = ?
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
        run.lane,
        run.worktreePath,
        run.worktreeBranch,
        run.resumesSession,
        run.id,
      );
  }

  getRun(id: string): RunRecord | null {
    const row = this.db.prepare('SELECT * FROM runs WHERE id = ?').get(id) as RunRow | undefined;
    return row ? rowToRun(row) : null;
  }

  /**
   * Inserts a run under its existing id, or changes nothing. Same purpose as
   * `importSuggestion`: a run id is quoted in logs, prompts and commit messages,
   * so it has to survive a move between machines unchanged.
   */
  importRun(run: RunRecord): boolean {
    try {
      this.createRun(run);
      return true;
    } catch (err) {
      if (!isUniqueViolation(err)) throw err;
      return false;
    }
  }

  listRuns(limit = 50): RunRecord[] {
    const rows = this.db
      .prepare('SELECT * FROM runs ORDER BY created_at DESC LIMIT ?')
      .all(limit) as unknown as RunRow[];
    return rows.map(rowToRun);
  }

  // --- deployed-version check queue ------------------------------------------
  //
  // Kept next to the run methods but fully independent of them: the check queue
  // must keep working when the suggestion runner is paused, and vice versa.

  createCheck(check: CheckRecord) {
    this.db
      .prepare(
        `INSERT INTO checks (id, spec_id, kind, probe, status, title, scope, targets, limits,
           created_at, started_at, finished_at, counts, findings, summary,
           promoted_suggestion_id, log_path, note)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        check.id,
        check.specId,
        check.kind,
        check.probe,
        check.status,
        check.title,
        JSON.stringify(check.scope),
        JSON.stringify(check.targets),
        JSON.stringify(check.limits),
        check.createdAt,
        check.startedAt,
        check.finishedAt,
        JSON.stringify(check.counts),
        JSON.stringify(check.findings),
        check.summary,
        check.promotedSuggestionId,
        check.logPath,
        check.note,
      );
  }

  updateCheck(check: CheckRecord) {
    this.db
      .prepare(
        `UPDATE checks SET status = ?, started_at = ?, finished_at = ?, counts = ?,
           findings = ?, summary = ?, promoted_suggestion_id = ?, note = ?
         WHERE id = ?`,
      )
      .run(
        check.status,
        check.startedAt,
        check.finishedAt,
        JSON.stringify(check.counts),
        JSON.stringify(check.findings),
        check.summary,
        check.promotedSuggestionId,
        check.note,
        check.id,
      );
  }

  getCheck(id: string): CheckRecord | null {
    const row = this.db.prepare('SELECT * FROM checks WHERE id = ?').get(id) as
      | CheckRow
      | undefined;
    return row ? rowToCheck(row) : null;
  }

  listChecks(limit = 50): CheckRecord[] {
    const rows = this.db
      .prepare('SELECT * FROM checks ORDER BY created_at DESC LIMIT ?')
      .all(limit) as unknown as CheckRow[];
    return rows.map(rowToCheck);
  }

  /** Every check that was queued but never finished, oldest first — the restart case. */
  listUnfinishedChecks(): CheckRecord[] {
    const rows = this.db
      .prepare("SELECT * FROM checks WHERE status IN ('queued', 'running') ORDER BY created_at ASC")
      .all() as unknown as CheckRow[];
    return rows.map(rowToCheck);
  }

  getCheckQueuePaused(): boolean {
    const row = this.db.prepare('SELECT value FROM settings WHERE key = ?').get('checkQueuePaused') as
      | { value: string }
      | undefined;
    return row?.value === 'true';
  }

  setCheckQueuePaused(paused: boolean): boolean {
    this.db
      .prepare('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
      .run('checkQueuePaused', paused ? 'true' : 'false');
    return paused;
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
      maxParallelRuns: numberSetting(
        raw.maxParallelRuns,
        DEFAULT_SETTINGS.maxParallelRuns,
        SETTINGS_BOUNDS.maxParallelRuns,
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
    // One transaction: a policy number that was written while the string next to
    // it was not would leave a half-applied settings page, and `getSettings`
    // reads the table back with no way to tell that apart from a deliberate mix.
    return this.tx(() => {
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
    });
  }
}

/**
 * SQLite reports a violated UNIQUE index as SQLITE_CONSTRAINT_UNIQUE (2067) and a
 * duplicate primary key as SQLITE_CONSTRAINT_PRIMARYKEY (1555) — with the same
 * message. `runs.id` is a text primary key, so the import needs both cases.
 */
function isUniqueViolation(err: unknown): boolean {
  const sqlite = err as { errcode?: number; message?: string } | null;
  if (sqlite?.errcode === 2067 || sqlite?.errcode === 1555) return true;
  return /UNIQUE constraint failed|PRIMARY KEY must be unique/i.test(sqlite?.message ?? '');
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
