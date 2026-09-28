import { describe, expect, it, afterEach } from 'vitest';
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildTerminalSession, readExitFile } from '../server/terminal';

/**
 * Two real outcomes from the TUI mode, both measured on the owner's desktop and
 * both worth a test because neither is visible in a passing run:
 *
 *  1. **A ghost run.** The TUI never exits by itself — it finishes the work and
 *     waits at a prompt. The window is closed to end the session, and then no
 *     exit file is ever written. The run stayed "läuft" for the full hard
 *     timeout and the queue waited behind a job nobody was doing. Caught by
 *     comparing the recorded pid against the process table, not by a timer.
 *
 *  2. **The wrapper is the parent, the session the child.** Killing the wrapper
 *     alone would leave the agent running unsupervised, so SIGTERM is trapped and
 *     forwarded.
 */

const RUNNER = readFileSync(join(import.meta.dirname, '..', 'server', 'runner.ts'), 'utf-8');

describe('Ein Fenster, das geschlossen wurde, beendet den Lauf', () => {
  it('erkennt eine tote Sitzung auch ohne Exit-Code', () => {
    expect(RUNNER).toContain('!isProcessAlive(entry.pid)');
    expect(RUNNER).toContain("'Im Terminal beendet, ohne Ergebnis zu melden.'");
  });

  it('meldet keinen Erfolg, den niemand bestaetigt hat', () => {
    // The agent's answer lives in the window, not in a file the runner can read.
    // Claiming "implemented" on a guess is the one thing that must not happen.
    const block = RUNNER.slice(RUNNER.indexOf('private finishTerminalRun'));
    expect(block).toContain("'cancelled'");
  });

  it('haelt das harte Zeitlimit ueber ein geschlossenes Fenster hinweg', () => {
    expect(RUNNER).toContain('if (entry.timedOut) return;');
  });
});

describe('Der Modus waehlbar, die Voreinstellung TUI', () => {
  it('ist die TUI, weil der Besitzer sie verlangt hat', () => {
    expect(RUNNER).toContain("?? 'tui'");
    const fn = RUNNER.slice(RUNNER.indexOf('private terminalArgs'));
    expect(fn.indexOf("'--prompt'")).toBeGreaterThan(-1);
  });

  it('startet die Oberflaeche ohne Huelle dazwischen', () => {
    // A full-screen interface as a *background* job is stopped by SIGTTOU on its
    // first write: the window shows a frozen copy and the shell prints
    // `Stopped`. Both measured — with `set -m` stopped, without it never finished.
    const fn = RUNNER.slice(RUNNER.indexOf('private openTerminal'));
    expect(fn).toContain('const tui = this.terminalMode()');
    expect(fn).toContain('buildTerminalCommand');
  });

  it('erkennt die Sitzung an einer Marke, nicht am Prozessbaum', () => {
    // `gnome-terminal` exits the moment the window is open and the session is
    // re-parented, so the emulator's subtree is empty while the session is still
    // on screen — which made a running job report as finished.
    const fn = RUNNER.slice(RUNNER.indexOf('private checkTerminal'));
    expect(fn).toContain('findByEnvMarker(runMarker(entry.record.id))');
  });

  it('legt den Sitzungsspeicher je Lauf beiseite, nicht nur den Server', () => {
    // `--standalone` starts a private *server*; the sessions still live in one
    // shared database, so the new window listed the owner's own sessions.
    // `XDG_DATA_HOME` is the lever that actually moves the store.
    const fn = RUNNER.slice(RUNNER.indexOf('private openTerminal'));
    expect(fn).toContain('isolateDataHome');
    const term = readFileSync(join(import.meta.dirname, '..', 'server', 'terminal.ts'), 'utf8');
    expect(term).toContain('XDG_DATA_HOME=');
  });

  it('meldet das Ende erst, wenn die Sitzung wirklich dagewesen ist', () => {
    // The marker takes a moment to appear; without that guard a run that never
    // started would be reported as finished instead of falling back.
    const fn = RUNNER.slice(RUNNER.indexOf('private checkTerminal'));
    expect(fn).toContain('if (entry.pid !== null)');
  });

  it('beendet in der Oberflaeche die markierte Sitzung', () => {
    const fn = RUNNER.slice(RUNNER.indexOf('private terminate'));
    expect(fn).toContain('[...findByEnvMarker(runMarker(entry.record.id)), entry.terminalTuiPid]');
  });

  it('haelt jeden Lauf in einem eigenen Server, weg vom offenen des Besitzers', () => {
    // Ohne `--standalone` hängt `opencode` sich an den Hintergrunddienst, an dem
    // auch das offene Fenster des Besitzers hängt. Der Lauf landet dann nicht im
    // eigenen Terminal, sondern taucht dort als weitere Sitzung auf und beide
    // Fenster zeigen je eine Hälfte desselben Auftrags. Gemessen an zwei
    // geöffneten Fenstern und einer Sitzung in der Oberfläche des Besitzers.
    const fn = RUNNER.slice(RUNNER.indexOf('private terminalArgs'));
    expect(fn).toContain("'--standalone'");
    expect((fn.match(/--standalone/g) ?? []).length).toBeGreaterThanOrEqual(2);
  });

  it('bietet den selbst beendenden Lauf als Alternative', () => {
    // `run` prints a plain log and ends on its own. Worth having for a long
    // queue nobody watches.
    const fn = RUNNER.slice(RUNNER.indexOf('private terminalArgs'));
    expect(fn).toContain("'run'");
    expect(fn).toContain("'run', '--standalone', '--auto'");
  });
});

