export type SuggestionCategory =
  | 'mechanics'
  | 'content'
  | 'balance'
  | 'bug'
  | 'ui'
  | 'audio'
  | 'other';

export type SuggestionStatus =
  | 'new'
  | 'approved'
  | 'rejected'
  | 'implementing'
  | 'implemented'
  | 'failed';

/**
 * `source` of an order the operator typed into the dashboard's task composer.
 * Travels the same road as a player suggestion, so it borrows scope prediction,
 * retries and history — but no votes, no Discord post, and it starts `approved`.
 */
export const OPERATOR_SOURCE = 'operator';

export type RunStatus = 'queued' | 'running' | 'succeeded' | 'failed' | 'cancelled';

/** What a deployed-version check looks at: a laggy game, a noisy log, dead buttons. */
export type CheckKind = 'actions' | 'logs' | 'performance';

/** How a check is carried out. */
export type CheckProbe =
  /** Reads the source; no device, no APK. Deterministic and fast. */
  | 'static'
  /** Measures the installed app via adb; needs a connected device. */
  | 'device';

export type CheckStatus = 'queued' | 'running' | 'passed' | 'warned' | 'failed' | 'cancelled';

export type CheckSeverity = 'info' | 'warn' | 'fail';

export interface CheckFinding {
  kind: CheckKind;
  /** Stable machine code, e.g. `button-without-callback`. */
  code: string;
  severity: CheckSeverity;
  /** Repo-relative path. */
  file: string;
  line: number;
  /** Enclosing function, when the check could determine one. */
  function?: string;
  /** German, one sentence, says what is wrong. */
  message: string;
  /** What to do about it. */
  hint?: string;
}

/** One checkable thing on a target, e.g. "buttons of the Siedler screen". */
export interface CheckSpec {
  id: string;
  kind: CheckKind;
  probe: CheckProbe;
  /** German label for the dashboard. */
  title: string;
  /** What the check looks at, in one sentence. */
  description: string;
  /** Globs of the files a static check reads, e.g. `godot/src/game/siedler/**`. */
  scope?: string[];
  /** Registry ids / screen ids a device probe visits. */
  targets?: string[];
  /**
   * Thresholds for a device probe, so the verdict is a number and not an
   * impression: `minFps`, `maxFrameMs` (p95), `maxLogLinesPerSecond`, `maxMemoryMb`.
   */
  limits?: CheckLimits;
}

export interface CheckLimits {
  minFps?: number;
  maxFrameMs?: number;
  maxLogLinesPerSecond?: number;
  maxMemoryMb?: number;
}

export interface CheckRecord {
  id: string;
  specId: string;
  kind: CheckKind;
  probe: CheckProbe;
  status: CheckStatus;
  title: string;
  /** Repo-relative globs the static pass read. */
  scope: string[];
  /** Registry ids / screen ids the device pass visited. */
  targets: string[];
  limits: CheckLimits | null;
  createdAt: number;
  startedAt: number | null;
  finishedAt: number | null;
  /** Number of findings per severity. */
  counts: { fail: number; warn: number; info: number };
  findings: CheckFinding[];
  /** German one-paragraph result for the dashboard. */
  summary: string;
  /** Suggestion created from a failing check, if the operator promoted it. */
  promotedSuggestionId: number | null;
  logPath: string;
  note: string | null;
}

export interface CheckQueueState {
  paused: boolean;
  activeCheck: CheckRecord | null;
  queue: CheckRecord[];
}


export interface Suggestion {
  id: number;
  text: string;
  author: string;
  source: string;
  category: SuggestionCategory;
  status: SuggestionStatus;
  votes: number;
  canonicalId: number | null;
  createdAt: number;
  updatedAt: number;
  discordMessageId: string | null;
  runId: string | null;
  /** Id of the parent suggestion when this one was created by splitting another order. */
  parentId?: number | null;
  /**
   * Stable per-suggestion key the game sends with every attempt. A repeated key
   * is a retry after a lost response and creates nothing new; `null` for
   * suggestions without one (dashboard, older client builds).
   */
  clientKey?: string | null;
}

export interface SuggestionView extends Suggestion {
  clusterIds: number[];
  clusterSize: number;
  run: RunRecord | null;
}

