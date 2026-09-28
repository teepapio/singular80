import type {
  QueueState,
  RunRecord,
  RunnerPolicy,
  ScopeAudit,
  ScopeInfo,
  ScopeManifest,
} from '../shared/types';

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
  const seconds = Math.max(0, Math.round(ms / 1000));
  if (seconds < 60) return `${seconds} s`;
  const minutes = Math.floor(seconds / 60);
  const rest = seconds % 60;
  if (minutes < 60) return rest > 0 ? `${minutes} min ${rest} s` : `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  return `${hours} h ${minutes % 60} min`;
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
 * Scope ids naming a kind of work rather than a place, which the server hands to
 * a run *in addition* to the specific scope. Two lanes can therefore both be
 * pointed at the same one — the scheduler allows that, or the queue stays
 * serial — so the panel says it out loud. Mirrors `BROAD_SCOPES` in
 * `server/scopes.ts`.
 */
export const BROAD_SCOPE_IDS = new Set(['core', 'content']);

export interface LaneRisk {
  /** Scope both busy lanes were pointed at, e.g. `core`. */
  scope: string;
  /** Lanes involved, ascending. */
  lanes: number[];
}

/** Pairs of busy lanes sharing a broad scope: the one collision the queue allows. */
export function laneRisks(runs: readonly RunRecord[]): LaneRisk[] {
  const out: LaneRisk[] = [];
  for (let i = 0; i < runs.length; i += 1) {
    for (let j = i + 1; j < runs.length; j += 1) {
      const a = runs[i];
      const b = runs[j];
      if (a.lane == null || b.lane == null) continue;
      const shared = a.scopes.filter((id) => BROAD_SCOPE_IDS.has(id) && b.scopes.includes(id));
      for (const scope of shared) {
        out.push({ scope, lanes: [a.lane, b.lane].sort((x, y) => x - y) });
      }
    }
  }
  return out;
}

/** One German warning line for `laneRisks`, or null when there is nothing to say. */
export function describeLaneRisks(risks: readonly LaneRisk[]): string | null {
  if (risks.length === 0) return null;
  const parts = risks.map((risk) => `${risk.scope} (Spur ${risk.lanes.join(' + ')})`);
  return `⚠ ${parts.join(', ')} — beide Spuren dürfen dort schreiben; der Scope-Audit meldet es, falls es passiert.`;
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
  const games = scopes.filter((s) => s.agent === 'game').length;
  const base = `${scopes.length} Scopes, davon ${games} Spiel-Scopes · `;
  if (manifest.problems.length === 0) return `${base}Manifest ist konsistent.`;
  return `${base}${manifest.problems.length} Manifest-Problem(e): ${manifest.problems[0]}`;
}
