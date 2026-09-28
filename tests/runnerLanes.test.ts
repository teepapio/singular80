/**
 * Parallel lanes: how many opencode sessions run at once, and which queued run gets
 * a free one. A fake `opencode` binary via `OPENCODE_BIN` in "hang" mode keeps a run
 * `running` as long as the test needs. Scope ids come from the real
 * `scripts/scopes.mjs` manifest — a made-up list would test the mock, not the manifest.
 */
import { spawn } from 'node:child_process';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Store } from '../server/db';
import { Runner } from '../server/runner';
import { freeLane, primaryScope, scopesConflict, sharedBroadScopes } from '../server/scopes';
import type { RunRecord, Settings, Suggestion } from '../src/shared/types';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const tempDirs: string[] = [];
const runners: Runner[] = [];
const children: ReturnType<typeof spawn>[] = [];
let previousBin: string | undefined;

/** A stand-in for `opencode run` that never finishes on its own. */
const FAKE_BIN = `#!/bin/sh
exec sleep 600
`;

beforeEach(() => {
  const dir = mkdtempSync(join(tmpdir(), 'singular80-lanes-'));
  tempDirs.push(dir);
  const bin = join(dir, 'fake-opencode');
  writeFileSync(bin, FAKE_BIN);
  chmodSync(bin, 0o755);
  previousBin = process.env.OPENCODE_BIN;
  process.env.OPENCODE_BIN = bin;
});

