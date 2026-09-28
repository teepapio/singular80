/**
 * Types for `scripts/worktree.mjs`.
 *
 * The script is plain JavaScript because it is a maintenance tool — but
 * `server/isolation.ts` imports it (the runner prepares a worktree per run with
 * exactly this code, so there is one implementation and not two) and
 * `tests/worktreeIsolation.test.ts` imports it as well. Both need a shape.
 * Hand-written, for the reason `locale.d.mts` gives.
 */

/** One entry of `git worktree list --porcelain`. */
export interface WorktreeEntry {
  path: string;
  head: string | null;
  /** Without the `refs/heads/` prefix. */
  branch: string | null;
  detached: boolean;
}

/** An agent branch and everything a person needs to decide what to do with it. */
export interface AgentWorktree {
  branch: string;
  label: string;
  path: string;
  /** False when the branch exists but has no checkout (a crashed lane). */
  registered: boolean;
  exists: boolean;
  head: string | null;
  /** Uncommitted paths, empty when clean. */
  dirty: string[];
  clean: boolean;
  /** Commits the branch has that `main` does not. */
  commits: number;
  /** A lane that never committed — nothing to merge, and nothing to lose. */
  empty: boolean;
  /** True when the branch is already reachable from `main` and adds nothing. */
  merged: boolean;
}

export interface ImportResult {
  ok: boolean;
  reason?: string;
  attempt?: number;
  skipped?: boolean;
}

export interface CreateResult {
  ok: boolean;
  branch: string;
  path: string;
  reason?: string;
  reused?: boolean;
  import?: ImportResult;
}

export interface RemoveResult {
  ok: boolean;
  branch: string;
  reason?: string;
  branchDeleted?: boolean;
}

/** Every checkout an agent works on, and the branches without one. */
export const AGENT_PREFIX: string;

/** Generated trees a merge must regenerate instead of reconciling. */
export const DERIVED_MIRRORS: string[];

export function sanitizeLabel(label: string): string;
export function agentBranch(label: string): string;
export function labelOf(branch: string): string;
export function worktreeRoot(): string;
export function worktreePath(label: string, base?: string): string;
export function godotDir(worktree: string): string;
export function parseWorktreeList(text: string): WorktreeEntry[];
export function parseBranchList(text: string): string[];
export function isMergedInto(repoRoot: string, branch: string, base?: string): boolean;
export function ownCommits(repoRoot: string, branch: string, base?: string): number;
export function dirtyFiles(cwd: string): string[];
export function listAgentWorktrees(repoRoot?: string): AgentWorktree[];
export function importGodot(
  worktree: string,
  options?: { log?: (line: string) => void; attempts?: number },
): ImportResult;
export function createWorktree(
  label: string,
  options?: { repoRoot?: string; base?: string; doImport?: boolean; log?: (line: string) => void },
): CreateResult;
export function removeWorktree(
  label: string,
  options?: { repoRoot?: string; force?: boolean; deleteBranch?: boolean | 'force' },
): RemoveResult;
export function pruneWorktrees(options?: { repoRoot?: string }): { removed: string[]; kept: string[] };
export function worktreeDiskMb(repoRoot?: string): number;
export function readRepoFile(rel: string): string;
