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
}

export interface RunView extends RunRecord {
  events: RunEvent[];
  summary: string;
  /** Whether the runner currently knows a live opencode process for this run. */
  alive: boolean;
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
  | { type: 'content:reloaded' };
