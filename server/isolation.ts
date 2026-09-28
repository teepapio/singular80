/**
 * One worktree per run, so two runs stop sharing a directory.
 *
 * The runner starts several `opencode run` sessions at once, and until now all
 * of them wrote into the same working tree. That has three consequences, none
 * of which a commit message can repair afterwards:
 *
 * 1. **Read-during-write.** A suite started by run A reads whatever run B has
 *    half-written. Measured on this repository: a parse error in a test file
 *    that another session had rewritten three minutes earlier, which ended a
 *    15-minute full run at minute ten with a failure that belonged to somebody
 *    else.
 * 2. **A commit race that loses work silently.** The agents are told to use a
 *    private index (`GIT_INDEX_FILE`, `read-tree HEAD`, `add`, `commit`). The
 *    private index prevents lock contention, but `read-tree HEAD` snapshots the
 *    tree at that moment: if two agents read-tree before either commits, the
 *    second commit has the first as its parent while still carrying the *old*
 *    blobs for the first agent's files — so the second commit reverts the
 *    first's work, and `git log` shows both commits as clean.
 * 3. **No branch to merge.** Scope lanes (`server/scopes.ts`) keep two agents
 *    off each other's `own` files, but `SHARED_FILES` — `game_registry.gd`,
 *    `CHANGELOG.md` — is shared by all sixteen game scopes on purpose. Those
 *    edits interleave in one file with no conflict detection at all.
 *
 * A worktree fixes all three, and costs 56 MB of checkout plus 11 s of import
 * per lane. What it does *not* fix is the coupling itself: two agents adding a
 * game still both insert into the registry, and that is still a merge. Which is
 * why this module ends in a branch and not in `main`, and why the merge is a
 * separate, explicit step (`scripts/merge-gate.mjs`).
 *
 * It is **off by default** (`S80_ISOLATE_RUNS=1` turns it on). Turning it on
 * changes where every run's commits land, and that is the owner's decision, not
 * a detail of a refactor.
 */
import { createWorktree, dirtyFiles, listAgentWorktrees, removeWorktree, worktreePath } from '../scripts/worktree.mjs';
import type { AgentWorktree } from '../scripts/worktree.mjs';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

export interface RunIsolation {
  path: string;
  branch: string;
}

/** The label a run's branch carries: `agent/suggestion-14`. */
export function runLabel(suggestionId: number): string {
  return `suggestion-${suggestionId}`;
}

/** True when this checkout is a git repository at all. */
export function isGitRepo(projectRoot: string): boolean {
  if (!existsSync(join(projectRoot, '.git'))) return false;
  const res = spawnSync('git', ['-C', projectRoot, 'rev-parse', '--git-dir'], { encoding: 'utf8', timeout: 10_000 });
  return res.status === 0;
}

/**
 * The checkout a run works in, or null when it cannot have one.
 *
 * Returning null instead of throwing is the whole point: a run must still start
 * when the worktree cannot be created. It lands in the shared tree, exactly as
 * before, and says so in the run's event log — a lane that is degraded but
 * running beats a lane that refuses to start because a directory is occupied.
 */
export function prepareRunWorktree(
  projectRoot: string,
  suggestionId: number,
  { enabled, doImport = true, log = () => {} }: { enabled: boolean; doImport?: boolean; log?: (line: string) => void },
): RunIsolation | null {
  if (!enabled) return null;
  if (!isGitRepo(projectRoot)) {
    log('Kein Git-Repository — der Lauf arbeitet im gemeinsamen Baum.');
    return null;
  }
  const existing = listAgentWorktrees(projectRoot).find((w) => w.branch === `agent/${runLabel(suggestionId)}`);
  if (existing?.registered) {
    // A retry, or a run adopted after a restart: the branch is where the first
    // attempt's commits are, and a second branch would split them in two.
    if (dirtyFiles(existing.path).length > 0) {
      log(`Worktree ${existing.branch} ist nicht sauber — der Lauf arbeitet im gemeinsamen Baum.`);
      return null;
    }
    log(`Worktree ${existing.branch} existiert bereits (${existing.commits} Commit(s)).`);
    return { path: existing.path, branch: existing.branch };
  }
  const res = createWorktree(runLabel(suggestionId), { repoRoot: projectRoot, doImport, log });
  if (!res.ok) {
    log(`Worktree nicht angelegt (${res.reason}) — der Lauf arbeitet im gemeinsamen Baum.`);
    return null;
  }
  return { path: res.path, branch: res.branch };
}

/**
 * Frees a run's checkout once its branch is in `main`.
 *
 * Only ever called by the merge gate or by a person: a worktree that holds an
 * unmerged commit is the only copy of that work, and this refuses rather than
 * guesses. A dirty checkout is refused outright.
 */
export function releaseRunWorktree(
  projectRoot: string,
  branch: string,
  { deleteBranch = false, log = () => {} }: { deleteBranch?: boolean; log?: (line: string) => void } = {},
): { ok: boolean; reason?: string } {
  const label = branch.replace(/^agent\//, '');
  const entry = listAgentWorktrees(projectRoot).find((w) => w.branch === branch);
  if (!entry) return { ok: false, reason: `kein Worktree für ${branch}` };
  if (!entry.merged) {
    return { ok: false, reason: `${branch} ist nicht in main — der Worktree bleibt stehen` };
  }
  const res = removeWorktree(label, { repoRoot: projectRoot, deleteBranch });
  if (res.ok) log(`${branch} aufgeräumt.`);
  return res.ok ? { ok: true } : { ok: false, reason: res.reason };
}

export { listAgentWorktrees, worktreePath };
export type { AgentWorktree };
