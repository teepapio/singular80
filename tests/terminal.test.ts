import { describe, expect, it, afterEach } from 'vitest';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { buildTerminalSession, readExitFile, readPidFile, shellQuote } from '../server/terminal';

/**
 * The session runs in a terminal window now, so two things the runner depends on
 * have to survive it: the exit code and the process id. The emulator's own
 * process exits as soon as the window opens, which is why a small shell wrapper
 * writes both to files.
 */

const args = (title: string, script: string) => ['-e', 'bash', '-c', script];

/**
 * Temp directories are cleaned here and not as the last line of each case: a
 * failing assertion used to leave the directory behind for the rest of the run.
 */
const tempDirs: string[] = [];

afterEach(() => {
  for (const dir of tempDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function tempDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

function session(overrides: Partial<Parameters<typeof buildTerminalSession>[0]> = {}) {
  const dir = tempDir('s80-term-');
  return {
    dir,
    built: buildTerminalSession({
      bin: 'xterm',
      args,
      title: 'Singular 80 — #7',
      cwd: '/home/edi/singular80',
      command: ['opencode', 'run', '--auto', 'Der Slime soll springen'],
      stateDir: dir,
      runId: 'run_x',
      ...overrides,
    }),
  };
}

describe('Die Kommandozeile fuer das Terminal', () => {
  it('gibt pid- und exit-Datei im Zustandsordner an', () => {
    const { built, dir } = session();
    expect(built.pidFile).toBe(join(dir, 'run_x.pid'));
    expect(built.exitFile).toBe(join(dir, 'run_x.exit'));
  });

  it('schreibt den Exit-Code ueber den Erfolg der Sitzung', () => {
    // The runner reads this; without it a finished run would look like a crash.
    const { built, dir } = session();
    const script = built.args[built.args.length - 1];
    expect(script).toContain(`printf '%s' "$?"`);
    expect(script).toContain(shellQuote(built.exitFile));
  });

  it('leitet SIGTERM an die Sitzung weiter', () => {
    // Cancel and the hard timeout kill the wrapper. Without the trap the agent
    // would keep running unsupervised — exactly what those two prevent.
    const { built, dir } = session();
    const script = built.args[built.args.length - 1];
    expect(script).toContain('trap');
    expect(script).toContain('kill -TERM');
  });

  it('schaltet Job-Control ein, sonst endet die Oberflaeche nie', () => {
    // Measured: without `set -m` the backgrounded session keeps the wrapper's
    // process group, and the interface never finishes — the test had to be
    // killed at its 120 s timeout. With it the session is a real foreground job
    // and completes.
    const { built, dir } = session();
    expect(built.args[built.args.length - 1]).toContain('set -m');
  });

  it('haelt das Fenster offen, damit die Ausgabe lesbar bleibt', () => {
    const { built, dir } = session();
    expect(built.args[built.args.length - 1]).toContain('exec bash');
  });

  it('schuetzt einen Auftragstext mit Anfuehrungszeichen und Dollarzeichen', () => {
    // The prompt is player text: a `$(...)` or a quote in it must not run.
    const { built, dir } = session({ command: ['opencode', '--prompt', "mach's $(rm -rf /) 'x'"] });
    const script = built.args[built.args.length - 1];
    expect(script).toContain(`'\\''`);
    // The dangerous text is inside quotes, so the substitution cannot fire.
    expect(script).not.toMatch(/^\s*\$\(/m);
  });

  it('wechselt vor dem Start in das Projektverzeichnis', () => {
    const { built, dir } = session();
    expect(built.args[built.args.length - 1]).toContain(`cd ${shellQuote('/home/edi/singular80')}`);
  });
});

describe('Das Wrapper-Skript laeuft wirklich', () => {
  it('liefert pid und exit-Code einer echten Sitzung', () => {
    // The script is what the runner depends on, so it is executed rather than
    // only pattern-matched: a shell that fails to parse would look fine here.
    const dir = mkdtempSync(join(tmpdir(), 's80-term-run-'));
    try {
      const built = buildTerminalSession({
        bin: 'bash',
        args,
        title: 't',
        cwd: dir,
        command: ['bash', '-c', 'exit 3'],
        stateDir: dir,
        runId: 'run_real',
      });
      const script = built.args[built.args.length - 1].replace(/\nexec bash\n?$/, '\n');
      const scriptFile = join(dir, 'wrapper.sh');
      writeFileSync(scriptFile, script);
      spawnSync('bash', [scriptFile], { encoding: 'utf8' });
      expect(readPidFile(built.pidFile)).toBeGreaterThan(0);
      expect(readExitFile(built.exitFile)).toBe(3);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('meldet 0 bei einer erfolgreichen Sitzung', () => {
    const dir = mkdtempSync(join(tmpdir(), 's80-term-ok-'));
    try {
      const built = buildTerminalSession({
        bin: 'bash',
        args,
        title: 't',
        cwd: dir,
        command: ['bash', '-c', 'true'],
        stateDir: dir,
        runId: 'run_ok',
      });
      const scriptFile = join(dir, 'w.sh');
      writeFileSync(scriptFile, built.args[built.args.length - 1].replace(/\nexec bash\n?$/, '\n'));
      spawnSync('bash', [scriptFile], { encoding: 'utf8' });
      expect(readExitFile(built.exitFile)).toBe(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('Das Lesen der Zustandsdateien', () => {
  it('liefert null, solange die Sitzung noch schreibt', () => {
    const dir = mkdtempSync(join(tmpdir(), 's80-term-miss-'));
    try {
      expect(readPidFile(join(dir, 'nope.pid'))).toBeNull();
      expect(readExitFile(join(dir, 'nope.exit'))).toBeNull();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('erkennt eine halb geschriebene Datei nicht als Ergebnis', () => {
    const dir = mkdtempSync(join(tmpdir(), 's80-term-half-'));
    try {
      const file = join(dir, 'half.exit');
      writeFileSync(file, '   ');
      expect(readExitFile(file)).toBeNull();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
