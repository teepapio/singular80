/**
 * Types for `scripts/test-affected.mjs`.
 *
 * Hand-written for the same reason as `merge-gate.d.mts`: the module is a
 * maintenance script, and the only importer that needs a shape is the test.
 * What is worth writing down is the plan — one entry per command, each with the
 * files that put it there, because "why was this run?" is the question the whole
 * tool exists to answer.
 */

/** One command in the plan. A `note` is not a command, it is the gap in one. */
export interface AffectedStep {
  /** Human name for the report, e.g. `Spieltests (tetris)`. */
  name?: string;
  /** Executable to spawn. Absent on a note. */
  bin?: string;
  args?: string[];
  /** Milliseconds before the step is killed. */
  timeout?: number;
  /** The files that put this step into the plan. Never empty for a real step. */
  reasons?: string[];
  /** Suite and screen counts of a scoped Godot run. */
  suites?: number;
  screens?: number;
  /** Said instead of run: a file that reaches no test at all. */
  note?: string;
}

/** The files a run judges: explicit names, or the difference against a base. */
export function changedFiles(options?: {
  files?: string[];
  staged?: boolean;
  base?: string | null;
  cwd?: string;
}): string[];

/**
 * Which commands prove this change. `full` is the complete catalogue, which is
 * what the APK build and `npm run gate -- --full` ask for.
 */
export function affectedSteps(
  files: string[],
  options?: { full?: boolean; hasNodeModules?: boolean; scopes?: Map<string, unknown> },
): AffectedStep[];

/** The complete catalogue: what a release proves, what no agent has to. */
export function fullSteps(hasNodeModules: boolean): AffectedStep[];

/** Runs the plan in order and stops at the first red step. */
export function runSteps(
  steps: AffectedStep[],
  options?: { cwd?: string; log?: (line: string) => void },
): { ok: boolean; step: AffectedStep | null };