export interface RunRecord {
  id: string;
  suggestionId: number;
  status: RunStatus;
  sessionId: string | null;
  /**
   * OpenCode session this run continues, when the owner pressed "Fortsetzen".
   * The previous run's session id, carried over so `opencode run --session` picks
   * the conversation up where it stopped instead of starting from nothing. Null
   * for every run that starts fresh.
   */
  resumesSession: string | null;
  /** 1-based lane the run occupies while it is executing, null while it waits in
   * the queue. Persisted, so a run adopted after a server restart keeps the
   * slot the operator already sees.
   */
  lane: number | null;
  /**
   * The checkout an isolated run works in, and the branch it commits to. Both
   * null for the default: a run in the shared tree, which is what every run
   * before worktrees existed reads back as.
   */
  worktreePath: string | null;
  worktreeBranch: string | null;
  prompt: string;
  exitCode: number | null;
  cost: number | null;
  tokensInput: number | null;
  tokensOutput: number | null;
  commitHash: string | null;
  /** Short human-readable result summary written by the runner (used on the dashboard). */
  resultSummary: string;
  createdAt: number;
  startedAt: number | null;
  finishedAt: number | null;
  logPath: string;
  /** 1-based attempt counter. A retry is a *new* run with `attempt = previous + 1`. */
  attempt: number;
  /** Retry policy snapshot taken when the run was queued, so a changed setting cannot rewrite history. */
  maxAttempts: number;
  /** Id of the run this attempt repeats; null for the first attempt. */
  retryOf: string | null;
  /** Wall-clock ms before which the run must not start (backoff after a failed attempt). */
  notBefore: number | null;
  /** Hard timeout budget in ms for this run; 0 disables it. */
  timeoutMs: number;
  /** Every scope id from `scripts/scopes.mjs` this run works on, most specific first. */
  scopes: string[];
  /** Primary scope id, i.e. `scopes[0]`. */
  scope: string | null;
  /** Machine-readable outcome reason (`timeout`, `exit 1`, `abgebrochen`, …), null while unfinished. */
  note: string | null;
  /**
   * Compact JSON of the scope audit at finalize time (files touched outside the
   * declared scope). Null when the run stayed inside its scope.
   */
  scopeIssues: string | null;
}

export interface RunView extends RunRecord {
  events: RunEvent[];
  /**
   * Timestamp of the most recent event, or null when the run has produced none.
   * The dashboard polls for activity liveness and only ever needed this one
   * number, so it is sent explicitly instead of making every client walk the
   * whole event array to find a maximum.
   */
  lastEventAt: number | null;
  summary: string;
  /** Whether the runner currently knows a live opencode process for this run. */
  alive: boolean;
  /** Which files the run touched relative to its declared scope. */
  scopeAudit: ScopeAudit | null;
}

export interface RunEvent {
  t: number;
  kind: 'status' | 'text' | 'tool' | 'info' | 'error' | 'done';
  text: string;
  tool?: string;
  detail?: string;
}

export interface Settings {
  discordWebhook: string;
  model: string;
  extraInstructions: string;
  /**
   * Hard timeout per run in minutes. 0 = no timeout, i.e. a hung agent blocks
   * the queue forever, which is exactly what this setting exists to prevent.
   */
  runTimeoutMinutes: number;
  /** Retries per run: 0 = none, 1 = one retry, N = up to N retries. */
  retryLimit: number;
  /** Base backoff in seconds before the first retry; doubles with every attempt. */
  retryBackoffSeconds: number;
  /**
   * How many opencode sessions may run at once, and the only limit on it: scopes
   * do not reserve a lane, so two runs in the same scope start side by side.
   */
  maxParallelRuns: number;
}

/** Queue policy as the runner currently applies it. */
export interface RunnerPolicy {
  timeoutMinutes: number;
  retryLimit: number;
  retryBackoffSeconds: number;
  /** Number of lanes, i.e. how many runs may execute at the same time. */
  maxParallelRuns: number;
}

export interface QueueState {
  /** While true no new run starts; a running run still finishes. */
  paused: boolean;
  policy: RunnerPolicy;
  /**
   * Every run currently executing, one entry per occupied lane. Oldest first, so
   * `activeRuns[0]` is the run that has had the most time to make progress.
   */
  activeRuns: RunRecord[];
  /** The oldest running run, for callers that only ever need one (health check). */
  activeRun: RunRecord | null;
  /** Runs waiting to start, in the order they will start. */
  queue: RunRecord[];
  /**
   * Queued runs that cannot start because every lane is busy. Purely
   * informational: explains an empty free lane instead of leaving a run "waiting"
   * with no visible reason. A run whose scope collides with a busy one is *not*
   * in here — scopes do not reserve a lane.
   */
  blockedRunIds: string[];
}

