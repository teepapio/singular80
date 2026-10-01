import type {
  QueueState,
  RunRecord,
  RunnerPolicy,
  ScopeAudit,
  ScopeInfo,
  ScopeManifest,
} from '../shared/types';
import { germanDuration } from './runActivity';

/**
 * Pure formatting for the run panel: pause state, policy line, retry and timeout
 * badges, scope warnings. Out of `main.ts` because these are the strings an
 * operator reads while deciding whether to intervene — they deserve a test more
 * than a template literal.
 */

export interface QueueSummary {
  paused: boolean;
  /** Short chip text for the panel header. */
  label: string;
  /** One line describing the policy that is actually in force. */
  policyLabel: string;
  /** Runs waiting to start. */
  waiting: number;
  /** How long until the next queued run may start, when a backoff is pending. */
  startsIn: string | null;
  /** How many lanes exist and how many are busy, e.g. "2 von 3 Spuren belegt". */
  lanes: string;
  /** Busy lanes, oldest first. */
  busyLanes: number;
  /** Lanes the operator configured, i.e. how many sessions may run at once. */
  totalLanes: number;
  /** Queued runs that wait for a busy lane instead of for their turn. */
  blocked: number;
}

/** German duration, reused for countdowns ("in 25 s", "in 2 min 5 s"). */
export function formatCountdown(ms: number): string {
  return germanDuration(ms, true);
}

export function describePolicy(policy: RunnerPolicy): string {
  const parts: string[] = [];
  parts.push(policy.timeoutMinutes > 0 ? `Zeitlimit ${formatCountdown(policy.timeoutMinutes * 60_000)}` : 'kein Zeitlimit');
  parts.push(policy.retryLimit > 0 ? `${policy.retryLimit}× Wiederholung` : 'keine Wiederholung');
  if (policy.retryLimit > 0) {
    parts.push(`${formatCountdown(policy.retryBackoffSeconds * 1000)} Wartezeit`);
  }
  parts.push(laneLabel(policy.maxParallelRuns, 0));
  return parts.join(' · ');
}

/** `3 Spuren parallel` / `keine Parallelität (1 Spur)`. */
export function laneLabel(totalLanes: number, busyLanes: number): string {
  const total = Math.max(1, totalLanes);
  if (total === 1) return busyLanes > 0 ? '1 Spur, belegt' : '1 Spur (nur nacheinander)';
  return `${busyLanes} von ${total} Spuren belegt`;
}

export function describeQueue(state: QueueState, now: number): QueueSummary {
  const pending = state.queue
    .filter((run) => run.notBefore != null && run.notBefore > now)
    .map((run) => run.notBefore as number);
  const soonest = pending.length ? Math.min(...pending) : null;
  const busyLanes = state.activeRuns.length;
  const totalLanes = Math.max(1, state.policy.maxParallelRuns);
  return {
    paused: state.paused,
    label: state.paused ? '⏸ Queue pausiert' : '▶ Queue läuft',
    policyLabel: describePolicy(state.policy),
    waiting: state.queue.length,
    startsIn: soonest !== null && soonest > now ? `nächster Start in ${formatCountdown(soonest - now)}` : null,
    lanes: laneLabel(totalLanes, busyLanes),
    busyLanes,
    totalLanes,
    blocked: state.blockedRunIds.length,
  };
}

/**
 * The waiting line under the pause chip: how many runs wait, how many of them for
 * a busy lane rather than for their turn, and when the next one may start.
 *
 * It lives here because it is written twice — once when the panel is built and
 * once per second by the countdown tick — and the two copies had drifted into
 * two grammars, of which the per-second one silently won every time.
 */
export function waitingLabel(summary: QueueSummary): string {
  const parts = [`${summary.waiting} wartend`];
  if (summary.blocked > 0) parts.push(`${summary.blocked} auf Spur`);
  if (summary.startsIn) parts.push(summary.startsIn);
  return parts.join(' · ');
}

/**
 * Scope ids naming a *kind* of work rather than a place: the server hands them to
 * a run in addition to the specific scope it guessed. Two lanes are therefore
 * routinely pointed at `core` without either of them owning it, and that is the
 * weaker of the two collisions — so it is reported differently from two lanes in
 * the same game.
 */
export const BROAD_SCOPE_IDS = new Set(['core', 'content']);

export interface LaneRisk {
  /** Scope both busy lanes were pointed at, e.g. `core`. */
  scope: string;
  /** Lanes involved, ascending. */
  lanes: number[];
  /** True for `core`/`content`: a supplement, not the owner of the files. */
  broad: boolean;
}

/**
 * Pairs of busy lanes that share a scope — the collision parallel lanes allow and
 * the owner asked for. It lists *every* shared scope, not only the broad ones:
 * two Tetris runs really can land in the same directory, and that is the case the
 * panel has to name.
 */
export function laneRisks(runs: readonly RunRecord[]): LaneRisk[] {
  const out: LaneRisk[] = [];
  for (let i = 0; i < runs.length; i += 1) {
    for (let j = i + 1; j < runs.length; j += 1) {
      const a = runs[i];
      const b = runs[j];
      if (a.lane == null || b.lane == null) continue;
      const shared = a.scopes.filter((id) => b.scopes.includes(id));
      for (const scope of shared) {
        out.push({ scope, lanes: [a.lane, b.lane].sort((x, y) => x - y), broad: BROAD_SCOPE_IDS.has(scope) });
      }
    }
  }
  return out;
}

