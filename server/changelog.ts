import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { RunRecord, Suggestion } from '../src/shared/types';

/**
 * The changelog of implemented suggestions — one or two lines each, in
 * `CHANGELOG.md`, committed and pushed so it lands on GitHub alongside the work
 * it describes.
 *
 * Three decisions worth stating, because the obvious alternative is worse:
 *
 * 1. **The runner writes it, not the agent that implemented the suggestion.**
 *    That agent is a separate session that may crash, time out, or be the very
 *    one that left a half-finished tree behind. The runner is the only party
 *    that knows *for certain* the run succeeded, so it is the only one allowed
 *    to claim it. An agent writing its own praise into the changelog can just as
 *    easily write it for a run that failed.
 *
 * 2. **Its own commit, staging only its own file.** The working tree is shared
 *    with concurrent runs (see AGENTS.md), so the changelog is committed with an
 *    explicit pathspec. A `git add -A` here would sweep a half-finished session
 *    into the repository — the exact failure this project has been bitten by.
 *
 * 3. **A failure is never fatal.** A changelog missing one line is a missing
 *    line; a runner that threw because a changelog write failed would mark a
 *    good run as broken. Everything here is best-effort and says so in the log.
 */

const FILE = 'CHANGELOG.md';

/**
 * Upper bound for every git call, in milliseconds.
 *
 * The function is synchronous, so a git that never answers freezes the whole
 * server: the SSE stream, the Telegram poll, the supervisor tick and the queue
 * behind it. The old comment claimed "the process is about to exit anyway" —
 * true of nothing here, this is called from the runner's `finalize` while five
 * other things are waiting their turn. A local git call gets a tight bound, a
 * push (network, DNS, a credential prompt) a generous one. `GIT_TERMINAL_PROMPT`
 * is what turns a hanging connect into an error at all.
 */
const GIT_TIMEOUT_MS = 10_000;
const PUSH_TIMEOUT_MS = 15_000;

/** One retry, not three: the old loop slept 2 s + 4 s *between attempts*. */
const PUSH_ATTEMPTS = 2;

/** What a `git push` failed with, in one line — the warnings below say nothing without it. */
function git(projectRoot: string, args: string[], timeoutMs = GIT_TIMEOUT_MS): { ok: boolean; out: string; err: string } {
  const res = spawnSync('git', ['-C', projectRoot, ...args], {
    encoding: 'utf8',
    timeout: timeoutMs,
    killSignal: 'SIGKILL',
    env: { ...process.env, GIT_TERMINAL_PROMPT: '0' },
  });
  const stderr = (res.stderr ?? '').trim();
  const reason = res.error
    ? res.error.message
    : res.signal
      ? `Signal ${res.signal}`
      : stderr || (res.status === null ? 'kein Exit-Code' : `exit ${res.status}`);
  return { ok: res.status === 0, out: (res.stdout ?? '').trim(), err: reason };
}

/**
 * A blocking delay of a few hundred milliseconds, without a subprocess.
 *
 * The old `spawnSync('sleep', …)` cost a process *and* the event loop for two
 * seconds per gap. `Atomics.wait` on a shared buffer is the same block without
 * either, which is the whole point: the API is synchronous, so there is no
 * cheaper way to space two push attempts apart.
 */
function briefDelay(ms: number): void {
  const shared = new Int32Array(new SharedArrayBuffer(4));
  Atomics.wait(shared, 0, 0, ms);
}

/** Today's date as `YYYY-MM-DD` in local time — the changelog is read by a person. */
function today(): string {
  const now = new Date();
  const month = String(now.getMonth() + 1).padStart(2, '0');
  const day = String(now.getDate()).padStart(2, '0');
  return `${now.getFullYear()}-${month}-${day}`;
}

/** Caps a line at the same width everywhere, whatever it describes. */
function clipText(text: string): string {
  const flat = text.replace(/\s+/g, ' ').trim();
  return flat.length > 100 ? `${flat.slice(0, 99)}…` : flat;
}

/**
 * Collapses a summary to one line and caps its length. A changelog entry that
 * wraps over four lines is a paragraph, and the point of this file is that it
 * can be skimmed in one sitting.
 */
export function entryLine(suggestion: Suggestion, run: RunRecord): string {
  const text = clipText(run.resultSummary ?? suggestion.text);
  // The number leads, because the reader is looking for "which one was this?"
  const hash = run.commitHash ? ` — \`${run.commitHash}\`` : '';
  return `- **#${suggestion.id}** ${text}${hash}`;
}

/**
 * The invisible tag that makes an entry idempotent.
 *
 * `appendLine` writes the file and then commits it, and a crash in between leaves
 * the line in the tree with no commit — so the next `finalize` for the same run
 * writes it a second time and a second commit claims the same work. A run id in
 * an HTML comment survives that round trip: markdown renders nothing, and the
 * check is exact instead of "does some line look like this one".
 *
 * The suggestion id is part of the tag because one run row is per suggestion, and
 * a run id alone would let a second entry for another suggestion in the same
 * chain be swallowed.
 */
function entryTag(suggestion: Suggestion, run: RunRecord): string {
  return `<!-- ${suggestion.id}:${run.id} -->`;
}

function sessionTag(text: string): string {
  return `<!-- session:${createHash('sha1').update(text).digest('hex').slice(0, 12)} -->`;
}

