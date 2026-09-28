import { spawnSync } from 'node:child_process';
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

function git(projectRoot: string, args: string[]): { ok: boolean; out: string } {
  const res = spawnSync('git', ['-C', projectRoot, ...args], { encoding: 'utf8' });
  return { ok: res.status === 0, out: (res.stdout ?? '').trim() };
}

/** Today's date as `YYYY-MM-DD` in local time — the changelog is read by a person. */
function today(): string {
  const now = new Date();
  const month = String(now.getMonth() + 1).padStart(2, '0');
  const day = String(now.getDate()).padStart(2, '0');
  return `${now.getFullYear()}-${month}-${day}`;
}

/**
 * Collapses a summary to one line and caps its length. A changelog entry that
 * wraps over four lines is a paragraph, and the point of this file is that it
 * can be skimmed in one sitting.
 */
export function entryLine(suggestion: Suggestion, run: RunRecord): string {
  const text = (run.resultSummary ?? suggestion.text).replace(/\s+/g, ' ').trim();
  const clipped = text.length > 100 ? `${text.slice(0, 99)}…` : text;
  // The number leads, because the reader is looking for "which one was this?"
  const hash = run.commitHash ? ` — \`${run.commitHash}\`` : '';
  return `- **#${suggestion.id}** ${clipped}${hash}`;
}

/**
 * Appends the entry, commits it with an explicit path, and pushes. Returns
 * whether the changelog is now on the remote — a `false` is a missing line,
 * never a reason to fail a run.
 */
export function appendChangelog(projectRoot: string, suggestion: Suggestion, run: RunRecord): boolean {
  try {
    const path = join(projectRoot, FILE);
    if (!existsSync(path)) return false;
    const line = entryLine(suggestion, run);
    // Group by day: a new date opens a new section, anything after it is
    // appended to the section that already exists.
    let body = readFileSync(path, 'utf8');
    const date = today();
    if (body.includes(`\n## ${date}\n`)) {
      body = body.replace(new RegExp(`(\n## ${date}\n(?:[^#]*)$)`), `$1${line}\n`);
    } else {
      body = `${body.replace(/\n*$/, '')}\n\n## ${date}\n\n${line}\n`;
    }
    // Written directly rather than through a shell heredoc: the text comes
    // from players, and a shell would read a backtick or `$(` inside a
    // suggestion as a command.
    writeFileSync(path, body, 'utf8');
    // Only this file, by path. Never `add -A`: see the note at the top.
    if (!git(projectRoot, ['add', '--', FILE]).ok) {
      console.warn('[changelog] konnte nicht gestaged werden');
      return false;
    }
    const committed = git(projectRoot, [
      'commit',
      '-m',
      `docs(changelog): #${suggestion.id} implemented`,
      '--',
      FILE,
    ]);
    if (!committed.ok) {
      console.warn('[changelog] commit fehlgeschlagen');
      return false;
    }
    // Pushing is part of the job: a changelog only this server can see is not
    // what was asked for. A detached HEAD or a rebase in progress both mean
    // "not now", so it is skipped with a note instead of a crash.
    const branch = git(projectRoot, ['rev-parse', '--abbrev-ref', 'HEAD']);
    if (!branch.ok || branch.out === 'HEAD') {
      console.warn('[changelog] kein Branch, nicht gepusht');
      return false;
    }
    if (!git(projectRoot, ['push', 'origin', branch.out]).ok) {
      console.warn('[changelog] push fehlgeschlagen — der Eintrag ist aber committed');
    }
    return true;
  } catch (err) {
    console.warn('[changelog] fehlgeschlagen:', (err as Error).message);
    return false;
  }
}
