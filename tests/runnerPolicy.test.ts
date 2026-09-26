/**
 * Hard timeout, retry policy and pause mode.
 *
 * The tests drive a fake `opencode` binary through `OPENCODE_BIN`, so they spawn
 * real processes (a real SIGTERM has to work) without ever calling a model.
 */
import { execFileSync, spawn } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Store } from '../server/db';
import { Runner, isProcessAlive } from '../server/runner';
import type { RunRecord, Settings, Suggestion } from '../src/shared/types';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const tempDirs: string[] = [];
const runners: Runner[] = [];
const children: ReturnType<typeof spawn>[] = [];
let previousBin: string | undefined;

/** A stand-in for `opencode run`: no model, deterministic, killable. */
const FAKE_BIN = `#!/bin/sh
# The runner passes "--title Vorschlag #<id>"; recover it so a fake commit can
# carry the same marker a real run would.
id=$(echo "$@" | sed -n 's/.*Vorschlag #\\([0-9][0-9]*\\).*/\\1/p')
case "$FAKE_RUNNER_MODE" in
  hang) exec sleep 600 ;;
  fail) echo '{"type":"error","part":{"error":{"data":{"message":"Modell nicht verfügbar"}}}}'; exit 1 ;;
  fail-once)
    # First attempt fails, every later one hangs: lets a test watch the retry
    # run without racing it.
    if [ -n "$FAKE_RUNNER_MARK" ] && [ -f "$FAKE_RUNNER_MARK" ]; then exec sleep 600; fi
    [ -n "$FAKE_RUNNER_MARK" ] && : > "$FAKE_RUNNER_MARK"
    echo '{"type":"error","part":{"error":{"data":{"message":"Rate limit"}}}}'
    exit 1 ;;
  fail-edit)
    echo '{"type":"tool","part":{"tool":"edit","state":{"status":"completed","title":"godot/src/game/tetris/tetris_screen.gd","output":"ok"}}}'
    exit 1 ;;
  fail-commit)
    echo "Teilstand $id" > notiz.md
    git add -A >/dev/null 2>&1
    git commit -q -m "feat(suggestion-$id): Teilarbeit" >/dev/null 2>&1
    exit 1 ;;
  ok) echo '{"type":"text","part":{"text":"Fertig."}}'; exit 0 ;;
  *) exit 2 ;;
esac
`;

beforeEach(() => {
  const dir = mkdtempSync(join(tmpdir(), 'singular80-policy-'));
  tempDirs.push(dir);
  mkdirSync(join(dir, 'markers'), { recursive: true });
  const bin = join(dir, 'fake-opencode');
  writeFileSync(bin, FAKE_BIN);
  chmodSync(bin, 0o755);
  previousBin = process.env.OPENCODE_BIN;
  process.env.OPENCODE_BIN = bin;
  process.env.FAKE_RUNNER_MODE = 'ok';
  process.env.FAKE_RUNNER_MARK = join(dir, 'markers', 'first-attempt');
});