afterEach(() => {
  for (const runner of runners.splice(0)) runner.dispose();
  for (const child of children.splice(0)) {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  }
  if (previousBin === undefined) delete process.env.OPENCODE_BIN;
  else process.env.OPENCODE_BIN = previousBin;
  for (const dir of tempDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

interface Harness {
  store: Store;
  runner: Runner;
  /** A suggestion whose text names a game, so it gets that game's scope. */
  suggestion: (text: string) => Suggestion;
  enqueue: (text: string) => RunRecord;
  running: () => RunRecord[];
}

function harness(settings: Partial<Settings> = {}): Harness {
  const dir = mkdtempSync(join(tmpdir(), 'singular80-lanes-data-'));
  tempDirs.push(dir);
  const dataDir = join(dir, 'data');
  const store = new Store(dataDir);
  store.saveSettings({ runTimeoutMinutes: 0, retryLimit: 0, retryBackoffSeconds: 0, ...settings });
  const runner = new Runner(store, {
    // The root is only used to find the binary and for `log/`; no git runs while a
    // run hangs.
    projectRoot: root,
    dataDir,
    contentDir: join(root, 'content'),
    callbacks: {},
  });
  runners.push(runner);
  const suggestion = (text: string): Suggestion =>
    store.createSuggestion({
      text,
      author: 'Test',
      source: 'dashboard',
      category: 'mechanics',
      canonicalId: null,
      status: 'approved',
    });
  return {
    store,
    runner,
    suggestion,
    enqueue: (text: string) => {
      const s = suggestion(text);
      return runner.enqueue(s, store.getSettings(), [s]);
    },
    running: () => store.listRuns(50).filter((r) => r.status === 'running'),
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

describe('scopesConflict', () => {
  const run = (id: string, scopes: string[]) => ({ id, scopes });

  it('lässt zwei verschiedene Spiele nebeneinander laufen', () => {
    expect(scopesConflict(run('a', ['tetris']), run('b', ['pang']))).toBe(false);
  });

  it('sperrt zwei Runs auf demselben Spiel', () => {
    expect(scopesConflict(run('a', ['tetris']), run('b', ['tetris']))).toBe(true);
  });

  it('lässt zwei Spiele laufen, die beide nur die breite Kategorie ergänzt bekommen', () => {
    // The documented leftover: `core`/`content` are supplement, not ownership. Comparing
    // the full scope list would put the queue back to serial.
    expect(scopesConflict(run('a', ['tetris', 'core']), run('b', ['pang', 'core']))).toBe(false);
    expect(sharedBroadScopes(run('a', ['tetris', 'core']), run('b', ['pang', 'core']))).toEqual(['core']);
  });

  it('gibt einem Run, dessen ganzer Job der breite Scope ist, den Baum allein', () => {
    expect(scopesConflict(run('a', ['core']), run('b', ['tetris']))).toBe(true);
    expect(scopesConflict(run('a', ['content']), run('b', ['pang', 'content']))).toBe(true);
    expect(sharedBroadScopes(run('a', ['tetris']), run('b', ['pang']))).toEqual([]);
  });

  it('nimmt den spezifischsten Scope als Besitzer', () => {
    expect(primaryScope(['tetris', 'core'])).toBe('tetris');
    expect(primaryScope(['core'])).toBe('core');
    expect(primaryScope([])).toBeNull();
  });

  it('behandelt einen Run ohne bekannten Scope als Konflikt zu allem', () => {
    // Nothing is known about where it writes — that must not be a free pass.
    expect(scopesConflict(run('a', []), run('b', ['pang']))).toBe(true);
    expect(scopesConflict(run('a', ['tetris']), run('b', []))).toBe(true);
  });

  it('behandelt denselben Run als Konflikt', () => {
    expect(scopesConflict(run('a', ['tetris']), run('a', ['pang']))).toBe(true);
  });
});

describe('freeLane', () => {
  it('vergibt die niedrigste freie Spur', () => {
    expect(freeLane([], 3)).toBe(1);
    expect(freeLane([1], 3)).toBe(2);
    expect(freeLane([2, 1], 3)).toBe(3);
  });

  it('sagt, wenn alle Spuren belegt sind', () => {
    expect(freeLane([1, 2, 3], 3)).toBeNull();
    expect(freeLane([9], 1)).toBe(1);
  });
});

describe('Parallele Spuren', () => {
  it('startet mehrere Runs gleichzeitig, wenn ihre Scopes sich nicht überschneiden', async () => {
    const h = harness({ maxParallelRuns: 3 });
    h.enqueue('Tetris: mehr Bälle am Stück');
    h.enqueue('Pang: die Bälle sollen schneller fliegen');
    h.enqueue('Poker: Chips anders verteilen');
    await waitFor(() => h.running().length === 3, 8000, 'drei laufende Runs');
    const lanes = h.running().map((r) => r.lane).sort();
    expect(lanes).toEqual([1, 2, 3]);
  });

  it('hält einen zweiten Run auf denselben Scope zurück', async () => {
    const h = harness({ maxParallelRuns: 3 });
    h.enqueue('Tetris: mehr Bälle am Stück');
    await waitFor(() => h.running().length === 1, 8000, 'erster Run');
    h.enqueue('Tetris: noch ein Feld mehr');
    // The second Tetris run must not start, however many lanes are free.
    await new Promise((resolve) => setTimeout(resolve, 300));
    expect(h.running().length).toBe(1);
    const state = h.runner.queueState();
    expect(state.queue.length).toBe(1);
    expect(state.blockedRunIds).toContain(state.queue[0].id);
  });

  it('lässt einen wartenden Run starten, sobald seine Spur frei wird', async () => {
    const h = harness({ maxParallelRuns: 1 });
    const first = h.enqueue('Tetris: mehr Bälle am Stück');
    await waitFor(() => h.running().length === 1, 8000, 'erster Run');
    h.enqueue('Pang: die Bälle sollen schneller fliegen');
    await new Promise((resolve) => setTimeout(resolve, 200));
    expect(h.running().length).toBe(1);

    h.runner.cancel(first.id);
    await waitFor(() => h.running().length === 1 && h.running()[0].suggestionId !== first.suggestionId, 8000, 'Nachfolge-Run');
    const started = h.running()[0];
    expect(started.status).toBe('running');
    // The freed lane is handed out again, not merely counted on.
    expect(started.lane).toBe(1);
  });

  it('behandelt eine Einstellung von einer Spur wie die alte serielle Queue', async () => {
    const h = harness({ maxParallelRuns: 1 });
    expect(h.runner.capacity()).toBe(1);
    h.enqueue('Tetris: mehr Bälle am Stück');
    h.enqueue('Pang: die Bälle sollen schneller fliegen');
    await waitFor(() => h.running().length === 1, 8000, 'ein laufender Run');
    await new Promise((resolve) => setTimeout(resolve, 200));
    expect(h.running().length).toBe(1);
    expect(h.runner.policy().maxParallelRuns).toBe(1);
  });

  it('meldet belegte Spuren in der QueueState', async () => {
    const h = harness({ maxParallelRuns: 2 });
    h.enqueue('Tetris: mehr Bälle am Stück');
    h.enqueue('Pang: die Bälle sollen schneller fliegen');
    await waitFor(() => h.running().length === 2, 8000, 'zwei laufende Runs');
    const state = h.runner.queueState();
    expect(state.activeRuns.length).toBe(2);
    // The oldest running run stays `activeRun` — the old API knows of only one.
    expect(state.activeRun?.id).toBe(state.activeRuns[0].id);
    expect(state.policy.maxParallelRuns).toBe(2);
  });

  it('gibt die Spur wieder frei, wenn ein Run endet', async () => {
    const h = harness({ maxParallelRuns: 1 });
    const first = h.enqueue('Tetris: mehr Bälle am Stück');
    await waitFor(() => h.running().length === 1, 8000, 'erster Run');
    h.runner.cancel(first.id);
    await waitFor(() => h.running().length === 0, 8000, 'kein laufender Run');
    expect(h.runner.activeRuns()).toEqual([]);
    expect(h.store.getRun(first.id)!.status).toBe('cancelled');
  });

  it('beendet bei einem Pausenwunsch nichts, was schon läuft', async () => {
    const h = harness({ maxParallelRuns: 2 });
    h.enqueue('Tetris: mehr Bälle am Stück');
    await waitFor(() => h.running().length === 1, 8000, 'erster Run');
    h.runner.setPaused(true);
    h.enqueue('Pang: die Bälle sollen schneller fliegen');
    await new Promise((resolve) => setTimeout(resolve, 300));
    expect(h.running().length).toBe(1);
    expect(h.store.listRuns(10).filter((r) => r.status === 'queued').length).toBe(1);
  });
});