/** One entry of the scope manifest in `scripts/scopes.mjs`. */
export interface ScopeInfo {
  id: string;
  /** Agent that owns the scope (`game`, `meshes`, `dashboard`, …). */
  agent: string;
  label: string;
  own: string[];
  shared: string[];
  /** Godot test suites this scope owns (used by `npm run test:game -- --scope`). */
  suites: string[];
  screens: string[];
  /** Base scope for registry variants that share a screen/logic module. */
  aliasOf: string | null;
}

export interface ScopeManifest {
  /** `unavailable` means the runner could not read `scripts/scopes.mjs`. */
  status: 'ok' | 'unavailable';
  error: string | null;
  scopes: ScopeInfo[];
  /** Files every agent may touch; reported loudly, never blocking. */
  sharedFiles: string[];
  /** Self-check of the manifest (ambiguous globs, unclaimed suites, …). */
  problems: string[];
}

export type ScopeConfidence = 'explicit' | 'category' | 'fallback';

export interface ScopePrediction {
  suggestionId: number;
  /** All predicted scopes, most specific first. Empty when the manifest is missing. */
  scopes: string[];
  label: string | null;
  agent: string | null;
  /** How the mapping was derived, shown verbatim on the dashboard. */
  reason: string;
  confidence: ScopeConfidence;
}

export interface ScopeAudit {
  runId: string;
  /** Declared scope(s) of the run; empty when unknown. */
  scopes: string[];
  agent: string | null;
  ok: boolean;
  /** Files owned by a *different* scope than the run's. */
  violations: string[];
  /** Files of the run's own scope that are shared with other agents. */
  shared: string[];
  /** Files no scope claims. */
  unclaimed: string[];
  /** Additional remarks, e.g. a `git add -A` that could sweep up foreign work. */
  notes: string[];
  /** Number of distinct files inspected. */
  checked: number;
}

export interface EnemyDef {
  id: string;
  name: string;
  hp: number;
  speed: number;
  damage: number;
  radius: number;
  color: string;
  xp: number;
  minWave: number;
  weight: number;
  shape?: 'circle' | 'square' | 'triangle' | 'diamond' | 'hexagon';
  behavior?: 'chase' | 'zigzag' | 'orbit';
  boss?: boolean;
  /** Enemy id spawned from this enemy's corpse on death (e.g. split slimes). */
  splitInto?: string;
  /** Number of children spawned on death (default 2). */
  splitCount?: number;
}

export interface WeaponDef {
  id: string;
  name: string;
  description: string;
  damage: number;
  cooldown: number;
  projectileSpeed: number;
  projectileCount: number;
  spread: number;
  pierce: number;
  size: number;
  color: string;
  unlockWave: number;
}

export interface UpgradeDef {
  id: string;
  name: string;
  description: string;
  stat: string;
  amount: number;
  maxStacks: number;
  rarity: 'common' | 'uncommon' | 'rare' | 'epic';
  minLevel: number;
}

export interface ModeDef {
  id: string;
  name: string;
  description: string;
  enemyHpMult: number;
  enemySpeedMult: number;
  spawnRateMult: number;
  duration: number;
}

export interface MechanicDef {
  id: string;
  name: string;
  description: string;
  enabled: boolean;
}

export interface ContentPack {
  version: number;
  enemies: EnemyDef[];
  weapons: WeaponDef[];
  upgrades: UpgradeDef[];
  modes: ModeDef[];
  mechanics: MechanicDef[];
}

export type BusEvent =
  | { type: 'suggestion:new'; suggestion: SuggestionView }
  | { type: 'suggestion:updated'; suggestion: SuggestionView }
  | { type: 'suggestion:vote'; suggestion: SuggestionView }
  | { type: 'run:started'; run: RunRecord }
  | { type: 'run:log'; runId: string; event: RunEvent }
  | { type: 'run:finished'; run: RunRecord }
  | { type: 'queue:state'; state: QueueState }
  | { type: 'check:started'; check: CheckRecord }
  | { type: 'check:finished'; check: CheckRecord }
  | { type: 'check:queue'; state: CheckQueueState }
  | { type: 'content:reloaded' };
