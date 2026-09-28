import { describe, expect, it } from 'vitest';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { appendChangelog, entryLine } from '../server/changelog';

/**
 * The runner's counterpart to the shared tree: it commits while other sessions
 * are mid-work. These tests build a repository that is *dirty* in the ways a
 * real one is at that moment, because an empty working tree proves nothing —
 * every bug found here happened with files already staged by someone else.
 */

const SUGGESTION = { id: 7, text: 'mach den slime ein bisschen langsamer' } as never;
const RUN = {
  id: 'run_1',
  status: 'succeeded',
  commitHash: 'b2110c6',
  resultSummary: 'speed 38 → 32',
} as never;

function repo() {
  const dir = mkdtempSync(join(tmpdir(), 's80-cl-'));
  const remote = mkdtempSync(join(tmpdir(), 's80-cl-remote-'));
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
  return { dir, remote, git };
}

describe('Der Changelog-Commit im geteilten Baum', () => {
  it('rührt nichts mit an, was eine andere Sitzung gerade gestaged hat', () => {
    const { dir, git } = repo();
    try {
      // A concurrent session staged work of its own. The changelog commit must
      // not carry it, and must not be refused because of it.
      writeFileSync(join(dir, 'fremde-arbeit.txt'), 'halbfertig\n');
      git('add', 'fremde-arbeit.txt');
      expect(appendChangelog(dir, SUGGESTION, RUN)).toBe(true);
      const files = git('show', '--name-only', '--pretty=format:', 'HEAD');
      expect(files).toContain('CHANGELOG.md');
      expect(files).not.toContain('fremde-arbeit.txt');
      // Still staged for its owner, not consumed by us.
      expect(git('diff', '--cached', '--name-only')).toContain('fremde-arbeit.txt');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('schreibt die Zeile auch, wenn der Baum uncommitted Änderungen hat', () => {
    const { dir, git } = repo();
    try {
      writeFileSync(join(dir, 'halbfertig.txt'), 'nicht committet\n');
      expect(appendChangelog(dir, SUGGESTION, RUN)).toBe(true);
      expect(readFileSync(join(dir, 'CHANGELOG.md'), 'utf8')).toContain('#7');
      expect(git('status', '--porcelain')).toContain('halbfertig.txt');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('legt einen neuen Tagesabschnitt an, ohne die älteren Zeilen zu verlieren', () => {
    // A regression that lost history would be silent: the file would still look
    // like a changelog, just a wrong one.
    const { dir } = repo();
    try {
      appendChangelog(dir, SUGGESTION, RUN);
      const body = readFileSync(join(dir, 'CHANGELOG.md'), 'utf8');
      expect(body).toContain('#1');
      expect(body).toContain('#7');
      expect(body).toContain(entryLine(SUGGESTION, RUN));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('hängt an einem bestehenden Tagesabschnitt an, statt einen zweiten zu bauen', () => {
    const { dir } = repo();
    try {
      appendChangelog(dir, { id: 7, text: 'a' } as never, { ...(RUN as object), resultSummary: 'a' } as never);
      appendChangelog(dir, { id: 8, text: 'b' } as never, { ...(RUN as object), resultSummary: 'b' } as never);
      const body = readFileSync(join(dir, 'CHANGELOG.md'), 'utf8');
      // Two new entries, and the older section is still the only other heading.
      expect(body).toContain('#7');
      expect(body).toContain('#8');
      expect(body.match(/^## \d{4}-\d{2}-\d{2}$/gm)?.length).toBeGreaterThanOrEqual(2);
      // Same-day entries share one heading.
      const today = new Date();
      const stamp = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
      expect(body.match(new RegExp(`^## ${stamp}$`, 'gm'))?.length).toBe(1);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
