/**
 * The dashboard's memory, as a file in the repository.
 *
 * Everything the dashboard decided lives in `data/singular80.db`, and a SQLite
 * file is exactly the thing you cannot put in git: it is a binary blob, every
 * merge is a conflict, and the moment two machines each ran their own server the
 * histories are two unrelated files. So the same facts also exist as one JSON
 * document that is meant to be committed:
 *
 *   backup/dashboard.json   ← written by "Backup ins Repo schreiben"
 *
 * Two properties make that file worth having:
 *
 *  - **It is readable without the server.** A lost database, a fresh clone or a
 *    second machine can read the whole history — texts, decisions, votes and
 *    every run with its commit — with `git show`.
 *  - **It is diffable.** Sorted ids and a stable field order mean a change is
 *    one line, not a rebuilt binary.
 *
 * Reading it back is a merge, not a restore: the file never overwrites newer
 * local facts, and a run that was still in flight on the other machine arrives
 * as `cancelled` rather than as a lie. The rules are in `mergeSnapshot` and each
 * one of them exists because the opposite would destroy something.
 */
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join, relative, sep } from 'node:path';
import { hostname } from 'node:os';
import type { RunRecord, Suggestion } from '../src/shared/types';
import { OPERATOR_SOURCE } from '../src/shared/types';
import type { Store } from './db';
import { buildPrompt } from './runner';

/** Bumped whenever the shape below changes in a way a reader must notice. */
export const BACKUP_VERSION = 1;

export const BACKUP_KIND = 'singular80-dashboard-backup';

/** Default location, relative to the repository root. */
export const BACKUP_RELATIVE_PATH = join('backup', 'dashboard.json');

/**
 * A run as it goes into the repository: same facts, but `prompt` is left out and
 * `logPath` is relative.
 *
 * The prompt is the one field that would blow the file up — every run stores a
 * few kilobytes of the same instructions — and it is *derived*: suggestion text,
 * cluster, settings, scope and attempt. Rebuilding it on import keeps the file
 * small and, better, keeps a hand-tuned prompt in the database authoritative
 * instead of letting a two-week-old copy win.
 */
export type PortableRun = Omit<RunRecord, 'prompt' | 'logPath'> & { logPath: string };

export interface BackupVote {
  suggestionId: number;
  voterId: string;
  createdAt: number;
}

export interface BackupSnapshot {
  kind: typeof BACKUP_KIND;
  version: number;
  /** When this file was written, ms. */
  writtenAt: number;
  /** Which machine wrote it — the question you ask first when two disagree. */
  machine: string;
  counts: { suggestions: number; runs: number; votes: number };
  suggestions: Suggestion[];
  runs: PortableRun[];
  votes: BackupVote[];
}

export interface BackupDiff {
  /** In the file, unknown here. */
  missingHere: number;
  /** Here, never written to the file. */
  missingThere: number;
  /** In both, but not identical. */
  differing: number;
  /** Of those: the file is the newer one. */
  newer: number;
  /** Of those: this database is newer. */
  older: number;
  /** Runs the file has that this database has not. */
  runsMissingHere: number;
}

export interface MergeReport {
  suggestionsAdded: number;
  suggestionsUpdated: number;
  votesAdded: number;
  runsAdded: number;
  runsCompleted: number;
  /** Ids that were inserted, so the caller can tell every open dashboard about
   * exactly those and not about the whole table. */
  suggestionIdsAdded: number[];
  suggestionIdsUpdated: number[];
  /** Ids the file carried in a shape this server refuses to apply. */
  skipped: string[];
}

/** Absolute path of the backup file; `BACKUP_FILE` overrides the default. */
export function backupPath(projectRoot: string): string {
  const override = process.env.BACKUP_FILE?.trim();
  if (override) return isAbsolute(override) ? override : join(projectRoot, override);
  return join(projectRoot, BACKUP_RELATIVE_PATH);
}

/** Repo-relative, POSIX-style path for messages and the API answer. */
export function backupDisplayPath(projectRoot: string, path = backupPath(projectRoot)): string {
  const rel = relative(projectRoot, path);
  return (rel.startsWith('..') ? path : rel).split(sep).join('/');
}

