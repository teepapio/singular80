import { execFileSync, spawn } from 'node:child_process';
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
    lane: 1,
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
    lane: 1,
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

describe('Übernommene Runs halten ihre Spur', () => {
  const adopted: ReturnType<typeof spawn>[] = [];

  afterEach(() => {
    for (const child of adopted.splice(0)) {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    }
  });

  /**
   * The state a server restart finds: the database says `running`, the opencode
   * process is still alive, and the PID registry points at it. Building the
   * `Runner` is what adopts the run, so the record has to exist *before*.
   */
  function bootWithAdoptedRun(settings: Record<string, number> = {}): {
    runner: Runner;
    run: RunRecord;
    store: Store;
  } {
    const dir = makeTempDir();
    const dataDir = join(dir, 'data');
    const store = new Store(dataDir);
    store.saveSettings({ runTimeoutMinutes: 0, retryLimit: 0, retryBackoffSeconds: 0, ...settings });
    const suggestion = store.createSuggestion({
      text: 'Tetris: mehr Bälle am Stück',
      author: 'Test',
      source: 'dashboard',
      category: 'mechanics',
      canonicalId: null,
      status: 'implementing',
    });
    const logPath = join(dir, 'adopted.jsonl');
    writeFileSync(logPath, `${JSON.stringify({ type: 'run_meta', runId: 'run_adopted' })}\n`);
    const run: RunRecord = {
      id: 'run_adopted',
      suggestionId: suggestion.id,
      status: 'running',
      sessionId: null,
      lane: null,
      prompt: 'p',
      exitCode: null,
      cost: null,
      tokensInput: null,
      tokensOutput: null,
      commitHash: null,
      resultSummary: '',
      createdAt: Date.now() - 5_000,
      startedAt: Date.now() - 5_000,
      finishedAt: null,
      logPath,
      attempt: 1,
      maxAttempts: 1,
      retryOf: null,
      notBefore: null,
      timeoutMs: 0,
      scopes: ['tetris', 'core'],
      scope: 'tetris',
      note: null,
      scopeIssues: null,
    };
    store.createRun(run);
    // A real, long-lived process: `recover()` only adopts what is genuinely
    // alive, and the bug this guards against is exactly in that path.
    const child = spawn('sleep', ['600'], { stdio: 'ignore' });
    adopted.push(child);
    writeFileSync(join(dataDir, 'active-runs.json'), JSON.stringify({ run_adopted: child.pid }));
    const runner = new Runner(store, {
      projectRoot: root,
      dataDir,
      contentDir: join(root, 'content'),
      callbacks: {},
    });
    return { runner, run, store };
  }

  it('übernimmt einen lebenden Run und weist ihm eine Spur zu', () => {
    const { runner, run, store } = bootWithAdoptedRun({ maxParallelRuns: 3 });
    expect(runner.activeRuns().map((r) => r.id)).toEqual([run.id]);
    expect(runner.activeRun()?.id).toBe(run.id);
    // The lane is persisted, so the panel shows the same number after a reload.
    expect(store.getRun(run.id)?.lane).toBe(1);
    runner.dispose();
  });

  it('vergibt die Spur des übernommenen Runs nicht ein zweites Mal', () => {
    // The failure this protects against: the adopted run is not registered, so
    // `activeRecords()` is empty, the next pump hands out lane 1 again, and two
    // agents end up in the same scope with nothing warning about it.
    const { runner, run } = bootWithAdoptedRun({ maxParallelRuns: 1 });
    expect(runner.queueState().activeRuns).toHaveLength(1);
    const fresh = runner.queueState().activeRuns[0];
    expect(fresh.id).toBe(run.id);
    runner.dispose();
  });

  it('gibt eine zu hohe Spur auf, wenn die Einstellung kleiner geworden ist', () => {
    const { runner } = bootWithAdoptedRun({ maxParallelRuns: 1 });
    expect(runner.activeRuns()[0].lane).toBe(1);
    runner.dispose();
  });
});
