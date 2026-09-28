import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, symlinkSync } from 'node:fs';
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

/**
 * The direct launch, with no shell in between: `gnome-terminal … -- opencode …`.
 *
 * **A full-screen interface must not be a background job.** With a wrapper that
 * starts it and waits, the session runs in the wrapper's process group, the
 * terminal's foreground group is the wrapper, and the interface's first write
 * raises SIGTTOU: the window shows a frozen copy and the shell prints
 * `Stopped`. Measured both ways — with `set -m` the process is stopped, without
 * it the run never finishes. So in this mode there is no wrapper at all.
 *
 * The cost is the exit code, which the emulator's own process does not have; the
 * runner finds the real session as a descendant and watches that instead.
 */
export function buildTerminalCommand(input: {
  bin: string;
  args: (title: string, script: string) => string[];
  title: string;
  command: string[];
  marker?: string;
  /** Per-run data directory, see `isolateDataHome`. */
  dataHome?: string;
}): { bin: string; argv: string[] } {
  // `env` carries the run id into the session — the handle that survives the
  // emulator re-parenting — and moves the session store somewhere private.
  //
  // `--standalone` is not enough for that: it starts a private *server*, but the
  // sessions live in one shared database on disk, so the new window lists the
  // owner's own sessions. `XDG_DATA_HOME` is what actually moves the store, and
  // it is the documented XDG lever rather than a trick.
  const env: string[] = [];
  if (input.marker) env.push(input.marker);
  if (input.dataHome) env.push(`XDG_DATA_HOME=${input.dataHome}`);
  const parts = env.length > 0 ? ['env', ...env, ...input.command] : input.command;
  // The same argv builder, but the "script" is the command itself, so every
  // emulator spelling stays in one place.
  const joined = parts.map(shellQuote).join(' ');
  return { bin: input.bin, argv: input.args(input.title, joined) };
}

/**
 * Finds a process by an environment marker — our own `env` wrapper puts the run
 * id in the session's environment.
 *
 * Needed because the process tree is not usable here: `gnome-terminal` exits the
 * moment the window is open, and the session is re-parented to
 * `gnome-terminal-server`. So the emulator's pid dies immediately and the session
 * is not below it, which made the runner report a finished run that was still on
 * screen. An environment marker survives re-parenting and is unique per run, so
 * it is the one handle that actually identifies *this* session.
 */
export function findByEnvMarker(marker: string): number[] {
  const found: number[] = [];
  let entries: string[] = [];
  try {
    entries = readdirSync('/proc').filter((name) => /^\d+$/.test(name));
  } catch {
    return found;
  }
  for (const name of entries) {
    const pid = Number(name);
    if (pid === process.pid) continue;
    try {
      const env = readFileSync(`/proc/${pid}/environ`, 'utf8');
      if (env.split('\0').includes(marker)) found.push(pid);
    } catch {
      /* not ours to read */
    }
  }
  return found;
}

/**
 * A private data directory for one run, with the parts of the owner's store it
 * needs.
 *
 * Only what must be shared is linked in: the configuration (their models,
 * providers, agents) and the credentials. Sessions, logs, snapshots and the shell
 * scratch space stay out, so the run's window shows an empty session list instead
 * of the owner's, and its own files cannot collide with theirs.
 */
export function isolateDataHome(runId: string, base: string, ownerHome: string): string {
  // `base` is where the isolated homes live (the project's data directory, which
  // is git-ignored); `ownerHome` is where the credentials are borrowed from.
  const dir = join(base, 'opencode-runs', runId);
  mkdirSync(dir, { recursive: true });
  // `auth.json` is the credential store and lives inside the data directory. If
  // the provider keeps its key there — it does on this machine — a run without it
  // cannot authenticate at all, which is worse than a shared session list.
  for (const name of ['auth.json']) {
    const source = join(ownerHome, '.local', 'share', 'opencode', name);
    const target = join(dir, name);
    try {
      if (!existsSync(target) && existsSync(source)) symlinkSync(source, target);
    } catch {
      /* best effort: the run may still find its credentials elsewhere */
    }
  }
  return dir;
}

/** The marker a session carries, unique per run. */
export function runMarker(runId: string): string {
  return `SINGULAR80_RUN=${runId}`;
}

/** Every live process below `pid`, deepest last. Reads /proc, no dependencies. */
export function descendantsOf(pid: number): number[] {
  const found: number[] = [];
  let frontier = [pid];
  for (let depth = 0; depth < 8 && frontier.length > 0; depth += 1) {
    const next: number[] = [];
    for (const parent of frontier) {
      let entries: string[] = [];
      try {
        entries = readdirSync('/proc').filter((name) => /^\d+$/.test(name));
      } catch {
        return found;
      }
      for (const name of entries) {
        const stat = readStatOf(Number(name));
        if (stat && stat.ppid === parent) {
          const child = Number(name);
          if (!found.includes(child)) {
            found.push(child);
            next.push(child);
          }
        }
      }
    }
    frontier = next;
  }
  return found;
}

function readStatOf(pid: number): { ppid: number } | null {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, 'utf8');
    // The executable name may contain spaces and parentheses, so the fields after
    // the last ')' are the reliable ones.
    const after = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
    return { ppid: Number(after[1]) };
  } catch {
    return null;
  }
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
    // Job control, and it is not optional. Without `set -m` the backgrounded
    // session stays in the wrapper's own process group, and a full-screen
    // interface in that group never finishes: measured, it ran until a 120 s
    // test timeout killed it. With job control the session gets its own process
    // group and becomes the terminal's foreground job — which is what the
    // interface needs in order to draw and to read the keyboard — and the trap
    // below can still reach it.
    'set -m',
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
