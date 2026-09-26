import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, describe, expect, it } from 'vitest';
import { Store } from '../server/db';
import { Runner, commitSince, isProcessAlive } from '../server/runner';
import type { RunRecord } from '../src/shared/types';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const tempDirs: string[] = [];

afterEach(() => {
  for (const dir of tempDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function makeTempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'singular80-recovery-'));
  tempDirs.push(dir);
  return dir;
}

/**
 * A throwaway git repository with one commit per suggestion id. Using a real
 * temp repo keeps the tests hermetic — they no longer depend on whatever commit
 * history happens to exist in the checked-out project.
 */
function makeTempGitRepo(commits: { message: string; files?: Record<string, string> }[]): string {
  const dir = makeTempDir();
  const git = (...args: string[]): void => {
    execFileSync('git', args, { cwd: dir, stdio: 'ignore' });
  };
  git('init', '-q', '-b', 'main');
  git('config', 'user.name', 'Test');
  git('config', 'user.email', 'test@example.invalid');
  for (const commit of commits) {
    for (const [name, content] of Object.entries(commit.files ?? { 'README.md': commit.message })) {
      writeFileSync(join(dir, name), content);
    }
    git('add', '-A');
    git('commit', '-q', '-m', commit.message);
  }
  return dir;
}

/** Builds a runner over a temp store plus a run that looks like it was interrupted. */
function setupInterruptedRun(
  startedAt: number,
  projectRoot: string,
): { store: Store; run: RunRecord; suggestionId: number } {
  const dir = makeTempDir();
  const store = new Store(join(dir, 'data'));
  const suggestion = store.createSuggestion({
    text: 'Testvorschlag für die Wiederherstellung',
    author: 'Test',
    source: 'dashboard',
    category: 'other',
    canonicalId: null,
    status: 'implementing',
  });
  const logPath = join(dir, 'run.jsonl');
  writeFileSync(
    logPath,
    `${JSON.stringify({ type: 'run_meta', runId: 'run_test', suggestionId: suggestion.id })}\n` +
      `${JSON.stringify({ type: 'text', timestamp: Date.now(), part: { text: 'Fertig.' } })}\n`,
  );
  const run: RunRecord = {
    id: 'run_test',
    suggestionId: suggestion.id,
    status: 'running',
    sessionId: null,
    prompt: 'prompt',
    exitCode: null,
    cost: null,
    tokensInput: null,
    tokensOutput: null,
    commitHash: null,
    resultSummary: '',
    createdAt: startedAt,
    startedAt,
    finishedAt: null,
    logPath,
    attempt: 1,
    maxAttempts: 1,
    retryOf: null,
    notBefore: null,
    timeoutMs: 0,
    scopes: [],
    scope: null,
    note: null,
    scopeIssues: null,
  };
  store.createRun(run);
  store.setSuggestionRun(suggestion.id, run.id);
  new Runner(store, {
    projectRoot,
    dataDir: join(dir, 'data'),
    contentDir: join(root, 'content'),
    callbacks: {},
  });
  return { store, run, suggestionId: suggestion.id };
}

describe('isProcessAlive', () => {
  it('erkennt den eigenen Prozess als lebendig', () => {
    expect(isProcessAlive(process.pid)).toBe(true);
  });

  it('erkennt eine ungenutzte PID als tot', () => {
    expect(isProcessAlive(2_147_483_646)).toBe(false);
  });
});

describe('commitSince', () => {
  it('findet den passenden Commit für einen alten Startzeitpunkt', () => {
    const repo = makeTempGitRepo([{ message: 'feat(suggestion-1): Arena' }]);
    expect(commitSince(0, repo, 1)).toMatch(/^[0-9a-f]+$/);
  });

  it('liefert null, wenn noch kein Commit nach dem Start existiert', () => {
    const repo = makeTempGitRepo([{ message: 'feat(suggestion-1): Arena' }]);
    expect(commitSince(Date.now() + 1_000_000_000, repo, 1)).toBeNull();
  });

  it('ordnet einen Commit einer anderen Suggestion nicht zu', () => {
    const repo = makeTempGitRepo([{ message: 'feat(suggestion-1): Arena' }]);
    expect(commitSince(0, repo, 999999)).toBeNull();
  });
});

describe('Runner-Neustart-Wiederherstellung', () => {
  it('rekonstruiert einen abgebrochenen Run als erfolgreich, wenn ein Commit existiert', () => {
    const repo = makeTempGitRepo([{ message: 'feat(suggestion-1): Arena' }]);
    const { store, run, suggestionId } = setupInterruptedRun(0, repo);
    const recovered = store.getRun(run.id)!;
    expect(recovered.status).toBe('succeeded');
    expect(recovered.commitHash).not.toBeNull();
    expect(store.getSuggestion(suggestionId)!.status).toBe('implemented');
  });

  it('markiert einen abgebrochenen Run ohne Commit als fehlgeschlagen', () => {
    const repo = makeTempGitRepo([{ message: 'feat(suggestion-1): Arena' }]);
    const { store, run } = setupInterruptedRun(Date.now() + 1_000_000_000, repo);
    expect(store.getRun(run.id)!.status).toBe('failed');
  });
});

describe('Runner.reconcileNow (Dashboard-Aufräumaktion)', () => {
  /** Creates a running run *after* the runner started, so no entry owns it. */
  function createPhantomRun(): { store: Store; runner: Runner; id: string; suggestionId: number } {
    const dir = makeTempDir();
    const store = new Store(join(dir, 'data'));
    const suggestion = store.createSuggestion({
      text: 'Phantom-Run für den Aufräum-Test',
      author: 'Test',
      source: 'dashboard',
      category: 'other',
      canonicalId: null,
      status: 'implementing',
    });
    const runner = new Runner(store, {
      projectRoot: root,
      dataDir: join(dir, 'data'),
      contentDir: join(root, 'content'),
      callbacks: {},
    });
    const logPath = join(dir, 'phantom.jsonl');
    writeFileSync(logPath, `${JSON.stringify({ type: 'run_meta', runId: 'run_phantom' })}\n`);
    const id = 'run_phantom';
    store.createRun({
      id,
      suggestionId: suggestion.id,
      status: 'running',
      sessionId: null,
      prompt: 'prompt',
      exitCode: null,
      cost: null,
      tokensInput: null,
      tokensOutput: null,
      commitHash: null,
      resultSummary: '',
      createdAt: Date.now(),
      startedAt: Date.now() + 1_000_000_000,
      finishedAt: null,
      logPath,
      attempt: 1,
      maxAttempts: 1,
      retryOf: null,
      notBefore: null,
      timeoutMs: 0,
      scopes: [],
      scope: null,
      note: null,
      scopeIssues: null,
    });
    return { store, runner, id, suggestionId: suggestion.id };
  }

  it('finalisiert einen verwaisten Running-Run und gibt ihn zurück', () => {
    const { store, runner, id, suggestionId } = createPhantomRun();
    const fixed = runner.reconcileNow();
    expect(fixed.map((r) => r.id)).toContain(id);
    expect(store.getRun(id)!.status).toBe('failed');
    expect(store.getSuggestion(suggestionId)!.status).toBe('failed');
  });

  it('lässt einen Run in Ruhe, sobald er nicht mehr als laufend markiert ist', () => {
    const { runner, id } = createPhantomRun();
    runner.reconcileNow();
    expect(runner.reconcileNow().map((r) => r.id)).not.toContain(id);
  });
});