/** Collects the whole dashboard history in a shape that is stable to diff. */
export function buildSnapshot(store: Store, projectRoot: string, now = Date.now()): BackupSnapshot {
  const suggestions = [...store.listSuggestions()].sort((a, b) => a.id - b.id);
  const runs = [...store.listRuns(100_000)]
    .sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id))
    // `prompt` is deliberately dropped here — see PortableRun. The name says
    // "removed on purpose" without a lint rule having to be told.
    .map<PortableRun>(({ prompt: _prompt, logPath, ...rest }) => ({
      ...rest,
      // The log files are gitignored; what matters is *where* they were, so a
      // history entry can still point at one after a fresh clone.
      logPath: relative(projectRoot, logPath).split(sep).join('/'),
    }));
  const votes = store.listVotes();
  return {
    kind: BACKUP_KIND,
    version: BACKUP_VERSION,
    writtenAt: now,
    machine: hostname(),
    counts: { suggestions: suggestions.length, runs: runs.length, votes: votes.length },
    suggestions,
    runs,
    votes,
  };
}

/**
 * Serializes deterministically. `JSON.stringify` already preserves insertion
 * order, and every object here is built in a fixed order, so two machines with
 * the same history produce byte-identical files — which is what makes a merge
 * show up as no diff at all instead of as noise.
 */
export function serializeSnapshot(snapshot: BackupSnapshot): string {
  return `${JSON.stringify(snapshot, null, 2)}\n`;
}

/** Writes the file atomically: a half-written backup is worse than none. */
export function writeSnapshotFile(path: string, snapshot: BackupSnapshot): void {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, serializeSnapshot(snapshot), 'utf8');
  renameSync(tmp, path);
}

export class BackupFormatError extends Error {}

/** Reads and validates. A wrong `kind` is refused loudly, not merged. */
export function readSnapshotFile(path: string): BackupSnapshot | null {
  if (!existsSync(path)) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(path, 'utf8'));
  } catch (err) {
    throw new BackupFormatError(`Backup-Datei ist kein gültiges JSON: ${(err as Error).message}`);
  }
  const snapshot = parsed as Partial<BackupSnapshot>;
  if (snapshot?.kind !== BACKUP_KIND) {
    throw new BackupFormatError(
      `Das ist keine Singular-80-Backup-Datei (kind=${String(snapshot?.kind)}).`,
    );
  }
  if (typeof snapshot.version !== 'number' || snapshot.version > BACKUP_VERSION) {
    throw new BackupFormatError(
      `Backup-Version ${String(snapshot.version)} ist neuer als dieser Server (${BACKUP_VERSION}) — bitte Server aktualisieren.`,
    );
  }
  if (!Array.isArray(snapshot.suggestions) || !Array.isArray(snapshot.runs)) {
    throw new BackupFormatError('Backup-Datei hat keine Vorschlags- oder Run-Liste.');
  }
  return {
    kind: BACKUP_KIND,
    version: snapshot.version,
    writtenAt: typeof snapshot.writtenAt === 'number' ? snapshot.writtenAt : 0,
    machine: typeof snapshot.machine === 'string' ? snapshot.machine : 'unbekannt',
    counts: snapshot.counts ?? { suggestions: snapshot.suggestions.length, runs: snapshot.runs.length, votes: 0 },
    suggestions: snapshot.suggestions,
    runs: snapshot.runs,
    votes: Array.isArray(snapshot.votes) ? snapshot.votes : [],
  };
}

/** Status of the file plus how far it and the database have drifted apart. */
export function backupStatus(
  store: Store,
  projectRoot: string,
  path = backupPath(projectRoot),
): BackupDiff & {
  path: string;
  exists: boolean;
  writtenAt: number | null;
  machine: string | null;
  suggestionCount: number;
  runCount: number;
  voteCount: number;
  error: string | null;
} {
  const base = {
    path: backupDisplayPath(projectRoot, path),
    exists: false,
    writtenAt: null as number | null,
    machine: null as string | null,
    suggestionCount: 0,
    runCount: 0,
    voteCount: 0,
    error: null as string | null,
    missingHere: 0,
    missingThere: 0,
    differing: 0,
    newer: 0,
    older: 0,
    runsMissingHere: 0,
  };
  let snapshot: BackupSnapshot | null = null;
  try {
    snapshot = readSnapshotFile(path);
  } catch (err) {
    return { ...base, exists: existsSync(path), error: (err as Error).message };
  }
  if (!snapshot) return base;
  return {
    ...base,
    ...diffSnapshot(store, snapshot),
    exists: true,
    writtenAt: snapshot.writtenAt,
    machine: snapshot.machine,
    suggestionCount: snapshot.suggestions.length,
    runCount: snapshot.runs.length,
    voteCount: snapshot.votes.length,
  };
}

