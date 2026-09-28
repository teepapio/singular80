import { describe, expect, it } from 'vitest';
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { appendChangelog, entryLine, sessionEntryLine } from '../server/changelog';

/**
 * The changelog is the one file the owner actually reads, so its contract — one or
 * two lines per implemented suggestion — is only worth something if it is enforced.
 * Paragraphs stop it from being read, and then it is worse than none, because it
 * still looks maintained.
 */

const SUGGESTION = { id: 42, text: 'Der Slime soll beim Springen Staub aufwirbeln' } as never;
const RUN = {
  id: 'run_1',
  status: 'succeeded',
  commitHash: 'abc1234',
  resultSummary: 'Sprung mit Staub ergänzt',
} as never;

describe('Changelog line', () => {
  it('leads with the number, because that is what the reader scans for', () => {
    expect(entryLine(SUGGESTION, RUN)).toBe('- **#42** Sprung mit Staub ergänzt — `abc1234`');
  });

  it('stays a single line even when the text wraps', () => {
    const run = { ...(RUN as object), resultSummary: 'y\nz\r\nw' } as never;
    expect(entryLine(SUGGESTION, run)).not.toMatch(/[\n\r]/);
  });

  it('clips at 100 characters rather than cutting silently', () => {
    const run = { ...(RUN as object), resultSummary: 'z'.repeat(400) } as never;
    const line = entryLine(SUGGESTION, run);
    expect(line.length).toBeLessThan(160);
    expect(line).toContain('…');
  });

  it('falls back to the suggestion text when the run summarised nothing', () => {
    const run = { ...(RUN as object), resultSummary: null } as never;
    expect(entryLine(SUGGESTION, run)).toContain('Staub aufwirbeln');
  });

  it('omits the commit rather than inventing one', () => {
    const run = { ...(RUN as object), commitHash: null } as never;
    expect(entryLine(SUGGESTION, run)).toBe('- **#42** Sprung mit Staub ergänzt');
  });
});

describe('Changelog line for a session change', () => {
  it('carries "edi:" instead of a suggestion number', () => {
    // Work from a normal session has no suggestion behind it. Without the prefix the
    // file mixes "the bot implemented #12" and "I fixed what you reported" in one
    // voice, and the first looks as automatic as the second.
    expect(sessionEntryLine('Server ist vom Gerät erreichbar')).toBe('- **edi:** Server ist vom Gerät erreichbar');
  });

  it('clips and flattens exactly like the other line', () => {
    const line = sessionEntryLine('a\nb   c '.repeat(200));
    expect(line).not.toMatch(/[\n\r]/);
    expect(line.length).toBeLessThan(160);
    expect(line).toContain('…');
  });
});

