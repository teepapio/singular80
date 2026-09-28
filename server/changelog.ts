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

/** Blocking sleep: the process is about to exit anyway, nothing else needs the thread. */
function sleep(ms: number): void {
  spawnSync('sleep', [String(ms / 1000)]);
}

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
  return appendLine(projectRoot, entryLine(suggestion, run), `docs(changelog): #${suggestion.id} implemented`);
}

/** The same, for a change that has no suggestion behind it. */
export function appendSessionEntry(projectRoot: string, text: string): boolean {
  return appendLine(projectRoot, sessionEntryLine(text), 'docs(changelog): session change');
}

function appendLine(projectRoot: string, line: string, commitMessage: string): boolean {
  try {
    const path = join(projectRoot, FILE);
    if (!existsSync(path)) return false;
    // Group by day: a new date opens a new section, anything after it is
    // appended to the section that already exists.
    let body = readFileSync(path, 'utf8');
    const date = today();
    const heading = `\n## ${date}\n`;
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
      body = `${body.slice(0, start)}${section}${line}\n${body.slice(end)}`;
    } else {
      body = `${body.replace(/\n*$/, '')}\n\n## ${date}\n\n${line}\n`;
    }
    // Written directly rather than through a shell heredoc: the text comes
    // from players and from the owner, and a shell would read a backtick or
    // `$(` inside it as a command.
    writeFileSync(path, body, 'utf8');
    // Only this file, by path. Never `add -A`: see the note at the top.
    if (!git(projectRoot, ['add', '--', FILE]).ok) {
      console.warn('[changelog] konnte nicht gestaged werden');
      return false;
    }
    const committed = git(projectRoot, ['commit', '-m', commitMessage, '--', FILE]);
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
    // Retry the push a few times. A run that commits while `tsx watch` restarts
    // the server, or while another session pushes at the same moment, loses the
    // race once and would otherwise leave the changelog local — which is the
    // one outcome this file exists to avoid.
    for (let attempt = 0; attempt < 3; attempt += 1) {
      if (git(projectRoot, ['push', 'origin', branch.out]).ok) return true;
      if (attempt < 2) sleep(2000 * (attempt + 1));
    }
    console.warn('[changelog] push nach 3 Versuchen fehlgeschlagen — der Eintrag ist committed, aber lokal');
    return false;
  } catch (err) {
    console.warn('[changelog] fehlgeschlagen:', (err as Error).message);
    return false;
  }
}
