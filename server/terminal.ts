import { spawnSync } from 'node:child_process';
import { readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Runs an OpenCode session in a real terminal window.
 *
 * Why: the dashboard used to show the session as a read-only log pane, and the
 * owner cannot type into it. In a terminal he can watch, answer a question, or
 * take over — which is the difference between supervising a run and waiting for
 * it.
 *
 * Two consequences of running in a terminal, both deliberate:
 *
 *  1. **No JSON stream.** `opencode run --format json` is what the dashboard
 *     parsed for the summary, the cost and the session id. The interactive
 *     `opencode` writes to a tty instead, so those numbers are unknown. The
 *     changelog falls back to the suggestion's own text, which says more anyway.
 *
 *  2. **Exit code via a file.** The terminal emulator's own process exits as soon
 *     as the window opens, so its exit code says nothing about the session. A
 *     tiny shell wrapper records the pid of the session and its exit code, and
 *     the runner reads those files. That keeps the hard timeout, the cancel
 *     button and the restart-adoption working exactly as before.
 */

/** Terminals we know how to drive, in order of preference. */
const CANDIDATES: { bin: string; args: (title: string, script: string) => string[] }[] = [
  // `--hold` would be nicer, but the trailing `exec bash` in the script keeps
  // the window open for every emulator without a per-emulator flag.
  { bin: 'gnome-terminal', args: (t, s) => ['--title', t, '--', 'bash', '-c', s] },
  { bin: 'konsole', args: (t, s) => ['-p', `tabtitle=${t}`, '-e', 'bash', '-c', s] },
  { bin: 'xfce4-terminal', args: (t, s) => ['--title', t, '--', 'bash', '-c', s] },
  { bin: 'kitty', args: (t, s) => ['--title', t, 'bash', '-c', s] },
  { bin: 'alacritty', args: (t, s) => ['--title', t, '-e', 'bash', '-c', s] },
  { bin: 'wezterm', args: (t, s) => ['start', '--title', t, '--', 'bash', '-c', s] },
  { bin: 'foot', args: (t, s) => ['--title', t, 'bash', '-c', s] },
  { bin: 'xterm', args: (t, s) => ['-title', t, '-e', 'bash', '-c', s] },
  { bin: 'x-terminal-emulator', args: (_t, s) => ['-e', 'bash', '-c', s] },
];

/** Overrides the detection, mostly for tests: `TERMINAL_EMULATOR=…`. */
function preferredBin(): string | null {
  const forced = (process.env.TERMINAL_EMULATOR ?? '').trim();
  return forced || null;
}

function exists(bin: string): boolean {
  const res = spawnSync('command', ['-v', bin], { encoding: 'utf8', shell: '/bin/sh' });
  return res.status === 0;
}

export function findTerminal(): { bin: string; args: (title: string, script: string) => string[] } | null {
  const forced = preferredBin();
  if (forced) {
    const match = CANDIDATES.find((c) => c.bin === forced);
    if (match) return match;
    // An unknown binary is still usable with the most common spelling.
    return { bin: forced, args: (t, s) => ['-e', 'bash', '-c', s] };
  }
  for (const candidate of CANDIDATES) {
    if (exists(candidate.bin)) return candidate;
  }
  return null;
}

export interface TerminalSession {
  bin: string;
  args: string[];
  pidFile: string;
  exitFile: string;
}

/**
 * Builds the launch command. `command` is the argv of the OpenCode call; it is
 * quoted into the wrapper script, so the prompt may contain quotes, newlines and
 * dollar signs.
 */
export function buildTerminalSession(input: {
  bin: string;
  args: (title: string, script: string) => string[];
  title: string;
  cwd: string;
  command: string[];
  stateDir: string;
  runId: string;
}): TerminalSession {
  const pidFile = join(input.stateDir, `${input.runId}.pid`);
  const exitFile = join(input.stateDir, `${input.runId}.exit`);
  const inner = input.command.map(shellQuote).join(' ');
  // The session runs in the background and is `wait`ed for, with a trap that
  // forwards SIGTERM. Without the trap, "Abbrechen" and the hard timeout would
  // kill only this shell and leave the agent running unsupervised — the exact
  // situation those two features exist to prevent. The exit code is written
  // before the window is kept open, and `exec bash` holds the window so the
  // owner can still read the output.
  const script = [
    `echo $$ > ${shellQuote(pidFile)}`,
    `cd ${shellQuote(input.cwd)} || exit 1`,
    'singular80_child=""',
    'trap \'[ -n "$singular80_child" ] && kill -TERM "$singular80_child" 2>/dev/null\' TERM INT',
    `${inner} &`,
    'singular80_child=$!',
    'wait "$singular80_child"',
    `printf '%s' "$?" > ${shellQuote(exitFile)}`,
    'trap - TERM INT',
    'echo',
    "echo '[Singular 80] Lauf beendet. Dieses Fenster schliessen: Strg+D.'",
    'exec bash',
  ].join('\n');
  return { bin: input.bin, args: input.args(input.title, script), pidFile, exitFile };
}

/** Single-quote for /bin/sh. The prompt is player text and may contain anything. */
export function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

export function readPidFile(path: string): number | null {
  const pid = Number(readTrimmed(path));
  return Number.isInteger(pid) && pid > 0 ? pid : null;
}

export function readExitFile(path: string): number | null {
  const raw = readTrimmed(path);
  if (raw === null) return null;
  const code = Number(raw);
  return Number.isInteger(code) ? code : null;
}

function readTrimmed(path: string): string | null {
  try {
    const text = readFileSync(path, 'utf8').trim();
    return text || null;
  } catch {
    return null;
  }
}

/** Clears the state of a finished run so a reused id cannot inherit a result. */
export function clearTerminalState(session: Pick<TerminalSession, 'pidFile' | 'exitFile'>): void {
  for (const file of [session.pidFile, session.exitFile]) {
    try {
      rmSync(file, { force: true });
    } catch {
      /* best effort */
    }
  }
}