/** How many facts each side has that the other does not. Pure, so it is testable. */
export function diffSnapshot(store: Store, snapshot: BackupSnapshot): BackupDiff {
  const local = new Map(store.listSuggestions().map((s) => [s.id, s]));
  let missingHere = 0;
  let missingThere = 0;
  let differing = 0;
  let newer = 0;
  let older = 0;
  for (const remote of snapshot.suggestions) {
    const mine = local.get(remote.id);
    if (!mine) {
      missingHere += 1;
      continue;
    }
    if (sameSuggestion(mine, remote)) continue;
    differing += 1;
    // Newer wins. `updatedAt` is bumped by every status change, vote and run
    // link, so it is the only field that orders two versions of the same row.
    if (remote.updatedAt > mine.updatedAt) newer += 1;
    else older += 1;
  }
  const localRunIds = new Set(store.listRuns(100_000).map((r) => r.id));
  let runsMissingHere = 0;
  for (const run of snapshot.runs) if (!localRunIds.has(run.id)) runsMissingHere += 1;
  missingThere = [...local.keys()].filter((id) => !snapshot.suggestions.some((s) => s.id === id)).length;
  return { missingHere, missingThere, differing, newer, older, runsMissingHere };
}

/** Two rows are the same when every field that anybody decided is equal. */
function sameSuggestion(a: Suggestion, b: Suggestion): boolean {
  return (
    a.text === b.text &&
    a.author === b.author &&
    a.source === b.source &&
    a.category === b.category &&
    a.status === b.status &&
    a.votes === b.votes &&
    a.canonicalId === b.canonicalId &&
    a.parentId === (b.parentId ?? null) &&
    a.runId === b.runId &&
    a.updatedAt === b.updatedAt
  );
}

/**
 * Applies a snapshot to the database. Never destructive:
 *
 *  - a suggestion only in the file is inserted with its id; a suggestion in both
 *    keeps whichever version has the newer `updatedAt` (ties go to the local one,
 *    because the local row may have just been changed by a vote this very
 *    request did not see);
 *  - a run only in the file is inserted; a run in both is only touched when the
 *    file has an *outcome* and the local row does not. That repairs a machine
 *    which lost "succeeded" and is a no-op for a run that is live here, because
 *    a live run has no outcome yet;
 *  - a run the file still lists as `running`/`queued` arrives as `cancelled`. It
 *    was in flight on another machine, it cannot be resumed from a JSON file, and
 *    leaving it "running" would show the operator a session that does not exist.
 */
export function mergeSnapshot(
  store: Store,
  snapshot: BackupSnapshot,
  options: { projectRoot: string },
): MergeReport {
  const report: MergeReport = {
    suggestionsAdded: 0,
    suggestionsUpdated: 0,
    votesAdded: 0,
    runsAdded: 0,
    runsCompleted: 0,
    suggestionIdsAdded: [],
    suggestionIdsUpdated: [],
    skipped: [],
  };
  const byId = new Map(snapshot.suggestions.map((s) => [s.id, s]));

  for (const remote of snapshot.suggestions) {
    const mine = store.getSuggestion(remote.id);
    if (!mine) {
      if (store.importSuggestion(remote)) {
        report.suggestionsAdded += 1;
        report.suggestionIdsAdded.push(remote.id);
      }
      continue;
    }
    if (sameSuggestion(mine, remote)) continue;
    if (remote.updatedAt > mine.updatedAt) {
      store.overwriteSuggestion(remote);
      report.suggestionsUpdated += 1;
      report.suggestionIdsUpdated.push(remote.id);
    }
  }
  report.votesAdded = store.importVotes(snapshot.votes);
  if (report.votesAdded > 0) store.recountVotes();

  for (const portable of snapshot.runs) {
    const mine = store.getRun(portable.id);
    if (!mine) {
      const run = toRunRecord(portable, store, byId, options);
      if (store.importRun(run)) report.runsAdded += 1;
      continue;
    }
    if (isFinished(mine.status) || !isFinished(portable.status)) continue;
    // The file knows how it ended, this database does not: take the outcome.
    const run = toRunRecord(portable, store, byId, options);
    store.updateRun(run);
    report.runsCompleted += 1;
  }
  return report;
}

