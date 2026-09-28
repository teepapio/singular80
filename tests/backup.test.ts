/**
 * The repository backup: what goes into the file, and what happens when a second
 * machine reads it back. The cases that matter are the destructive ones — a merge
 * that overwrites a newer decision, renumbers a suggestion, or revives a "running"
 * row loses something the operator cannot get back.
 */
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  BACKUP_KIND,
  BackupFormatError,
  backupDisplayPath,
  backupStatus,
  buildSnapshot,
  describeBackup,
  diffSnapshot,
  mergeSnapshot,
  readSnapshotFile,
  writeSnapshotFile,
} from '../server/backup';
import { hashVoterId } from '../server/db';
import { Store } from '../server/db';
import type { RunRecord, Suggestion } from '../src/shared/types';
import type { BackupSnapshot } from '../server/backup';

const tempDirs: string[] = [];
let root: string;
let dataDir: string;
let store: Store;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'singular80-backup-repo-'));
  tempDirs.push(root);
  dataDir = join(root, 'data');
  store = new Store(dataDir);
});

afterEach(() => {
  for (const dir of tempDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
  delete process.env.BACKUP_FILE;
});

function backupFile(): string {
  return join(root, 'backup', 'dashboard.json');
}

/** Writes a file the way a broken merge or a hand edit would leave one. */
function writeRaw(name: string, content: string): void {
  mkdirSync(join(root, 'backup'), { recursive: true });
  writeFileSync(join(root, 'backup', name), content);
}

function makeSuggestion(overrides: Partial<Suggestion> = {}): Suggestion {
  return store.createSuggestion({
    text: 'Tetris: mehr Bälle am Stück',
    author: 'Spielerin',
    source: 'game',
    category: 'mechanics',
    canonicalId: null,
    status: 'approved',
    ...overrides,
  });
}

function makeRun(suggestion: Suggestion, overrides: Partial<RunRecord> = {}): RunRecord {
  const run: RunRecord = {
    id: `run_${suggestion.id}`,
    suggestionId: suggestion.id,
    status: 'succeeded',
    sessionId: 'ses_1',
    lane: 1,
    worktreePath: null,
    worktreeBranch: null,
    prompt: 'PROMO — gehört nicht ins Backup',
    exitCode: 0,
    cost: 0.01,
    tokensInput: 100,
    tokensOutput: 50,
    commitHash: 'abc1234',
    resultSummary: 'Fertig.',
    createdAt: 1_700_000_000_000,
    startedAt: 1_700_000_000_000,
    finishedAt: 1_700_000_060_000,
    logPath: join(root, 'log', 'run.jsonl'),
    attempt: 1,
    maxAttempts: 2,
    retryOf: null,
    notBefore: null,
    timeoutMs: 0,
    scopes: ['tetris', 'core'],
    scope: 'tetris',
    note: 'ok',
    scopeIssues: null,
    ...overrides,
  };
  store.createRun(run);
  return run;
}

/** A second machine: same repository file, its own empty database. */
function otherMachine(): Store {
  const dir = join(root, 'data-other');
  return new Store(dir);
}

describe('buildSnapshot', () => {
  it('nimmt Vorschläge, Entscheidungen, Stimmen und Runs auf', () => {
    const suggestion = makeSuggestion();
    store.addVote(suggestion.id, 'voter_abcdef');
    makeRun(suggestion);
    const snapshot = buildSnapshot(store, root, 1_700_000_000_000);
    expect(snapshot.kind).toBe(BACKUP_KIND);
    expect(snapshot.counts).toEqual({ suggestions: 1, runs: 1, votes: 1 });
    expect(snapshot.suggestions[0].id).toBe(suggestion.id);
    // The committed file carries a hash, never the raw device id: the repository
    // is public and `voterId` is a stable per-device identifier.
    expect(snapshot.votes[0]).toMatchObject({
      suggestionId: suggestion.id,
      voterId: hashVoterId('voter_abcdef'),
    });
    expect(snapshot.votes[0].voterId).not.toBe('voter_abcdef');
  });

  it('lässt den Prompt weg und macht den Logpfad repo-relativ', () => {
    // The prompt is derivable and kilobytes large: in the repo it would be the
    // biggest blob and a new diff line on every run.
    const suggestion = makeSuggestion();
    makeRun(suggestion);
    const snapshot = buildSnapshot(store, root);
    const run = snapshot.runs[0] as unknown as Record<string, unknown>;
    expect(run.prompt).toBeUndefined();
    expect(run.logPath).toBe('log/run.jsonl');
  });

  it('sortiert stabil, damit zwei Maschinen byte-gleiche Dateien schreiben', () => {
    const a = makeSuggestion({ text: 'A' });
    const b = makeSuggestion({ text: 'B' });
    makeRun(b, { id: 'run_b', createdAt: 5 });
    makeRun(a, { id: 'run_a', createdAt: 9 });
    const snapshot = buildSnapshot(store, root);
    expect(snapshot.suggestions.map((s) => s.id)).toEqual([a.id, b.id]);
    expect(snapshot.runs.map((r) => r.id)).toEqual(['run_b', 'run_a']);
  });
});

describe('Datei', () => {
  it('schreibt und liest dieselbe Datei', () => {
    makeSuggestion();
    const snapshot = buildSnapshot(store, root);
    writeSnapshotFile(backupFile(), snapshot);
    const read = readSnapshotFile(backupFile());
    expect(read?.counts.suggestions).toBe(1);
    expect(read?.version).toBe(snapshot.version);
  });

  it('liefert null, wenn es keine Datei gibt', () => {
    expect(readSnapshotFile(backupFile())).toBeNull();
  });

  it('lehnt eine fremde Datei ab, statt sie zu mischen', () => {
    writeRaw('dashboard.json', JSON.stringify({ kind: 'etwas-anderes', version: 1 }));
    expect(() => readSnapshotFile(backupFile())).toThrow(BackupFormatError);
  });

  it('lehnt eine neuere Version ab, statt sie zu raten', () => {
    writeRaw(
      'dashboard.json',
      JSON.stringify({ kind: BACKUP_KIND, version: 99, suggestions: [], runs: [], votes: [] }),
    );
    expect(() => readSnapshotFile(backupFile())).toThrow(/neuer als dieser Server/);
  });

  it('meldet kaputtes JSON statt einer leeren Historie', () => {
    // A silent `null` would be the worst outcome: the database would look fresh and
    // the operator would think there was never anything to back up.
    writeRaw('dashboard.json', '{ kaputt');
    expect(() => readSnapshotFile(backupFile())).toThrow(BackupFormatError);
  });

  it('nennt den Pfad repo-relativ', () => {
    expect(backupDisplayPath(root, backupFile())).toBe('backup/dashboard.json');
  });
});

describe('mergeSnapshot', () => {
  it('übernimmt Vorschläge, die hier fehlen — mit derselben Id', () => {
    const suggestion = makeSuggestion({ text: 'Vom anderen Rechner' });
    store.addVote(suggestion.id, 'voter_abcdef');
    makeRun(suggestion);
    const snapshot = buildSnapshot(store, root);

    const fresh = otherMachine();
    const report = mergeSnapshot(fresh, snapshot, { projectRoot: root });
    expect(report.suggestionsAdded).toBe(1);
    // The id is the whole point: "Vorschlag #42" must stay the same suggestion.
    const restored = fresh.getSuggestion(suggestion.id);
    expect(restored?.text).toBe('Vom anderen Rechner');
    expect(restored?.status).toBe('approved');
    expect(fresh.listVotes()).toHaveLength(1);
  });

  it('zählt die Stimmen nach dem Import aus der Vote-Tabelle, nicht aus dem Feld', () => {
    const suggestion = makeSuggestion();
    store.addVote(suggestion.id, 'voter_aaaaaa');
    store.addVote(suggestion.id, 'voter_bbbbbb');
    const snapshot = buildSnapshot(store, root);
    // `votes` in the snapshot is a counter the import overwrites — the table is truth.
    const fresh = otherMachine();
    mergeSnapshot(fresh, snapshot, { projectRoot: root });
    expect(fresh.getSuggestion(suggestion.id)?.votes).toBe(2);
  });

  it('nimmt bei einem echten Konflikt die neuere Fassung', () => {
    const suggestion = makeSuggestion({ text: 'alt' });
    const snapshot = buildSnapshot(store, root);
    const fresh = otherMachine();
    mergeSnapshot(fresh, snapshot, { projectRoot: root });
    // Approved then rejected here, so `updatedAt` moves past the file's.
    fresh.updateSuggestionStatus(suggestion.id, 'rejected');
    const localUpdatedAt = fresh.getSuggestion(suggestion.id)!.updatedAt;

    const report = mergeSnapshot(fresh, snapshot, { projectRoot: root });
    expect(report.suggestionsUpdated).toBe(0);
    expect(fresh.getSuggestion(suggestion.id)?.status).toBe('rejected');
    expect(fresh.getSuggestion(suggestion.id)!.updatedAt).toBe(localUpdatedAt);
  });

  it('übernimmt eine Entscheidung, die hier noch nicht existiert', () => {
    const suggestion = makeSuggestion();
    const snapshot = buildSnapshot(store, root);
    const fresh = otherMachine();
    mergeSnapshot(fresh, snapshot, { projectRoot: root });
    // A colleague wrote the file later and implemented the suggestion.
    const remote: BackupSnapshot = {
      ...snapshot,
      writtenAt: snapshot.writtenAt + 1000,
      suggestions: [{ ...snapshot.suggestions[0], status: 'implemented', updatedAt: snapshot.writtenAt + 1000 }],
    };
    const report = mergeSnapshot(fresh, remote, { projectRoot: root });
    expect(report.suggestionsUpdated).toBe(1);
    expect(fresh.getSuggestion(suggestion.id)?.status).toBe('implemented');
  });

  it('holt ein fehlendes Run-Ergebnis nach, ohne einen laufenden Run anzufassen', () => {
    const suggestion = makeSuggestion();
    const run = makeRun(suggestion);
    const snapshot = buildSnapshot(store, root);
    const fresh = otherMachine();
    // This machine knows the run only as "running" (a crash); the file knows it
    // succeeded. That gap is what `runsCompleted` covers.
    fresh.createRun({ ...run, status: 'running', finishedAt: null, note: null, commitHash: null });
    const report = mergeSnapshot(fresh, snapshot, { projectRoot: root });
    expect(report.runsCompleted).toBe(1);
    expect(fresh.getRun(run.id)?.status).toBe('succeeded');
    expect(fresh.getRun(run.id)?.commitHash).toBe('abc1234');
  });

  it('lässt einen laufenden Run laufen, wenn die Datei denselben Stand kennt', () => {
    // Both sides say "running" — the file's result would belong to a process this
    // machine never started.
    const suggestion = makeSuggestion();
    const run = makeRun(suggestion, { status: 'running', finishedAt: null, note: null, commitHash: null });
    const snapshot = buildSnapshot(store, root);
    const fresh = otherMachine();
    fresh.createRun(run);
    const report = mergeSnapshot(fresh, snapshot, { projectRoot: root });
    expect(report.runsCompleted).toBe(0);
    expect(fresh.getRun(run.id)?.status).toBe('running');
  });

  it('bringt einen unfertigen Run aus der Datei als abgebrochen, nicht als laufend', () => {
    // No process resumes from a JSON file, and an invented "running" run is a lie
    // the operator can no longer tell from the truth.
    const suggestion = makeSuggestion();
    makeRun(suggestion, { status: 'running', finishedAt: null, note: null, commitHash: null });
    const snapshot = buildSnapshot(store, root);
    const fresh = otherMachine();
    const report = mergeSnapshot(fresh, snapshot, { projectRoot: root });
    expect(report.runsAdded).toBe(1);
    const restored = fresh.listRuns(10)[0];
    expect(restored.status).toBe('cancelled');
    expect(restored.note).toContain('nie abgeschlossen');
  });

  it('baut den Prompt beim Import neu auf, statt einen alten mitzunehmen', () => {
    const suggestion = makeSuggestion();
    makeRun(suggestion);
    const snapshot = buildSnapshot(store, root);
    const fresh = otherMachine();
    mergeSnapshot(fresh, snapshot, { projectRoot: root });
    const restored = fresh.listRuns(10)[0];
    expect(restored.prompt).not.toBe('PROMO — gehört nicht ins Backup');
    expect(restored.prompt).toContain(`Vorschlag #${suggestion.id}`);
  });

  it('macht absoluten Logpfad wieder repo-relativ', () => {
    const suggestion = makeSuggestion();
    makeRun(suggestion);
    const snapshot = buildSnapshot(store, root);
    const fresh = otherMachine();
    mergeSnapshot(fresh, snapshot, { projectRoot: root });
    expect(fresh.listRuns(10)[0].logPath).toBe(join(root, 'log', 'run.jsonl'));
  });

  it('lässt eine Stimme ohne Vorschlag fallen, statt sie zu zählen', () => {
    makeSuggestion();
    store.addVote(store.listSuggestions()[0].id, 'voter_aaaaaa');
    const snapshot = buildSnapshot(store, root);
    snapshot.votes.push({ suggestionId: 9999, voterId: 'voter_zzzzzz', createdAt: 1 });
    const fresh = otherMachine();
    const report = mergeSnapshot(fresh, snapshot, { projectRoot: root });
    // The orphan vote must not count, or the counter is off by one once the
    // suggestion is reloaded.
    expect(report.votesAdded).toBe(1);
    expect(fresh.listVotes()).toHaveLength(1);
  });

  it('ist zweimal hintereinander laufend', () => {
    const suggestion = makeSuggestion();
    store.addVote(suggestion.id, 'voter_abcdef');
    makeRun(suggestion);
    const snapshot = buildSnapshot(store, root);
    const fresh = otherMachine();
    mergeSnapshot(fresh, snapshot, { projectRoot: root });
    const second = mergeSnapshot(fresh, snapshot, { projectRoot: root });
    expect(second).toMatchObject({
      suggestionsAdded: 0,
      suggestionsUpdated: 0,
      votesAdded: 0,
      runsAdded: 0,
      runsCompleted: 0,
    });
  });
});

describe('diffSnapshot', () => {
  it('zählt, was pro Seite fehlt', () => {
    const a = makeSuggestion({ text: 'A' });
    makeRun(a);
    const snapshot = buildSnapshot(store, root);
    const fresh = otherMachine();
    const diff = diffSnapshot(fresh, snapshot);
    expect(diff.missingHere).toBe(1);
    expect(diff.missingThere).toBe(0);
    expect(diff.runsMissingHere).toBe(1);
    makeSuggestion({ text: 'B' });
    expect(diffSnapshot(store, snapshot).missingThere).toBe(1);
    expect(a.id).toBeGreaterThan(0);
  });
});

describe('backupStatus', () => {
  it('sagt es, wenn noch keine Datei da ist', () => {
    const status = backupStatus(store, root);
    expect(status.exists).toBe(false);
    expect(describeBackup(status)).toContain('Noch keine Backup-Datei');
  });

  it('meldet eine kaputte Datei, statt sie als leer zu melden', () => {
    writeRaw('dashboard.json', '{ kaputt');
    const status = backupStatus(store, root);
    expect(status.error).toContain('gültiges JSON');
    expect(describeBackup(status)).toContain('⚠');
  });

  it('meldet nach dem Schreiben, dass beide Seiten gleich sind', () => {
    makeSuggestion();
    writeSnapshotFile(backupFile(), buildSnapshot(store, root));
    const status = backupStatus(store, root);
    expect(status.exists).toBe(true);
    expect(status.path).toBe('backup/dashboard.json');
    expect(describeBackup(status)).toContain('identisch');
  });

  it('nennt, was nachzuladen wäre', () => {
    const suggestion = makeSuggestion();
    writeSnapshotFile(backupFile(), buildSnapshot(store, root));
    const fresh = otherMachine();
    const status = backupStatus(fresh, root);
    expect(status.missingHere).toBe(1);
    expect(describeBackup(status)).toContain('fehlen hier');
    expect(suggestion.id).toBeGreaterThan(0);
  });
});