describe('Das Wrapper-Skript leitet Signale weiter', () => {
  const dirs: string[] = [];
  afterEach(() => {
    for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
  });

  /** Waits until `check` is true, or fails with a message that says what. */
  async function waitUntil(check: () => boolean, timeout: number, what: string): Promise<void> {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      if (check()) return;
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    throw new Error(`Timeout beim Warten auf ${what}`);
  }

  it('beendet auch das Kind, wenn das Fenster geschlossen wird', async () => {
    const dir = mkdtempSync(join(tmpdir(), 's80-term-trap-'));
    dirs.push(dir);
    const built = buildTerminalSession({
      bin: 'bash',
      args: (t, s) => ['-e', 'bash', '-c', s],
      title: 't',
      cwd: dir,
      // The child announces itself, waits two seconds, then leaves a marker. If
      // SIGTERM is forwarded, it never gets there: a forwarded signal kills the
      // `bash` that would have run `touch`.
      command: ['bash', '-c', 'touch gestartet; sleep 2; touch kind-lebt'],
      stateDir: dir,
      runId: 'run_trap',
    });
    const scriptFile = join(dir, 'w.sh');
    writeFileSync(
      scriptFile,
      built.args[built.args.length - 1].replace(/\nexec bash\n?$/, '\n'),
    );
    const child = spawn('bash', [scriptFile], { stdio: 'ignore' });
    // The marker, not a fixed sleep: a SIGTERM sent before the trap is armed kills
    // the wrapper by accident, and the test would fail for the wrong reason.
    await waitUntil(() => existsSync(join(dir, 'gestartet')), 10_000, 'das gestartete Kind');
    child.kill('SIGTERM');
    // Longer than the child's own two seconds, so a surviving child is caught.
    await new Promise((resolve) => setTimeout(resolve, 3_500));

    // **The marker is the assertion.** `readExitFile` was the only check here, and
    // it cannot tell "the child was killed" from "the child was orphaned and is
    // still working in the tree" — the exit file is missing in both cases, which is
    // the exact failure this file exists for. The old version created the marker
    // and then never looked at it.
    expect(
      existsSync(join(dir, 'kind-lebt')),
      'Das Kind lief weiter: SIGTERM ist nicht angekommen, der Agent arbeitet unbeaufsichtigt.',
    ).toBe(false);
    // The wrapper records the exit code it saw, so a closed window is reported as
    // 143 = 128 + SIGTERM. It used to be asserted as "nothing", which was wrong:
    // the file is written on purpose, and a missing one is what a hard kill of the
    // server looks like.
    expect(readExitFile(built.exitFile)).toBe(143);
  }, 30_000);
});
