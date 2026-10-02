/**
 * Types for `scripts/merge-gate.mjs`.
 *
 * Hand-written for the reason `locale.d.mts` gives: the gate is a maintenance
 * script, and the only importer that needs a shape is
 * `tests/worktreeIsolation.test.ts`. What is worth writing down here is the
 * *shape of the report* — a gate either advances `main` or explains why not, and
 * `refused` is that explanation, one line per reason.
 */

/** One thing the gate did, or one thing it refused. */
export interface GateStep {
  kind: 'merge' | 'sync-commit' | 'verify' | string;
  /** Branch name, for a merge. */
  branch?: string;
  name?: string;
  ok: boolean;
  /** Files in conflict, for a merge that could not be resolved. */
  conflicts?: string[];
  /** Committed paths, for the sync commit. */
  files?: string[];
  /** The last lines of a failed command — enough to see, not a transcript. */
  output?: string;
  /** A step that did not apply, e.g. a repository without the sync tools. */
  skipped?: boolean;
}

export interface GateReport {
  /** Branch the shared tree was on when the gate started. */
  head: string;
  /** Commit of `main` the gate built on. */
  base: string;
  branches: string[];
  /** Every reason the gate did not advance `main`. Empty means it did. */
  refused: string[];
  steps: GateStep[];
  /** The verified commit, read *after* the sync commit. */
  mergeSha: string | null;
  fastForwarded: boolean;
  pushed: boolean;
  gateDir?: string;
}

export interface AgentWorktreeLike {
  branch: string;
  merged: boolean;
}

/**
 * The branches to merge: named ones, or every open one. A branch that does not
 * exist and one that is already in `main` are reported, not merged.
 */
export function resolveBranches(
  names: string[],
  entries: AgentWorktreeLike[],
): { merge: string[]; skipped: { branch: string; why: string }[] };

/** What must stop the gate before it merges anything. */
export function gateRefusals(input: {
  head: string;
  base: string;
  behindOrigin: boolean;
  origin: boolean;
}): string[];

/** The files the sync tools own: their output is committed, never merged. */
export function syncPaths(): string[];

/**
 * The steps the gate runs: whatever `scripts/test-affected.mjs` derives from the
 * files the merge touched, or the whole catalogue with `full`.
 */
export function verificationSteps(options: { hasNodeModules: boolean; files?: string[]; full?: boolean }): {
  name: string;
  bin: string;
  args: string[];
  /** Why this step is in the plan — the merge's file list, in one line. */
  reasons: string[];
  timeout?: number;
  /** Suite and screen counts, for a scoped Godot run. */
  suites?: number;
  screens?: number;
}[];

export function runGate(options?: {
  branches: string[];
  verify?: boolean;
  push?: boolean;
  advance?: boolean;
  keep?: boolean;
  /** Run the complete catalogue instead of only what the merge touched. */
  full?: boolean;
  repoRoot?: string;
  log?: (line: string) => void;
}): GateReport;
