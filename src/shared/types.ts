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

export type RunStatus = 'queued' | 'running' | 'succeeded' | 'failed' | 'cancelled';

export interface ScoreBreakdown {
  votes: number;
  cluster: number;
  recency: number;
  category: number;
  quality: number;
  penalty: number;
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
}

export interface SuggestionView extends Suggestion {
  score: number;
  breakdown: ScoreBreakdown;
  clusterIds: number[];
  clusterSize: number;
  run: RunRecord | null;
}

export interface RunRecord {
  id: string;
  suggestionId: number;
  status: RunStatus;
  sessionId: string | null;
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
  autoApprove: boolean;
  autoApproveScore: number;
  /**
   * Hard timeout per run in minutes. 0 = no timeout (a hung agent then blocks
   * the queue forever, which is exactly what this setting exists to prevent).
   */
  runTimeoutMinutes: number;
  /** Retries per run: 0 = none, 1 = one retry, N = up to N retries. */
  retryLimit: number;
  /** Base backoff in seconds before the first retry; doubles with every attempt. */
  retryBackoffSeconds: number;
}

/** Queue policy as the runner currently applies it. */
export interface RunnerPolicy {
  timeoutMinutes: number;
  retryLimit: number;
  retryBackoffSeconds: number;
}

export interface QueueState {
  /** While true no new run starts; a running run still finishes. */
  paused: boolean;
  policy: RunnerPolicy;
  activeRun: RunRecord | null;
  /** Runs waiting to start, in the order they will start. */
  queue: RunRecord[];
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
  | { type: 'content:reloaded' };
