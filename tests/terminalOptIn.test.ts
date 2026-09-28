import { describe, expect, it, afterEach, vi } from 'vitest';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readFileSync } from 'node:fs';

/**
 * The terminal windows were my mistake, and this test is the reason it cannot
 * happen again.
 *
 * Making "run in a terminal" the runner's default meant the test suite — which
 * builds a Runner around a *fake* `opencode` binary in a temp directory — opened
 * a real gnome-terminal window for every single case. The owner got a stream of
 * windows while the tests ran.
 *
 * So: the Runner must do nothing unless the application explicitly asks. That is
 * asserted against the source, because the failure was a missing opt-in, and a
 * missing opt-in is exactly what a test of behaviour would miss.
 */

const RUNNER = readFileSync(join(import.meta.dirname, '..', 'server', 'runner.ts'), 'utf8');
const APP = readFileSync(join(import.meta.dirname, '..', 'server', 'app.ts'), 'utf8');
const INDEX = readFileSync(join(import.meta.dirname, '..', 'server', 'index.ts'), 'utf8');

describe('Terminalfenster nur auf ausdruecklichen Wunsch', () => {
  it('der Runner oeffnet ohne Opt-in gar nichts', () => {
    // The exact line that stops the windows. If it ever becomes `!== false`
    // again, every runner test opens a window on the desktop.
    expect(RUNNER).toContain('if (this.options.terminalMode !== true) return null;');
  });

  it('nur die Anwendung darf es einschalten', () => {
    expect(APP).toContain('terminalMode: options.terminalRuns === true');
    // The tests construct a Runner directly and pass no such option.
    expect(APP).toContain('terminalRuns?: boolean;');
  });

  it('der Einstiegspunkt entscheidet es und sagt es', () => {
    expect(INDEX).toContain('terminalRuns,');
    expect(INDEX).toContain('findTerminal()');
  });

  it('ein Schalter im Environment schaltet es aus', () => {
    // A session the owner cannot watch is worse than a quiet one, and turning it
    // off must not require a code change.
    expect(RUNNER).toContain("process.env.S80_TERMINAL === '0'");
    expect(INDEX).toContain("process.env.S80_TERMINAL !== '0'");
  });
});

describe('Kein Fenster, wenn der Test laeuft', () => {
  const dirs: string[] = [];
  afterEach(() => {
    for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
  });

  it('ein Runner ohne terminalMode oeffnet kein Terminal', async () => {
    // Checked through a side effect that survives the process: a terminal run
    // writes `run/terminal/<runId>.pid`. No such file means no window was
    // opened — which is exactly what went wrong, since the whole suite runs
    // against a fake `opencode` binary.
    const { Runner } = await import('../server/runner');
    const { Store } = await import('../server/db');
    const { mkdtempSync: mk, existsSync, writeFileSync, chmodSync } = await import('node:fs');
    const dir = mk(join(tmpdir(), 's80-noterm-data-'));
    const repo = mk(join(tmpdir(), 's80-noterm-repo-'));
    dirs.push(dir, repo);

    const fake = join(repo, 'fake-opencode');
    writeFileSync(fake, '#!/bin/sh\nsleep 0.2\n');
    chmodSync(fake, 0o755);
    process.env.OPENCODE_BIN = fake;

    const store = new Store(dir);
    const runner = new Runner(store, {
      projectRoot: repo,
      dataDir: dir,
      contentDir: join(repo, 'content'),
      callbacks: {},
    });
    const suggestion = store.createSuggestion({
      text: 'Tetris: mehr Bälle am Stück',
      author: 'Anonym',
      source: 'game',
      category: 'mechanics',
      canonicalId: null,
      status: 'approved',
    });
    runner.enqueue(suggestion, store.getSettings(), [suggestion]);
    await new Promise((r) => setTimeout(r, 250));
    runner.dispose();
    delete process.env.OPENCODE_BIN;

    expect(existsSync(join(repo, 'run', 'terminal'))).toBe(false);
  });
});