/** One German warning line for `laneRisks`, or null when there is nothing to say. */
export function describeLaneRisks(risks: readonly LaneRisk[]): string | null {
  if (risks.length === 0) return null;
  const parts = risks.map((risk) =>
    risk.broad
      ? `${risk.scope} (Spur ${risk.lanes.join(' + ')}) — beide dürfen dort schreiben`
      : `${risk.scope} (Spur ${risk.lanes.join(' + ')}) — beide können dieselben Dateien anfassen`,
  );
  return `⚠ ${parts.join(', ')}. Der Scope-Audit meldet es, falls es passiert.`;
}

/** `Versuch 2/3` for a retried run, or null for a first attempt. */
export function attemptLabel(run: RunRecord): string | null {
  if (run.attempt <= 1) return null;
  return `Versuch ${run.attempt}/${run.maxAttempts}`;
}

export interface RunBadge {
  icon: string;
  label: string;
  title: string;
  kind: 'ok' | 'warn' | 'error' | 'muted';
}

/**
 * Why a run ended. The runner's note is authoritative: the agent's own summary
 * can say anything, and an agent that said something before hanging must still
 * read as a timeout.
 */
export function outcomeBadge(run: RunRecord): RunBadge | null {
  const timedOut = run.note?.startsWith('Zeitüberschreitung') ?? false;
  if (timedOut) {
    return {
      icon: '⏱',
      label: 'Zeitüberschreitung',
      title: `${run.note} · Zeitlimit ${formatCountdown(run.timeoutMs)}`,
      kind: 'error',
    };
  }
  if (run.status === 'succeeded') {
    return { icon: '✅', label: 'Erfolgreich', title: run.note ?? '', kind: 'ok' };
  }
  if (run.status === 'cancelled') {
    return { icon: '⏹', label: 'Abgebrochen', title: run.note ?? 'Vom Betreiber abgebrochen', kind: 'muted' };
  }
  if (run.status === 'failed') {
    return {
      icon: '⚠️',
      label: 'Fehlgeschlagen',
      title: run.note ?? 'Kein Grund hinterlegt',
      kind: 'error',
    };
  }
  return null;
}

/** Headline of a scope audit, or null when the run stayed inside its scope. */
export function scopeWarning(audit: ScopeAudit | null | undefined): string | null {
  if (!audit) return null;
  if (audit.violations.length > 0) {
    const extra = audit.violations.length > 1 ? ` (+${audit.violations.length - 1})` : '';
    return `Außerhalb des Scopes: ${audit.violations[0]}${extra}`;
  }
  if (audit.notes.length > 0) return audit.notes[0];
  if (audit.shared.length > 0) {
    const extra = audit.shared.length > 1 ? ` (+${audit.shared.length - 1})` : '';
    return `Geteilte Datei geändert: ${audit.shared[0]}${extra}`;
  }
  if (audit.unclaimed.length > 0) {
    const extra = audit.unclaimed.length > 1 ? ` (+${audit.unclaimed.length - 1})` : '';
    return `Datei außerhalb jedes Scopes: ${audit.unclaimed[0]}${extra}`;
  }
  return null;
}

export interface ScopeGroup {
  agent: string;
  scopes: ScopeInfo[];
}

/** Scopes grouped by their owning agent, for the layout panel. */
export function groupScopes(scopes: ScopeInfo[]): ScopeGroup[] {
  const groups = new Map<string, ScopeInfo[]>();
  for (const scope of scopes) {
    const list = groups.get(scope.agent);
    if (list) list.push(scope);
    else groups.set(scope.agent, [scope]);
  }
  return [...groups.entries()]
    .map(([agent, list]) => ({ agent, scopes: list }))
    .sort((a, b) => a.agent.localeCompare(b.agent));
}

/** The scope a run declares, with its label from the manifest. */
export function scopeLabel(run: RunRecord, manifest: ScopeManifest | null): string {
  if (run.scopes.length === 0) return 'kein Scope bekannt';
  const labels = run.scopes
    .map((id) => manifest?.scopes.find((s) => s.id === id)?.label ?? id)
    .join(', ');
  return labels;
}

/** One line about the manifest itself, shown above the scope list. */
export function manifestHeadline(manifest: ScopeManifest | null): string {
  if (!manifest) return 'Manifest wird geladen …';
  if (manifest.status === 'unavailable') {
    return `Manifest nicht lesbar: ${manifest.error ?? 'unbekannter Fehler'} — Scope-Prüfung ist aus`;
  }
  // Defensive: the page can outlive a server that answered with an older shape.
  const scopes = manifest.scopes ?? [];
  const games = scopes.filter((s) => s.agent === 'agent-game').length;
  const base = `${scopes.length} Scopes, davon ${games} Spiel-Scopes · `;
  if (manifest.problems.length === 0) return `${base}Manifest ist konsistent.`;
  return `${base}${manifest.problems.length} Manifest-Problem(e): ${manifest.problems[0]}`;
}
