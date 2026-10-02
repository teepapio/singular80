/**
 * The worktree layer: one checkout per agent, and the gate that merges them.
 *
 * The unit tests cover the pure parts (name sanitising, porcelain parsing, the
 * gate's own decisions). The end-to-end tests run against a **throwaway git
 * repository** built in a temp directory with a local bare `origin` — the
 * owner's repository is never the subject, which is the only way the merge and
 * push paths can be proven at all without pushing to GitHub.
 *
 * The Godot import is switched off in every test (`doImport: false`): it costs
 * 11 s and 57 MB per checkout, and it is Godot's business, not git's. It is
 * covered by one test that asserts the *call* happens and that a second attempt
 * follows a failed first one — a core dump in a fresh worktree was measured on
 * this machine, and a lane that dies there looks exactly like an agent that
 * never started.
 */
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync, appendFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  AGENT_PREFIX,
  DERIVED_MIRRORS,
  agentBranch,
  createWorktree,
  dirtyFiles,
  importGodot,
  isMergedInto,
  labelOf,
  listAgentWorktrees,
  ownCommits,
  parseBranchList,
  parseWorktreeList,
  pruneWorktrees,
  removeWorktree,
  sanitizeLabel,
  worktreePath,
  worktreeRoot,
} from '../scripts/worktree.mjs';
import { gateRefusals, resolveBranches, runGate, syncPaths, verificationSteps } from '../scripts/merge-gate.mjs';
import { isGitRepo, prepareRunWorktree, releaseRunWorktree, runLabel } from '../server/isolation';
import { commitSince } from '../server/runner';

const temps: string[] = [];
let previousWorktreeDir: string | undefined;
let previousGodotBin: string | undefined;

function git(cwd: string, args: string[]): string {
  const res = spawnSync('git', ['-C', cwd, ...args], { encoding: 'utf8' });
  if (res.status !== 0) throw new Error(`git ${args.join(' ')}: ${res.stderr}`);
  return (res.stdout ?? '').trim();
}

/**
 * A repository with a real history, a real `main` and a real (local) `origin`.
 * The bare remote is what makes `push` in the gate a testable step instead of a
 * network call.
 */
function makeRepo(): string {
  const dir = mkdtempSync(join(tmpdir(), 's80-wt-repo-'));
  temps.push(dir);
  const origin = join(dir, 'origin.git');
  const repo = join(dir, 'repo');
  spawnSync('git', ['init', '-q', '--bare', '-b', 'main', origin]);
  spawnSync('git', ['clone', '-q', origin, repo]);
  git(repo, ['config', 'user.email', 'test@singular80']);
  git(repo, ['config', 'user.name', 'Test']);
  git(repo, ['config', 'commit.gpgsign', 'false']);
  writeFileSync(join(repo, 'NUR-MAIN.md'), 'basis\n');
  git(repo, ['add', 'NUR-MAIN.md']);
  git(repo, ['commit', '-qm', 'Basis']);
  git(repo, ['push', '-q', 'origin', 'main']);
  return repo;
}

/** One commit on the agent branch, written the way an agent would. */
function agentCommit(repo: string, label: string, file: string, text: string, message: string): string {
  const wt = worktreePath(label);
  writeFileSync(join(wt, file), `${text}\n`);
  git(wt, ['add', file]);
  git(wt, ['commit', '-qm', message]);
  return git(wt, ['rev-parse', 'HEAD']);
}

beforeEach(() => {
  previousWorktreeDir = process.env.S80_WORKTREE_DIR;
  previousGodotBin = process.env.GODOT_BIN;
});