/**
 * The line for work that came from a normal session rather than from a
 * suggestion — the owner asked for a fix, an agent made it, and there is no
 * number to point at.
 *
 * `edi:` rather than a name: it is a prefix you can search for, it does not
 * change when someone works here, and it does not pretend to be a suggestion
 * id. Without a marker like this the file would mix "the bot implemented #12"
 * with "I fixed the thing you reported" in the same voice, and the first would
 * look as automatic as the second.
 */
export function sessionEntryLine(text: string): string {
  return `- **edi:** ${clipText(text)}`;
}

/**
 * Appends the entry, commits it with an explicit path, and pushes. Returns
 * whether the changelog is now on the remote — a `false` is a missing line,
 * never a reason to fail a run.
 */
export function appendChangelog(projectRoot: string, suggestion: Suggestion, run: RunRecord): boolean {
  return appendLine(
    projectRoot,
    entryLine(suggestion, run),
    `docs(changelog): #${suggestion.id} implemented`,
    entryTag(suggestion, run),
  );
}

/** The same, for a change that has no suggestion behind it. */
export function appendSessionEntry(projectRoot: string, text: string): boolean {
  return appendLine(projectRoot, sessionEntryLine(text), 'docs(changelog): session change', sessionTag(text));
}

/** The branch the changelog is allowed to land on. */
const PUSH_BRANCH = 'main';

function appendLine(projectRoot: string, line: string, commitMessage: string, tag: string): boolean {
  try {
    const path = join(projectRoot, FILE);
    if (!existsSync(path)) return false;
    // Group by day: a new date opens a new section, anything after it is
    // appended to the section that already exists.
    let body = readFileSync(path, 'utf8');
    // Already in the file: a previous attempt got as far as the write and died
    // before its commit, or this run was finalized twice. Either way the line is
    // there and must not be added a second time in a second commit.
    if (body.includes(tag)) {
      console.warn(`[changelog] Eintrag ${tag} steht schon in der Datei — nicht erneut geschrieben`);
      return false;
    }
    const date = today();
    const heading = `\n## ${date}\n`;
    const entry = `${line} ${tag}`;
    if (body.includes(heading)) {
      // Append at the end of the day's section, which runs until the next
      // heading. The earlier version inserted right after the heading, which
      // reversed the order and — worse — a `$1` referencing a group that had
      // not matched wrote the *original* text back and silently dropped the
      // entry. That is how #7 went missing.
      const start = body.indexOf(heading) + heading.length;
      const next = body.indexOf('\n## ', start);
      const end = next === -1 ? body.length : next + 1;
      const section = body.slice(start, end).replace(/\n*$/, '\n');
      body = `${body.slice(0, start)}${section}${entry}\n${body.slice(end)}`;
    } else {
      body = `${body.replace(/\n*$/, '')}\n\n## ${date}\n\n${entry}\n`;
    }
    // Written directly rather than through a shell heredoc: the text comes
    // from players and from the owner, and a shell would read a backtick or
    // `$(` inside it as a command.
    writeFileSync(path, body, 'utf8');
    // Only this file, by path. Never `add -A`: see the note at the top.
    const staged = git(projectRoot, ['add', '--', FILE]);
    if (!staged.ok) {
      console.warn('[changelog] konnte nicht gestaged werden:', staged.err);
      return false;
    }
    const committed = git(projectRoot, ['commit', '-m', commitMessage, '--', FILE]);
    if (!committed.ok) {
      console.warn('[changelog] commit fehlgeschlagen:', committed.err);
      return false;
    }
    // Pushing is part of the job: a changelog only this server can see is not
    // what was asked for. A detached HEAD or a rebase in progress both mean
    // "not now", so it is skipped with a note instead of a crash.
    const branch = git(projectRoot, ['rev-parse', '--abbrev-ref', 'HEAD']);
    if (!branch.ok || branch.out === 'HEAD') {
      console.warn('[changelog] kein Branch, nicht gepusht:', branch.err);
      return false;
    }
    // `main` and only `main`. Pushing whatever happens to be checked out is how a
    // changelog line ends up on a `wip/*` branch that nobody merges, while the
    // branch this repository actually ships stays one entry behind.
    if (branch.out !== PUSH_BRANCH) {
      console.warn(`[changelog] auf Branch ${branch.out} — nicht auf ${PUSH_BRANCH} gepusht, Eintrag bleibt lokal`);
      return false;
    }
    // Retry once. A run that commits while `tsx watch` restarts the server, or
    // while another session pushes at the same moment, loses the race once and
    // would otherwise leave the changelog local — which is the one outcome this
    // file exists to avoid. The gap is a fraction of the old 2 s + 4 s, because
    // the loop around it is blocking the event loop.
    for (let attempt = 0; attempt < PUSH_ATTEMPTS; attempt += 1) {
      const pushed = git(projectRoot, ['push', 'origin', PUSH_BRANCH], PUSH_TIMEOUT_MS);
      if (pushed.ok) return true;
      if (attempt < PUSH_ATTEMPTS - 1) briefDelay(500);
      else console.warn('[changelog] push fehlgeschlagen — der Eintrag ist committed, aber lokal:', pushed.err);
    }
    return false;
  } catch (err) {
    console.warn('[changelog] fehlgeschlagen:', (err as Error).message);
    return false;
  }
}