function isFinished(status: RunRecord['status']): boolean {
  return status === 'succeeded' || status === 'failed' || status === 'cancelled';
}

/** Turns a stored run back into a full record: absolute log path, real prompt. */
function toRunRecord(
  portable: PortableRun,
  store: Store,
  suggestions: Map<number, Suggestion>,
  options: { projectRoot: string },
): RunRecord {
  const { prompt, logPath, ...rest } = portable as PortableRun & { prompt?: string };
  const suggestion = suggestions.get(portable.suggestionId) ?? store.getSuggestion(portable.suggestionId);
  const settings = store.getSettings();
  const cluster = suggestion
    ? store
        .listSuggestions()
        .filter((s) => (s.canonicalId ?? s.id) === (suggestion.canonicalId ?? suggestion.id))
    : [];
  const rebuilt = suggestion
    ? buildPrompt(
        suggestion,
        cluster.length ? cluster : [suggestion],
        settings,
        options.projectRoot,
        portable.scopes,
        portable.attempt,
      )
    : `#${portable.suggestionId} (Vorschlag in dieser Datenbank nicht vorhanden)`;
  return {
    ...rest,
    // An unfinished run from another machine cannot be resumed, and pretending
    // otherwise would show a session nobody can cancel or wait for.
    status: isFinished(portable.status) ? portable.status : 'cancelled',
    note: isFinished(portable.status) ? portable.note : 'Aus dem Backup importiert — dort nie abgeschlossen',
    prompt: rebuilt,
    logPath: isAbsolute(logPath) ? logPath : join(options.projectRoot, logPath),
  };
}

/** One German line for the dashboard's backup panel. Pure, so it is testable. */
export function describeBackup(input: {
  exists: boolean;
  writtenAt: number | null;
  machine: string | null;
  suggestionCount: number;
  runCount: number;
  voteCount: number;
  missingHere: number;
  missingThere: number;
  differing: number;
  newer: number;
  runsMissingHere: number;
  error: string | null;
  now?: number;
}): string {
  if (input.error) return `⚠ ${input.error}`;
  if (!input.exists) {
    return 'Noch keine Backup-Datei im Repository. „Ins Repo schreiben“ legt sie an — danach gehört sie mit ins Git.';
  }
  const when = input.writtenAt ? new Date(input.writtenAt).toLocaleString('de-DE') : 'unbekannt';
  const parts = [
    `${input.suggestionCount} Vorschläge, ${input.runCount} Runs, ${input.voteCount} Stimmen`,
    `geschrieben ${when}${input.machine ? ` von ${input.machine}` : ''}`,
  ];
  if (input.missingHere > 0) parts.push(`${input.missingHere} fehlen hier (aus der Datei nachladen)`);
  if (input.runsMissingHere > 0) parts.push(`${input.runsMissingHere} Runs fehlen hier`);
  if (input.differing > 0) {
    parts.push(
      `${input.differing} Abweichungen (Datei ${input.newer}× neuer, hier ${input.differing - input.newer}× neuer)`,
    );
  }
  if (input.missingThere > 0) parts.push(`${input.missingThere} nur hier — beim Schreiben dazukommen`);
  if (input.missingHere === 0 && input.differing === 0 && input.missingThere === 0) {
    parts.push('Datenbank und Datei sind identisch.');
  }
  void input.now;
  return parts.join(' · ');
}

/** True when an operator order is in the snapshot — the dashboard badges it. */
export function isOperatorOrder(suggestion: Suggestion): boolean {
  return suggestion.source === OPERATOR_SOURCE;
}
