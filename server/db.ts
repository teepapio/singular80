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
};

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
  };
}

function rowToRun(row: RunRow): RunRecord {
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
  };
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
        log_path TEXT NOT NULL
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
  }

  createSuggestion(input: {
    text: string;
    author: string;
    source: string;
    category: string;
    canonicalId: number | null;
    status?: SuggestionStatus;
    parentId?: number | null;
  }): Suggestion {
    const now = Date.now();
    const stmt = this.db.prepare(
      `INSERT INTO suggestions (text, author, source, category, status, votes, canonical_id, created_at, updated_at, parent_id)
       VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?)`,
    );
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
    );
    return this.getSuggestion(Number(result.lastInsertRowid))!;
  }

  getSuggestion(id: number): Suggestion | null {
    const row = this.db.prepare('SELECT * FROM suggestions WHERE id = ?').get(id) as
      | SuggestionRow
      | undefined;
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
        `INSERT INTO runs (id, suggestion_id, status, session_id, prompt, exit_code, cost, tokens_input, tokens_output, commit_hash, result_summary, created_at, started_at, finished_at, log_path)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
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
      );
  }

  updateRun(run: RunRecord) {
    this.db
      .prepare(
        `UPDATE runs SET status = ?, session_id = ?, exit_code = ?, cost = ?, tokens_input = ?, tokens_output = ?, commit_hash = ?, result_summary = ?, started_at = ?, finished_at = ?
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
    };
  }

  saveSettings(patch: Partial<Settings>): Settings {
    const stmt = this.db.prepare(
      'INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
    );
    for (const [key, value] of Object.entries(patch)) {
      if (value === undefined) continue;
      stmt.run(key, String(value));
    }
    return this.getSettings();
  }
}