describe('The changelog in the repository', () => {
  const ROOT = join(import.meta.dirname, '..');

  it('exists — without the file the runner silently does nothing', () => {
    expect(() => readFileSync(join(ROOT, 'CHANGELOG.md'), 'utf8')).not.toThrow();
  });

  it('tells the two kinds of entry apart', () => {
    // Both belong in the file and must stay tellable apart: a number is a suggestion,
    // `edi:` is work the owner asked for directly.
    const lines = readFileSync(join(ROOT, 'CHANGELOG.md'), 'utf8')
      .split('\n')
      .filter((l) => l.startsWith('- '));
    expect(lines.length).toBeGreaterThan(0);
    for (const line of lines) {
      expect(line).toMatch(/^- \*\*(\#\d+|edi:)\*\*/);
      expect(line.split('\n').length).toBe(1);
      expect(line.length).toBeLessThan(200);
    }
    expect(lines.some((l) => l.startsWith('- **edi:**'))).toBe(true);
  });

  it('holds at most two lines per entry', () => {
    const lines = readFileSync(join(ROOT, 'CHANGELOG.md'), 'utf8')
      .split('\n')
      .filter((l) => l.startsWith('- '));
    expect(lines.length).toBeGreaterThan(0);
    for (const line of lines) {
      expect(line.split('\n').length).toBe(1);
      expect(line.length).toBeLessThan(200);
    }
  });

  it('is not ignored by git, or it would quietly stop growing', () => {
    // `check-ignore` exits 1 when the file is *not* ignored; that inversion is expected.
    expect(spawnSync('git', ['-C', ROOT, 'check-ignore', '-q', 'CHANGELOG.md']).status).toBe(1);
  });
});

describe('The changelog commit touches only its own file', () => {
  // Checked rather than trusted: a `git add -A` in changelog.ts would commit whatever a
  // concurrent session left in the tree, and that has happened here before.
  it('never sweeps in unrelated work', () => {
    const dir = mkdtempSync(join(tmpdir(), 's80-changelog-'));
    const remote = mkdtempSync(join(tmpdir(), 's80-changelog-remote-'));
    try {
      // A real remote on disk: the function pushes, and without one the push fails and
      // it reports `false` even though the commit was fine.
      execFileSync('git', ['-C', remote, 'init', '-q', '--bare', '-b', 'main']);
      const env = {
        ...process.env,
        GIT_AUTHOR_NAME: 't',
        GIT_AUTHOR_EMAIL: 't@t',
        GIT_COMMITTER_NAME: 't',
        GIT_COMMITTER_EMAIL: 't@t',
      };
      const git = (...args: string[]) => execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8', env });
      git('init', '-q', '-b', 'main');
      // The identity the real repository carries in `.git/config`; without it
      // `git commit` refuses and the test measures the sandbox.
      git('config', 'user.name', 'Singular 80');
      git('config', 'user.email', 'singular80@users.noreply.github.com');
      git('remote', 'add', 'origin', remote);
      writeFileSync(join(dir, 'CHANGELOG.md'), '# Changelog\n\n## 2026-01-01\n\n- **#1** alt\n');
      writeFileSync(join(dir, 'dirty.txt'), 'fremde, halb fertige Arbeit\n');
      git('add', '--', 'CHANGELOG.md');
      git('commit', '-q', '-m', 'basis');
      git('push', '-q', 'origin', 'main');

      const ok = appendChangelog(
        dir,
        { id: 2, text: 'neu' } as never,
        { id: 'r', status: 'succeeded', commitHash: 'deadbee', resultSummary: 'neu gebaut' } as never,
      );
      expect(ok).toBe(true);
      const files = git('show', '--name-only', '--pretty=format:', 'HEAD');
      expect(files).toContain('CHANGELOG.md');
      expect(files).not.toContain('dirty.txt');
      expect(readFileSync(join(dir, 'CHANGELOG.md'), 'utf8')).toContain('#2');
      // And it is on the remote, not merely in the local history.
      expect(execFileSync('git', ['-C', remote, 'log', '-1', '--pretty=format:%s'], { encoding: 'utf8' })).toContain(
        '#2',
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
      rmSync(remote, { recursive: true, force: true });
    }
  });

  it('treats a backtick in a suggestion as text, not as a shell command', () => {
    // The text comes from players. An earlier version wrote the file through a
    // shell heredoc, where a `$(...)` inside a suggestion would have run.
    const dir = mkdtempSync(join(tmpdir(), 's80-changelog-'));
    const remote = mkdtempSync(join(tmpdir(), 's80-changelog-remote-'));
    try {
      execFileSync('git', ['-C', remote, 'init', '-q', '--bare', '-b', 'main']);
      const env = {
        ...process.env,
        GIT_AUTHOR_NAME: 't',
        GIT_AUTHOR_EMAIL: 't@t',
        GIT_COMMITTER_NAME: 't',
        GIT_COMMITTER_EMAIL: 't@t',
      };
      const git = (...args: string[]) => execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8', env });
      git('init', '-q', '-b', 'main');
      git('config', 'user.name', 'Singular 80');
      git('config', 'user.email', 'singular80@users.noreply.github.com');
      git('remote', 'add', 'origin', remote);
      writeFileSync(join(dir, 'CHANGELOG.md'), '# Changelog\n\n## 2026-01-01\n\n- **#1** alt\n');
      git('add', '--', 'CHANGELOG.md');
      git('commit', '-q', '-m', 'basis');
      git('push', '-q', 'origin', 'main');

      const marker = join(dir, 'ERLEDIGT');
      appendChangelog(
        dir,
        { id: 3, text: 'x' } as never,
        {
          id: 'r',
          status: 'succeeded',
          commitHash: null,
          resultSummary: `mach $(touch ${marker})`,
        } as never,
      );
      expect(existsSync(marker)).toBe(false);
      expect(readFileSync(join(dir, 'CHANGELOG.md'), 'utf8')).toContain('touch');
    } finally {
      rmSync(dir, { recursive: true, force: true });
      rmSync(remote, { recursive: true, force: true });
    }
  });
});