afterEach(() => {
  if (previousWorktreeDir === undefined) delete process.env.S80_WORKTREE_DIR;
  else process.env.S80_WORKTREE_DIR = previousWorktreeDir;
  if (previousGodotBin === undefined) delete process.env.GODOT_BIN;
  else process.env.GODOT_BIN = previousGodotBin;
  for (const dir of temps.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe('Namen', () => {
  it('macht aus einer Beschriftung einen Branch', () => {
    expect(agentBranch('suggestion-14')).toBe('agent/suggestion-14');
    expect(labelOf('agent/suggestion-14')).toBe('suggestion-14');
    expect(AGENT_PREFIX).toBe('agent/');
  });

  it('nimmt ein schon gesetztes Präfix nicht doppelt', () => {
    expect(agentBranch('agent/suggestion-14')).toBe('agent/suggestion-14');
  });

  it('entfernt alles, was in einem Pfad oder Branchnamen gefährlich wäre', () => {
    // A `:` or a space in a label produces a worktree that `git worktree remove`
    // cannot address again, and a `..` escapes the worktree root.
    expect(sanitizeLabel('vorschlag 14: neu')).toBe('vorschlag-14-neu');
    expect(sanitizeLabel('../../etc')).toBe('etc');
    expect(() => sanitizeLabel('   ')).toThrow();
    expect(() => sanitizeLabel('a/../b')).toThrow();
  });

  it('legt Worktrees unterhalb einer Basis ab, nicht daneben', () => {
    const base = join(tmpdir(), 'wt-base');
    expect(worktreePath('wt/1', base)).toBe(join(base, 'wt/1'));
    expect(worktreePath('a', base)).toBe(join(base, 'a'));
  });
});

describe('porcelain', () => {
  const SAMPLE = [
    'worktree /home/edi/singular80',
    'HEAD c3e6170c3e5e',
    'branch refs/heads/main',
    '',
    'worktree /home/edi/.local/share/singular80/worktrees/suggestion-14',
    'HEAD a1b2c3d4e5f6',
    'branch refs/heads/agent/suggestion-14',
    '',
    'worktree /tmp/head-wt',
    'HEAD 13fb5f1a2b3c',
    'detached',
    '',
  ].join('\n');

  it('liest Worktrees, Zweige und den detached Zustand', () => {
    const list = parseWorktreeList(SAMPLE);
    expect(list).toHaveLength(3);
    expect(list[0]).toMatchObject({ path: '/home/edi/singular80', branch: 'main', detached: false });
    expect(list[1].branch).toBe('agent/suggestion-14');
    expect(list[2].detached).toBe(true);
    expect(list[2].branch).toBeNull();
  });

  it('verträgt eine Liste ohne abschließenden Leerblock', () => {
    expect(parseWorktreeList('worktree /a\nHEAD 1\nbranch refs/heads/main')).toHaveLength(1);
  });

  it('nimmt nur Agent-Zweige und ignoriert den Markierungsstern', () => {
    const text = ['  agent/suggestion-14', '  main', '* agent/suggestion-15', '  wip/x', ''].join('\n');
    expect(parseBranchList(text)).toEqual(['agent/suggestion-14', 'agent/suggestion-15']);
  });
});

describe('Zustand eines Agent-Zweigs', () => {
  it('nennt einen frischen Zweig leer und nicht gemergt', () => {
    const repo = makeRepo();
    process.env.S80_WORKTREE_DIR = mkdtempSync(join(tmpdir(), 's80-wt-dir-'));
    expect(createWorktree('leer', { repoRoot: repo, doImport: false }).ok).toBe(true);
    const [entry] = listAgentWorktrees(repo);
    expect(entry.branch).toBe('agent/leer');
    expect(entry.empty).toBe(true);
    expect(entry.merged).toBe(true); // reachable from main, but with nothing of its own
    expect(ownCommits(repo, 'agent/leer')).toBe(0);
    expect(isMergedInto(repo, 'agent/leer')).toBe(true);
  });

  it('zählt die Commits, die main noch nicht hat', () => {
    const repo = makeRepo();
    process.env.S80_WORKTREE_DIR = mkdtempSync(join(tmpdir(), 's80-wt-dir-'));
    createWorktree('arbeit', { repoRoot: repo, doImport: false });
    agentCommit(repo, 'arbeit', 'A.md', 'a', 'feat: A');
    agentCommit(repo, 'arbeit', 'B.md', 'b', 'feat: B');
    const [entry] = listAgentWorktrees(repo);
    expect(entry.commits).toBe(2);
    expect(entry.empty).toBe(false);
    expect(entry.merged).toBe(false);
    expect(entry.clean).toBe(true);
  });

  it('meldet uncommittete Arbeit mit dem richtigen Dateinamen', () => {
    // The porcelain line is ` M NAME`; slicing three characters off a *trimmed*
    // first line ate the 'M' and produced `AME.md`.
    const repo = makeRepo();
    process.env.S80_WORKTREE_DIR = mkdtempSync(join(tmpdir(), 's80-wt-dir-'));
    createWorktree('schmutzig', { repoRoot: repo, doImport: false });
    appendFileSync(join(worktreePath('schmutzig'), 'NUR-MAIN.md'), 'x\n');
    expect(dirtyFiles(worktreePath('schmutzig'))).toEqual(['NUR-MAIN.md']);
    expect(listAgentWorktrees(repo)[0].clean).toBe(false);
  });
});

describe('Worktree-Lebenszyklus', () => {
  it('legt an, nutzt wieder und entfernt — und weigert sich bei Schmutz', () => {
    const repo = makeRepo();
    process.env.S80_WORKTREE_DIR = mkdtempSync(join(tmpdir(), 's80-wt-dir-'));
    const created = createWorktree('vorschlag-7', { repoRoot: repo, doImport: false });
    expect(created.ok).toBe(true);
    expect(created.reused).toBe(false);
    writeFileSync(join(created.path, 'NUR-MAIN.md'), 'weg\n');
    // In *this* checkout: `git -C repo checkout --` would repair the shared tree
    // and leave the worktree dirty, which is the case the next call refuses.
    git(created.path, ['checkout', '--', 'NUR-MAIN.md']);

    const again = createWorktree('vorschlag-7', { repoRoot: repo, doImport: false });
    expect(again.reused).toBe(true);

    writeFileSync(join(created.path, 'GEZAPPT.md'), 'x\n');
    const refused = removeWorktree('vorschlag-7', { repoRoot: repo });
    expect(refused.ok).toBe(false);
    expect(refused.reason).toContain('GEZAPPT.md');

    const forced = removeWorktree('vorschlag-7', { repoRoot: repo, force: true, deleteBranch: 'force' });
    expect(forced.ok).toBe(true);
    expect(forced.branchDeleted).toBe(true);
    expect(listAgentWorktrees(repo)).toHaveLength(0);
  });

  it('räumt nur auf, was gemergt und sauber ist', () => {
    const repo = makeRepo();
    process.env.S80_WORKTREE_DIR = mkdtempSync(join(tmpdir(), 's80-wt-dir-'));
    // A merged one, an unmerged one and a merged-but-dirty one.
    createWorktree('drin', { repoRoot: repo, doImport: false });
    agentCommit(repo, 'drin', 'A.md', 'a', 'feat: A');
    git(repo, ['merge', '--ff-only', 'agent/drin']);
    createWorktree('offen', { repoRoot: repo, doImport: false });
    agentCommit(repo, 'offen', 'B.md', 'b', 'feat: B');
    createWorktree('schmutzig', { repoRoot: repo, doImport: false });
    agentCommit(repo, 'schmutzig', 'C.md', 'c', 'feat: C');
    git(repo, ['merge', '--ff-only', 'agent/schmutzig']);
    writeFileSync(join(worktreePath('schmutzig'), 'D.md'), 'd\n');

    const { removed, kept } = pruneWorktrees({ repoRoot: repo });
    expect(removed).toEqual(['agent/drin']);
    expect(kept.sort()).toEqual(['agent/offen', expect.stringContaining('agent/schmutzig')]);
  });

  it('lässt einen Zweig ohne Checkout stehen, statt ihn zu löschen', () => {
    // A crashed lane leaves the branch behind. Its commits are the only copy.
    const repo = makeRepo();
    process.env.S80_WORKTREE_DIR = mkdtempSync(join(tmpdir(), 's80-wt-dir-'));
    createWorktree('abgestuerzt', { repoRoot: repo, doImport: false });
    agentCommit(repo, 'abgestuerzt', 'A.md', 'a', 'feat: A');
    git(repo, ['worktree', 'remove', '--force', worktreePath('abgestuerzt')]);
    const [entry] = listAgentWorktrees(repo);
    expect(entry.registered).toBe(false);
    expect(entry.commits).toBe(1);
    expect(createWorktree('abgestuerzt', { repoRoot: repo, doImport: false }).ok).toBe(false);
  });
});

describe('Import', () => {
  it('versucht es zweimal, wenn der erste Import stirbt', () => {
    // Measured: the first `--import` in a brand-new worktree aborted with a core
    // dump and succeeded unchanged on the second run.
    const dir = mkdtempSync(join(tmpdir(), 's80-import-'));
    temps.push(dir);
    const log = join(dir, 'fake-godot');
    const counter = join(dir, 'tries');
    writeFileSync(
      log,
      `#!/bin/sh\necho x >> ${counter}\nif [ "$(wc -l < ${counter})" = "1" ]; then echo "dumped core" >&2; exit 134; fi\nexit 0\n`,
    );
    spawnSync('chmod', ['+x', log]);
    process.env.GODOT_BIN = log;
    mkdirSync(join(dir, 'godot'), { recursive: true });
    const res = importGodot(dir, { log: () => {} });
    expect(res.ok).toBe(true);
    expect(res.attempt).toBe(2);
  });

  it('gibt nach zwei Versuchen auf, statt endlos zu laufen', () => {
    const dir = mkdtempSync(join(tmpdir(), 's80-import-'));
    temps.push(dir);
    const log = join(dir, 'fake-godot');
    writeFileSync(log, '#!/bin/sh\necho "kaputt" >&2\nexit 1\n');
    spawnSync('chmod', ['+x', log]);
    process.env.GODOT_BIN = log;
    mkdirSync(join(dir, 'godot'), { recursive: true });
    const res = importGodot(dir, { log: () => {} });
    expect(res.ok).toBe(false);
    expect(res.reason).toContain('kaputt');
  });

  it('meldet ein Verzeichnis ohne Godot-Projekt, statt Godot zu starten', () => {
    const dir = mkdtempSync(join(tmpdir(), 's80-import-'));
    temps.push(dir);
    const res = importGodot(dir, { log: () => {} });
    expect(res.ok).toBe(false);
    expect(res.reason).toContain('Godot-Projekt');
  });
});

describe('Gate: Entscheidungen', () => {
  it('merkt nur, was es nicht schon gibt, und überspringt, was drin ist', () => {
    const entries = [
      { branch: 'agent/a', merged: false },
      { branch: 'agent/b', merged: true },
    ] as Parameters<typeof resolveBranches>[1];
    const { merge, skipped } = resolveBranches(['a', 'agent/b', 'gibtsnicht'], entries);
    expect(merge).toEqual(['agent/a']);
    expect(skipped).toEqual([
      { branch: 'agent/b', why: 'schon in main' },
      { branch: 'agent/gibtsnicht', why: 'gibt es nicht' },
    ]);
  });

  it('verweigert das Gate, wenn der Baum nicht auf main steht', () => {
    expect(gateRefusals({ head: 'wip/halb', base: 'abc', behindOrigin: false, origin: true })[0]).toContain('main');
    expect(gateRefusals({ head: 'main', base: '', behindOrigin: false, origin: true })[0]).toContain('main');
  });

  it('verweigert das Gate, wenn origin/main weiter ist als das lokale main', () => {
    const out = gateRefusals({ head: 'main', base: 'abc', behindOrigin: true, origin: true });
    expect(out.join(' ')).toContain('git pull');
  });

  it('erlaubt einem schmutzigen gemeinsamen Baum das Gate — das prüft der Fast-forward', () => {
    // Foreign work in the shared tree is the normal case, not a reason to stop.
    // What must never happen is a fast-forward that overwrites it, and that is
    // git's own check at the last step.
    expect(gateRefusals({ head: 'main', base: 'abc', behindOrigin: false, origin: true })).toEqual([]);
  });

  it('erzeugt abgeleitete Dateien neu, statt sie zusammenzuführen', () => {
    expect(syncPaths()).toEqual([...DERIVED_MIRRORS, 'locale']);
    expect(DERIVED_MIRRORS).toEqual(['godot/assets/content', 'godot/assets/locale']);
  });

  /**
   * The gate judges what the merge brought in, not the whole tree.
   *
   * `verificationSteps` is `test-affected.mjs` with the merge's file list, so
   * these three cases are the contract between the two: a game branch is checked
   * by that game's suites, a branch that touched shared ground by the whole
   * catalogue, and `--full` by the catalogue regardless.
   */
  it('prüft nur, was der Merge berührt', () => {
    const game = verificationSteps({ hasNodeModules: true, files: ['godot/src/game/tetris/tetris_screen.gd'] });
    expect(game.map((s) => s.name)).toEqual(['content:check', 'locale:check', 'Spieltests (tetris)']);
    expect(game.at(-1)?.args).toEqual(['scripts/test-game.mjs', '--scope', 'tetris']);

    const shared = verificationSteps({ hasNodeModules: true, files: ['godot/src/core/logic/game_registry.gd'] });
    expect(shared.at(-1)?.args).toEqual(['scripts/test-game.mjs']);

    const server = verificationSteps({ hasNodeModules: true, files: ['server/runner.ts'] });
    expect(server.map((s) => s.name)).toEqual(['content:check', 'locale:check', 'typecheck', 'npm test']);
  });

  it('prüft den ganzen Katalog, wenn er das verlangt', () => {
    expect(verificationSteps({ hasNodeModules: true, files: ['README.md'], full: true }).map((s) => s.name))
      .toEqual(['content:check', 'locale:check', 'typecheck', 'npm test', 'Spieltests']);
  });

  it('nennt bei jedem Schritt, warum er im Plan ist', () => {
    for (const step of verificationSteps({ hasNodeModules: true, files: ['server/runner.ts'] })) {
      expect(step.reasons?.length, `${step.name} ohne Grund`).toBeGreaterThan(0);
    }
  });

  it('springt die JavaScript-Schritte ohne node_modules, statt sie zu melden', () => {
    // Skipping them silently would report a green gate that checked nothing.
    const steps = verificationSteps({ hasNodeModules: false, files: ['server/runner.ts'] }).map((s) => s.name);
    expect(steps).toEqual(['content:check', 'locale:check']);
  });
});

describe('Lauf-Isolation', () => {
  it('ist aus, solange sie nicht eingeschaltet ist', () => {
    const repo = makeRepo();
    expect(prepareRunWorktree(repo, 1, { enabled: false })).toBeNull();
  });

  it('arbeitet im gemeinsamen Baum weiter, wenn kein Repository da ist', () => {
    // A run must always start. A refused lane is a suggestion that stays in the
    // queue; a degraded lane is work in progress.
    const plain = mkdtempSync(join(tmpdir(), 's80-plain-'));
    temps.push(plain);
    const notes: string[] = [];
    expect(isGitRepo(plain)).toBe(false);
    expect(prepareRunWorktree(plain, 1, { enabled: true, log: (l) => notes.push(l) })).toBeNull();
    expect(notes.join(' ')).toContain('gemeinsamen Baum');
  });

  it('gibt einem Lauf seinen Zweig und behält ihn für einen zweiten Versuch', () => {
    const repo = makeRepo();
    process.env.S80_WORKTREE_DIR = mkdtempSync(join(tmpdir(), 's80-wt-dir-'));
    expect(runLabel(42)).toBe('suggestion-42');
    const first = prepareRunWorktree(repo, 42, { enabled: true, doImport: false });
    expect(first).toEqual({ path: worktreePath('suggestion-42'), branch: 'agent/suggestion-42' });
    agentCommit(repo, 'suggestion-42', 'A.md', 'a', 'feat(suggestion-42): A');

    // The retry must go to the same branch: the first attempt's commit is there.
    const second = prepareRunWorktree(repo, 42, { enabled: true, doImport: false });
    expect(second).toEqual(first);
    expect(ownCommits(repo, 'agent/suggestion-42')).toBe(1);
  });

  it('verweigert einen schmutzigen Worktree, statt ihn zu übernehmen', () => {
    const repo = makeRepo();
    process.env.S80_WORKTREE_DIR = mkdtempSync(join(tmpdir(), 's80-wt-dir-'));
    const first = prepareRunWorktree(repo, 5, { enabled: true, doImport: false });
    writeFileSync(join(first!.path, 'A.md'), 'halbfertig\n');
    const notes: string[] = [];
    expect(prepareRunWorktree(repo, 5, { enabled: true, doImport: false, log: (l) => notes.push(l) })).toBeNull();
    expect(notes.join(' ')).toContain('nicht sauber');
  });

  it('räumt nur auf, was in main ist', () => {
    const repo = makeRepo();
    process.env.S80_WORKTREE_DIR = mkdtempSync(join(tmpdir(), 's80-wt-dir-'));
    prepareRunWorktree(repo, 6, { enabled: true, doImport: false });
    agentCommit(repo, 'suggestion-6', 'A.md', 'a', 'feat(suggestion-6): A');
    expect(releaseRunWorktree(repo, 'agent/suggestion-6').ok).toBe(false);
    git(repo, ['merge', '--ff-only', 'agent/suggestion-6']);
    expect(releaseRunWorktree(repo, 'agent/suggestion-6').ok).toBe(true);
  });
});

describe('Commit-Erkennung auf einem Agent-Zweig', () => {
  it('sieht den Commit des Laufs auch ohne ihn auf main', () => {
    // The whole reason `commitSince` takes a ref: an isolated run's commit is not
    // on `main` until the gate has run, and without the ref a finished run reads
    // as "no commit" — which sends the suggestion back into the queue.
    const repo = makeRepo();
    process.env.S80_WORKTREE_DIR = mkdtempSync(join(tmpdir(), 's80-wt-dir-'));
    prepareRunWorktree(repo, 9, { enabled: true, doImport: false });
    agentCommit(repo, 'suggestion-9', 'A.md', 'a', 'feat(suggestion-9): etwas');

    const started = Date.now() - 60_000;
    expect(commitSince(started, repo, 9, 'agent/suggestion-9')).toMatch(/^[0-9a-f]+$/);
    // Without the ref: nothing, because the commit is not on main.
    expect(commitSince(started, repo, 9)).toBeNull();
    // A branch that does not exist is "no commit", not an exception.
    expect(commitSince(started, repo, 9, 'agent/gibtsnicht')).toBeNull();
  });
});

describe('Gate: Ende zu Ende', () => {
  /** Both steps a run needs, so the gate has something real to merge. */
  function agentWithCommit(repo: string, label: string, file: string, text: string, message: string): void {
    const wt = worktreePath(label);
    mkdirSync(join(wt, 'scripts'), { recursive: true });
    // Without the sync tools the gate has nothing derived to regenerate, and
    // says so instead of failing.
    writeFileSync(join(wt, 'scripts/sync-content.mjs'), 'process.exit(0);\n');
    git(wt, ['add', '-A']);
    git(wt, ['commit', '-qm', 'chore: sync-Werkzeug']);
    agentCommit(repo, label, file, text, message);
  }

  it('merged, prüft, fast-forwarded und pusht', () => {
    const repo = makeRepo();
    process.env.S80_WORKTREE_DIR = mkdtempSync(join(tmpdir(), 's80-wt-dir-'));
    createWorktree('a', { repoRoot: repo, doImport: false });
    agentWithCommit(repo, 'a', 'A.md', 'a', 'feat(suggestion-1): A');
    createWorktree('b', { repoRoot: repo, doImport: false });
    agentWithCommit(repo, 'b', 'B.md', 'b', 'feat(suggestion-2): B');

    const report = runGate({ branches: ['agent/a', 'agent/b'], verify: false, repoRoot: repo, log: () => {} });
    expect(report.refused).toEqual([]);
    expect(report.fastForwarded).toBe(true);
    expect(report.pushed).toBe(true);
    // One merge commit per branch, and the gate's own sha is what main is at.
    expect(git(repo, ['rev-parse', 'HEAD'])).toBe(report.mergeSha);
    expect(git(repo, ['log', '--merges', '--oneline']).split('\n')).toHaveLength(2);
    // And the remote has it, which is the point of the whole exercise.
    expect(git(join(repo, '..', 'origin.git'), ['rev-parse', 'main'])).toBe(report.mergeSha);
    expect(git(repo, ['ls-tree', '--name-only', 'HEAD']).split('\n')).toEqual(
      expect.arrayContaining(['A.md', 'B.md']),
    );
  });

  it('lässt main unberührt, wenn zwei Zweige dieselbe Datei anders ändern', () => {
    const repo = makeRepo();
    process.env.S80_WORKTREE_DIR = mkdtempSync(join(tmpdir(), 's80-wt-dir-'));
    const before = git(repo, ['rev-parse', 'HEAD']);
    createWorktree('x', { repoRoot: repo, doImport: false });
    agentCommit(repo, 'x', 'GEMEINSAM.md', 'von x', 'feat(suggestion-1): x');
    createWorktree('y', { repoRoot: repo, doImport: false });
    agentCommit(repo, 'y', 'GEMEINSAM.md', 'von y', 'feat(suggestion-2): y');

    const report = runGate({ branches: ['agent/x', 'agent/y'], verify: false, repoRoot: repo, log: () => {} });
    expect(report.refused.join(' ')).toContain('GEMEINSAM.md');
    expect(report.fastForwarded).toBe(false);
    expect(report.pushed).toBe(false);
    expect(git(repo, ['rev-parse', 'HEAD'])).toBe(before);
    // And the gate cleans up after itself even when it stops.
    expect(git(repo, ['worktree', 'list'])).not.toContain('s80-gate-');
  });

  it('prüft, ohne main zu bewegen, wenn --no-advance', () => {
    const repo = makeRepo();
    process.env.S80_WORKTREE_DIR = mkdtempSync(join(tmpdir(), 's80-wt-dir-'));
    const before = git(repo, ['rev-parse', 'HEAD']);
    createWorktree('z', { repoRoot: repo, doImport: false });
    agentCommit(repo, 'z', 'Z.md', 'z', 'feat(suggestion-3): Z');

    const report = runGate({
      branches: ['agent/z'],
      verify: false,
      advance: false,
      repoRoot: repo,
      log: () => {},
    });
    expect(report.refused).toEqual([]);
    expect(report.fastForwarded).toBe(false);
    expect(git(repo, ['rev-parse', 'HEAD'])).toBe(before);
    expect(report.mergeSha).not.toBe(before);
  });

  it('verweigert alles, wenn der gemeinsame Baum nicht auf main steht', () => {
    const repo = makeRepo();
    process.env.S80_WORKTREE_DIR = mkdtempSync(join(tmpdir(), 's80-wt-dir-'));
    git(repo, ['checkout', '-q', '-b', 'wip/halb']);
    const report = runGate({ branches: ['agent/egal'], verify: false, repoRoot: repo, log: () => {} });
    expect(report.refused.join(' ')).toContain('main');
    expect(report.mergeSha).toBeNull();
  });

  /**
   * The whole point of the derived plan, end to end: the gate spawns the checks
   * the merge actually reaches, and a red one stops it before the
   * fast-forward. `scripts/sync-content.mjs` and `scripts/locale.mjs` are the
   * two steps that run in *every* plan, so two stubs in the throwaway repository
   * stand in for the suites — the red one is the interesting half, and it is
   * what proves the gate does not report green after a failed check.
   */
  it('fährt den Plan des Merges und stoppt bei einem roten Schritt', () => {
    const repo = makeRepo();
    process.env.S80_WORKTREE_DIR = mkdtempSync(join(tmpdir(), 's80-wt-dir-'));
    mkdirSync(join(repo, 'scripts'), { recursive: true });
    // Two stubs: the catalogue checks are in every plan, so this plan is exactly
    // them and nothing else — the merged file (`Z.md`) reaches no scope.
    writeFileSync(join(repo, 'scripts', 'sync-content.mjs'), 'process.exit(0);\n');
    writeFileSync(join(repo, 'scripts', 'locale.mjs'), 'process.exit(Number(process.env.S80_LOCALE_ROT ?? 0));\n');
    git(repo, ['add', 'scripts']);
    git(repo, ['commit', '-qm', 'Prüfwerkzeuge als Stubs']);

    createWorktree('plan', { repoRoot: repo, doImport: false });
    agentCommit(repo, 'plan', 'Z.md', 'z', 'feat(suggestion-4): Z');

    const ok = runGate({ branches: ['agent/plan'], verify: true, repoRoot: repo, log: () => {} });
    const verified = ok.steps.filter((s) => s.kind === 'verify').map((s) => s.name);
    expect(verified).toEqual(['content:check', 'locale:check']);
    expect(ok.refused).toEqual([]);
    expect(ok.fastForwarded).toBe(true);

    // The same merge with a red catalogue check: `main` must stay where it was.
    process.env.S80_LOCALE_ROT = '1';
    const before = git(repo, ['rev-parse', 'HEAD']);
    createWorktree('rot', { repoRoot: repo, doImport: false });
    agentCommit(repo, 'rot', 'R.md', 'r', 'feat(suggestion-5): R');
    const red = runGate({ branches: ['agent/rot'], verify: true, repoRoot: repo, log: () => {} });
    expect(red.steps.find((s) => s.kind === 'verify' && !s.ok)?.name).toBe('locale:check');
    expect(red.refused.join(' ')).toContain('locale:check');
    expect(red.fastForwarded).toBe(false);
    expect(git(repo, ['rev-parse', 'HEAD'])).toBe(before);
    delete process.env.S80_LOCALE_ROT;
  });
});

describe('Worktree-Wurzel', () => {
  it('folgt S80_WORKTREE_DIR und sonst dem Verzeichnis des Nutzers', () => {
    process.env.S80_WORKTREE_DIR = '/tmp/s80-wohin';
    expect(worktreeRoot()).toBe('/tmp/s80-wohin');
    delete process.env.S80_WORKTREE_DIR;
    expect(worktreeRoot()).toContain(join('.local', 'share', 'singular80', 'worktrees'));
  });
});