afterEach(() => {
  for (const runner of runners.splice(0)) runner.dispose();
  for (const child of children.splice(0)) {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  }
  if (previousBin === undefined) delete process.env.OPENCODE_BIN;
  else process.env.OPENCODE_BIN = previousBin;
  delete process.env.FAKE_RUNNER_MODE;
  delete process.env.FAKE_RUNNER_MARK;
  for (const dir of tempDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

interface Harness {
  store: Store;
  runner: Runner;
  dataDir: string;
  repo: string;
  suggestion: (text?: string) => Suggestion;
}

function makeGitRepo(): string {
  const dir = mkdtempSync(join(tmpdir(), 'singular80-policy-repo-'));
  tempDirs.push(dir);
  const git = (...args: string[]): void => {
    execFileSync('git', args, { cwd: dir, stdio: 'ignore' });
  };
  git('init', '-q', '-b', 'main');
  git('config', 'user.name', 'Test');
  git('config', 'user.email', 'test@example.invalid');
  writeFileSync(join(dir, 'README.md'), 'Test\n');
  git('add', '-A');
  git('commit', '-q', '-m', 'init');
  return dir;
}

function harness(settings: Partial<Settings> = {}, repo?: string): Harness {  const dir = mkdtempSync(join(tmpdir(), 'singular80-policy-data-'));
  tempDirs.push(dir);
  const dataDir = join(dir, 'data');
  const store = new Store(dataDir);
  store.saveSettings({ runTimeoutMinutes: 0, retryLimit: 0, retryBackoffSeconds: 0, ...settings });
  const projectRoot = repo ?? makeGitRepo();
  const runner = new Runner(store, {
    projectRoot,
    dataDir,
    contentDir: join(root, 'content'),
    callbacks: {},
  });
  runners.push(runner);
  return {
    store,
    runner,
    dataDir,
    repo: projectRoot,
    suggestion: (text = 'Tetris: mehr Bälle am Stück') =>
      store.createSuggestion({
        text,
        author: 'Test',
        source: 'dashboard',
        category: 'mechanics',
        canonicalId: null,
        status: 'approved',
      }),
  };
}

/** Waits until `check` is true, or fails the test after `timeout` ms. */
async function waitFor(check: () => boolean, timeout = 8000, what = 'Bedingung'): Promise<void> {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (check()) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`Timeout beim Warten auf ${what}`);
}

function spawnSleeper(): number {
  const child = spawn('sleep', ['600'], { stdio: 'ignore' });
  children.push(child);
  return child.pid!;
}

function runsOf(store: Store, suggestionId: number): RunRecord[] {
  return store.listRuns(50).filter((r) => r.suggestionId === suggestionId);
}

describe('Hartes Zeitlimit', () => {
  it('beendet einen hängenden Prozess und markiert den Run als fehlgeschlagen', async () => {
    process.env.FAKE_RUNNER_MODE = 'hang';
    const h = harness({ runTimeoutMinutes: 0.02 });
    const suggestion = h.suggestion();
    const run = h.runner.enqueue(suggestion, h.store.getSettings(), [suggestion]);
    await waitFor(() => h.store.getRun(run.id)!.status === 'running', 8000, 'Start');
    await waitFor(() => h.store.getRun(run.id)!.status !== 'running', 15_000, 'Zeitüberschreitung');

    const stored = h.store.getRun(run.id)!;
    expect(stored.status).toBe('failed');
    expect(stored.note).toContain('Zeitüberschreitung');
    expect(stored.resultSummary.length).toBeGreaterThan(0);
    expect(h.store.getSuggestion(suggestion.id)!.status).toBe('failed');
  });

  it('lässt einen Run ohne Zeitlimit laufen', async () => {
    process.env.FAKE_RUNNER_MODE = 'ok';
    const h = harness({ runTimeoutMinutes: 0 });
    const suggestion = h.suggestion();
    const run = h.runner.enqueue(suggestion, h.store.getSettings(), [suggestion]);
    expect(run.timeoutMs).toBe(0);
    await waitFor(() => h.store.getRun(run.id)!.status === 'succeeded', 8000, 'Erfolg');
  });

  it('zählt die Wartezeit nach einem Neustart weiter', async () => {
    // A run that was already over budget when the new server starts: the timeout
    // is derived from `startedAt`, so it does not restart the clock.
    const h = harness({ runTimeoutMinutes: 1 });
    const suggestion = h.suggestion();
    const sleeper = spawnSleeper();
    const logPath = join(h.dataDir, 'adopted.jsonl');
    writeFileSync(logPath, `${JSON.stringify({ type: 'run_meta', runId: 'run_adopted' })}\n`);
    h.store.createRun({
      id: 'run_adopted',
      suggestionId: suggestion.id,
      status: 'running',
      sessionId: null,
      prompt: 'p',
      exitCode: null,
      cost: null,
      tokensInput: null,
      tokensOutput: null,
      commitHash: null,
      resultSummary: '',
      createdAt: Date.now() - 10 * 60_000,
      startedAt: Date.now() - 10 * 60_000,
      finishedAt: null,
      logPath,
      attempt: 1,
      maxAttempts: 1,
      retryOf: null,
      notBefore: null,
      timeoutMs: 60_000,
      scopes: ['tetris'],
      scope: 'tetris',
      note: null,
      scopeIssues: null,
    });
    writeFileSync(join(h.dataDir, 'active-runs.json'), JSON.stringify({ run_adopted: sleeper }));

    const restarted = new Runner(h.store, {
      projectRoot: h.repo,
      dataDir: h.dataDir,
      contentDir: join(root, 'content'),
      callbacks: {},
    });
    runners.push(restarted);

    const stored = h.store.getRun('run_adopted')!;
    expect(stored.status).toBe('failed');
    expect(stored.note).toContain('Zeitüberschreitung');
    await waitFor(() => !isProcessAlive(sleeper), 8000, 'Prozess beendet');
  });
});

describe('Wiederholungen', () => {
  it('legt nach einem Fehlschlag einen sichtbaren zweiten Versuch an', async () => {
    process.env.FAKE_RUNNER_MODE = 'fail-once';
    const h = harness({ retryLimit: 1, retryBackoffSeconds: 0 });
    const suggestion = h.suggestion();
    const first = h.runner.enqueue(suggestion, h.store.getSettings(), [suggestion]);
    await waitFor(() => runsOf(h.store, suggestion.id).length === 2, 8000, 'Wiederholung');
    await waitFor(() => runsOf(h.store, suggestion.id).some((r) => r.status === 'running'), 8000, 'Start des zweiten Versuchs');

    const attempts = runsOf(h.store, suggestion.id);
    const second = attempts.find((r) => r.id !== first.id)!;
    expect(first.attempt).toBe(1);
    expect(first.maxAttempts).toBe(2);
    expect(first.status).toBe('failed');
    expect(second.attempt).toBe(2);
    expect(second.retryOf).toBe(first.id);
    expect(second.status).toBe('running');
    // The retry is a new row with its own log, not a state of the old one.
    expect(second.logPath).not.toBe(first.logPath);
    expect(second.prompt).toContain('WIEDERHOLUNGSVERSUCH 2');
  });

  it('wiederholt keinen erfolgreichen Run', async () => {
    process.env.FAKE_RUNNER_MODE = 'ok';
    const h = harness({ retryLimit: 3, retryBackoffSeconds: 0 });
    const suggestion = h.suggestion();
    const run = h.runner.enqueue(suggestion, h.store.getSettings(), [suggestion]);
    await waitFor(() => h.store.getRun(run.id)!.status === 'succeeded', 8000, 'Erfolg');
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(runsOf(h.store, suggestion.id)).toHaveLength(1);
  });

  it('wiederholt nicht, wenn der fehlgeschlagene Versuch schon committet hat', async () => {
    process.env.FAKE_RUNNER_MODE = 'fail-commit';
    const h = harness({ retryLimit: 2, retryBackoffSeconds: 0 });
    const suggestion = h.suggestion();
    const run = h.runner.enqueue(suggestion, h.store.getSettings(), [suggestion]);
    await waitFor(() => h.store.getRun(run.id)!.status === 'failed', 8000, 'Fehlschlag');
    await new Promise((resolve) => setTimeout(resolve, 200));
    // A second commit for the same suggestion would answer "did the agent do
    // anything?" twice, so the chain stops here.
    expect(runsOf(h.store, suggestion.id)).toHaveLength(1);
    const events = h.runner.getEvents(run.id);
    expect(events.some((e) => e.text.includes('Kein Wiederholungsversuch'))).toBe(true);
  });

  it('hält sich an die Obergrenze der Versuche', async () => {
    process.env.FAKE_RUNNER_MODE = 'fail';
    const h = harness({ retryLimit: 2, retryBackoffSeconds: 0 });
    const suggestion = h.suggestion();
    h.runner.enqueue(suggestion, h.store.getSettings(), [suggestion]);
    await waitFor(() => runsOf(h.store, suggestion.id).length === 3, 10_000, 'drei Versuche');
    await new Promise((resolve) => setTimeout(resolve, 300));
    const attempts = runsOf(h.store, suggestion.id);
    expect(attempts).toHaveLength(3);
    expect(attempts.every((r) => r.status === 'failed')).toBe(true);
    expect(Math.max(...attempts.map((r) => r.attempt))).toBe(3);
  });

  it('wartet mit dem Start auf den Backoff', async () => {
    process.env.FAKE_RUNNER_MODE = 'fail';
    const h = harness({ retryLimit: 1, retryBackoffSeconds: 600 });
    const suggestion = h.suggestion();
    const run = h.runner.enqueue(suggestion, h.store.getSettings(), [suggestion]);
    await waitFor(() => runsOf(h.store, suggestion.id).length === 2, 8000, 'Wiederholung in der Schlange');
    const retry = runsOf(h.store, suggestion.id).find((r) => r.id !== run.id)!;
    expect(retry.status).toBe('queued');
    expect(retry.notBefore).toBeGreaterThan(Date.now() + 100_000);
    expect(h.runner.queueState().queue.map((r) => r.id)).toContain(retry.id);
  });

  it('überlebt einen Neustart: die wartende Wiederholung startet danach', async () => {
    process.env.FAKE_RUNNER_MODE = 'fail';
    const dir = mkdtempSync(join(tmpdir(), 'singular80-policy-data-'));
    tempDirs.push(dir);
    const dataDir = join(dir, 'data');
    const store = new Store(dataDir);
    store.saveSettings({ runTimeoutMinutes: 0, retryLimit: 1, retryBackoffSeconds: 600 });
    const projectRoot = makeGitRepo();
    const runner = new Runner(store, {
      projectRoot,
      dataDir,
      contentDir: join(root, 'content'),
      callbacks: {},
    });
    const suggestion = store.createSuggestion({
      text: 'Pang: Bounce-Anzeige',
      author: 'Test',
      source: 'dashboard',
      category: 'ui',
      canonicalId: null,
      status: 'approved',
    });
    const first = runner.enqueue(suggestion, store.getSettings(), [suggestion]);
    await waitFor(() => store.listRuns(50).filter((r) => r.suggestionId === suggestion.id).length === 2, 8000, 'Wiederholung');
    runner.dispose();

    const restarted = new Runner(store, {
      projectRoot,
      dataDir,
      contentDir: join(root, 'content'),
      callbacks: {},
    });
    runners.push(restarted);
    const retry = store.listRuns(50).find((r) => r.id !== first.id)!;
    // The backoff deadline is stored on the run, so a restart waits it out
    // instead of starting the retry immediately.
    expect(restarted.queueState().queue.map((r) => r.id)).toContain(retry.id);
    expect(retry.notBefore).toBeGreaterThan(Date.now());
  });
});

describe('Pause', () => {
  it('startet keinen neuen Run, solange die Schlange pausiert ist', async () => {
    process.env.FAKE_RUNNER_MODE = 'hang';
    const h = harness();
    const first = h.suggestion('Tetris: erster Auftrag');
    const second = h.suggestion('Tetris: zweiter Auftrag');
    h.runner.setPaused(true);
    const runA = h.runner.enqueue(first, h.store.getSettings(), [first]);
    const runB = h.runner.enqueue(second, h.store.getSettings(), [second]);
    await new Promise((resolve) => setTimeout(resolve, 300));
    expect(h.store.getRun(runA.id)!.status).toBe('queued');
    expect(h.store.getRun(runB.id)!.status).toBe('queued');
    expect(h.runner.queueState().paused).toBe(true);
    expect(h.runner.queueState().queue).toHaveLength(2);
  });

  it('lässt den laufenden Run zu Ende laufen und setzt danach fort', async () => {
    process.env.FAKE_RUNNER_MODE = 'ok';
    const h = harness();
    const first = h.suggestion('Tetris: erster Auftrag');
    const second = h.suggestion('Tetris: zweiter Auftrag');
    const runA = h.runner.enqueue(first, h.store.getSettings(), [first]);
    await waitFor(() => h.store.getRun(runA.id)!.status === 'running', 8000, 'Start');
    h.runner.setPaused(true);
    const runB = h.runner.enqueue(second, h.store.getSettings(), [second]);
    await waitFor(() => h.store.getRun(runA.id)!.status === 'succeeded', 8000, 'Ende des laufenden Runs');
    // Paused means "no new work", not "kill what is running".
    expect(h.store.getRun(runB.id)!.status).toBe('queued');
    h.runner.setPaused(false);
    await waitFor(() => h.store.getRun(runB.id)!.status === 'succeeded', 8000, 'Fortsetzung');
  });

  it('überlebt einen Neustart im pausierten Zustand', async () => {
    const h = harness();
    const suggestion = h.suggestion();
    h.runner.setPaused(true);
    h.runner.dispose();
    expect(h.store.getQueuePaused()).toBe(true);

    const restarted = new Runner(h.store, {
      projectRoot: h.repo,
      dataDir: h.dataDir,
      contentDir: join(root, 'content'),
      callbacks: {},
    });
    runners.push(restarted);
    const run = restarted.enqueue(suggestion, h.store.getSettings(), [suggestion]);
    await new Promise((resolve) => setTimeout(resolve, 300));
    expect(restarted.isPaused()).toBe(true);
    expect(h.store.getRun(run.id)!.status).toBe('queued');
  });

  it('lässt sich abbrechen, während die Schlange pausiert ist', async () => {
    const h = harness();
    h.runner.setPaused(true);
    const suggestion = h.suggestion();
    const run = h.runner.enqueue(suggestion, h.store.getSettings(), [suggestion]);
    expect(h.runner.cancel(run.id).ok).toBe(true);
    expect(h.store.getRun(run.id)!.status).toBe('cancelled');
    expect(h.runner.queueState().queue).toHaveLength(0);
  });

  it('unterscheidet Abbruch von Zeitüberschreitung', async () => {
    // Both kill the process, but the outcome must stay distinguishable: a
    // cancellation is the operator's decision, a timeout is the runner's.
    process.env.FAKE_RUNNER_MODE = 'hang';
    const h = harness({ runTimeoutMinutes: 0.02 });
    const suggestion = h.suggestion();
    const cancelled = h.runner.enqueue(suggestion, h.store.getSettings(), [suggestion]);
    await waitFor(() => h.store.getRun(cancelled.id)!.status === 'running', 8000, 'Start');
    h.runner.cancel(cancelled.id);
    await waitFor(() => h.store.getRun(cancelled.id)!.status !== 'running', 8000, 'Abbruch');
    expect(h.store.getRun(cancelled.id)!.status).toBe('cancelled');
    expect(h.store.getRun(cancelled.id)!.note).toContain('Abgebrochen');
    // A cancelled run is not repeated either: the operator stopped it on purpose.
    expect(runsOf(h.store, suggestion.id)).toHaveLength(1);
  });
});

describe('Manuelles Wiederholen', () => {
  it('legt einen neuen Versuch an und verweist auf den alten', async () => {
    process.env.FAKE_RUNNER_MODE = 'fail';
    const h = harness({ retryLimit: 0, retryBackoffSeconds: 0 });
    const suggestion = h.suggestion();
    const first = h.runner.enqueue(suggestion, h.store.getSettings(), [suggestion]);
    await waitFor(() => h.store.getRun(first.id)!.status === 'failed', 8000, 'Fehlschlag');
    const result = h.runner.retry(first.id);
    expect(result.ok).toBe(true);
    expect(result.run!.attempt).toBe(2);
    expect(result.run!.retryOf).toBe(first.id);
  });

  it('verweigert das Wiederholen eines laufenden Runs', async () => {
    process.env.FAKE_RUNNER_MODE = 'hang';
    const h = harness();
    const suggestion = h.suggestion();
    const run = h.runner.enqueue(suggestion, h.store.getSettings(), [suggestion]);
    await waitFor(() => h.store.getRun(run.id)!.status === 'running', 8000, 'Start');
    expect(h.runner.retry(run.id).ok).toBe(false);
  });

  it('verweigert das Wiederholen eines erfolgreichen Runs', async () => {
    process.env.FAKE_RUNNER_MODE = 'ok';
    const h = harness();
    const suggestion = h.suggestion();
    const run = h.runner.enqueue(suggestion, h.store.getSettings(), [suggestion]);
    await waitFor(() => h.store.getRun(run.id)!.status === 'succeeded', 8000, 'Erfolg');
    const result = h.runner.retry(run.id);
    expect(result.ok).toBe(false);
    expect(result.error).toContain('nichts zu wiederholen');
    expect(runsOf(h.store, suggestion.id)).toHaveLength(1);
  });

  it('verweigert das Wiederholen, wenn schon ein Commit existiert', async () => {
    process.env.FAKE_RUNNER_MODE = 'fail-commit';
    const h = harness({ retryLimit: 0 });
    const suggestion = h.suggestion();
    const run = h.runner.enqueue(suggestion, h.store.getSettings(), [suggestion]);
    await waitFor(() => h.store.getRun(run.id)!.status === 'failed', 8000, 'Fehlschlag');
    const result = h.runner.retry(run.id);
    expect(result.ok).toBe(false);
    expect(result.error).toContain('Commit');
  });

  it('erlaubt es mit force trotzdem', async () => {
    process.env.FAKE_RUNNER_MODE = 'fail-commit';
    const h = harness({ retryLimit: 0 });
    const suggestion = h.suggestion();
    const run = h.runner.enqueue(suggestion, h.store.getSettings(), [suggestion]);
    await waitFor(() => h.store.getRun(run.id)!.status === 'failed', 8000, 'Fehlschlag');
    expect(h.runner.retry(run.id, { force: true }).ok).toBe(true);
  });
});

describe('Scope-Buchführung am Run', () => {
  it('trägt den ermittelten Scope in den Run und in das Log', async () => {
    process.env.FAKE_RUNNER_MODE = 'ok';
    const h = harness();
    const suggestion = h.suggestion('Tetris: neue Level-Serie');
    const run = h.runner.enqueue(suggestion, h.store.getSettings(), [suggestion]);
    expect(run.scopes).toContain('tetris');
    expect(run.scope).toBe('tetris');
    await waitFor(() => h.store.getRun(run.id)!.status === 'succeeded', 8000, 'Erfolg');
    expect(h.store.getRun(run.id)!.note).toBe('ok');
  });

  it('merkt sich, dass ein Run außerhalb seines Scopes gearbeitet hat', async () => {
    process.env.FAKE_RUNNER_MODE = 'fail-edit';
    const h = harness({ retryLimit: 0 });
    const suggestion = h.suggestion('Tetris: neue Level-Serie');
    const run = h.runner.enqueue(suggestion, h.store.getSettings(), [suggestion]);
    await waitFor(() => h.store.getRun(run.id)!.status === 'failed', 8000, 'Fehlschlag');
    const audit = h.runner.auditScopeOf(run.id)!;
    expect(audit.scopes).toContain('tetris');
    expect(audit.ok).toBe(true);
    expect(audit.checked).toBeGreaterThan(0);
  });
});
