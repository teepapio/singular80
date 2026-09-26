import './style.css';
import type {
  BusEvent,
  QueueState,
  RunEvent,
  RunRecord,
  RunView,
  ScopeAudit,
  ScopeManifest,
  SuggestionView,
} from '../shared/types';
import {
  attemptLabel,
  describeQueue,
  formatCountdown,
  groupScopes,
  manifestHeadline,
  outcomeBadge,
  scopeLabel,
  scopeWarning,
} from './queueControls';
import { describeRunActivity, formatDuration, lastEventTimestamp, needsRunCleanup } from './runActivity';

type Tab = 'queue' | 'new' | 'top' | 'cluster' | 'done';

interface DashboardState {
  suggestions: SuggestionView[];
  runs: RunRecord[];
  activeRun: RunRecord | null;
  runEvents: RunEvent[];
  /** Wall-clock time of the last received/synced event of the active run. */
  lastActivityAt: number | null;
  /** Whether the server still tracks a live process for the active run. */
  activeRunAlive: boolean | null;
  /** Pause state, policy and pending runs as the server reports them. */
  queue: QueueState | null;
  /** Scope layout the runner depends on (from scripts/scopes.mjs). */
  manifest: ScopeManifest | null;
  /** Which files a run touched relative to its declared scope. */
  audit: ScopeAudit | null;
  tab: Tab;
  category: string | null;
  search: string;
  expanded: Set<number>;
  connected: boolean;
  /** Suggestion id currently being split in the dialog, or null. */
  splitFor: number | null;
}

const state: DashboardState = {
  suggestions: [],
  runs: [],
  activeRun: null,
  runEvents: [],
  lastActivityAt: null,
  activeRunAlive: null,
  queue: null,
  manifest: null,
  audit: null,
  tab: 'queue',
  category: null,
  search: '',
  expanded: new Set(),
  connected: false,
  splitFor: null,
};

/** How often the "last output" indicator is refreshed while a run is active. */
const ACTIVITY_TICK_MS = 1000;
/** How long the run may be quiet before we re-check it against the API. */
const ACTIVITY_RESYNC_MS = 15_000;
/** Minimum spacing between automatic run cleanups triggered by the dashboard. */
const AUTO_RECONCILE_COOLDOWN_MS = 30_000;

/** Guards against overlapping or self-triggering automatic run cleanups. */
let autoReconcileRunning = false;
let lastAutoReconcileAt = 0;

const CATEGORY_LABELS: Record<string, string> = {
  mechanics: 'Mechanik',
  content: 'Content',
  balance: 'Balance',
  bug: 'Bug',
  ui: 'UI',
  audio: 'Audio',
  other: 'Sonstiges',
};

const STATUS_LABELS: Record<string, string> = {
  new: 'Neu',
  approved: 'Genehmigt',
  rejected: 'Abgelehnt',
  implementing: 'Läuft',
  implemented: 'Umgesetzt',
  failed: 'Fehlgeschlagen',
};

const $ = <T extends HTMLElement>(selector: string): T => document.querySelector(selector) as T;

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function voterId(): string {
  try {
    let id = localStorage.getItem('singular80_voter');
    if (!id) {
      id = `voter_${Math.random().toString(36).slice(2)}${Date.now().toString(36)}`;
      localStorage.setItem('singular80_voter', id);
    }
    return id;
  } catch {
    return `voter_${Math.random().toString(36).slice(2)}`;
  }
}

function timeAgo(timestamp: number): string {
  const seconds = Math.floor((Date.now() - timestamp) / 1000);
  if (seconds < 60) return 'gerade eben';
  if (seconds < 3600) return `vor ${Math.floor(seconds / 60)} min`;
  if (seconds < 86400) return `vor ${Math.floor(seconds / 3600)} h`;
  return `vor ${Math.floor(seconds / 86400)} d`;
}

/** Records the newest activity of the active run, ignoring out-of-order times. */
function markActivity(timestamp?: number): void {
  const now = Date.now();
  const t = Math.min(timestamp ?? now, now);
  state.lastActivityAt = state.lastActivityAt === null ? t : Math.max(state.lastActivityAt, t);
}

async function api<T>(path: string, init?: RequestInit): Promise<T> {
  // Only advertise a JSON body when there actually is one. Otherwise Fastify
  // rejects empty POST/PATCH requests with
  // "Body cannot be empty when content-type is set to 'application/json'".
  const headers = new Headers(init?.headers);
  if (init?.body != null && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json');
  }
  const res = await fetch(path, { ...init, headers });
  if (!res.ok) {
    const body = (await res.json().catch(() => ({}))) as { error?: string };
    throw new Error(body.error ?? `HTTP ${res.status}`);
  }
  return (await res.json()) as T;
}

function toast(message: string, kind: 'info' | 'success' | 'error' = 'info'): void {
  const container = $('#toasts');
  const el = document.createElement('div');
  el.className = `toast ${kind}`;
  el.textContent = message;
  container.appendChild(el);
  setTimeout(() => el.remove(), 6000);
}

/** Ids of suggestions that were split into sub-tasks (container orders). */
function parentIds(): Set<number> {
  const ids = new Set<number>();
  for (const s of state.suggestions) if (s.parentId != null) ids.add(s.parentId);
  return ids;
}

/** Ids of sub-tasks that belong to the given suggestion. */
function childrenOf(id: number): number[] {
  const ids: number[] = [];
  for (const s of state.suggestions) if (s.parentId === id) ids.push(s.id);
  return ids;
}

function visibleSuggestions(): SuggestionView[] {
  let list = [...state.suggestions];
  if (state.category) list = list.filter((s) => s.category === state.category);
  if (state.search) {
    const needle = state.search.toLowerCase();
    list = list.filter((s) => s.text.toLowerCase().includes(needle) || `#${s.id}`.includes(needle));
  }
  switch (state.tab) {
    case 'queue': {
      // Parents that were split into sub-tasks are containers, not runnable orders.
      const parents = parentIds();
      list = list.filter((s) => (s.status === 'approved' || s.status === 'implementing') && !parents.has(s.id));
      return list.sort((a, b) => b.score - a.score || b.votes - a.votes);
    }
    case 'new':
      list = list.filter((s) => s.status === 'new');
      return list.sort((a, b) => b.score - a.score || b.createdAt - a.createdAt);
    case 'top':
      list = list.filter((s) => s.status !== 'rejected');
      return list.sort((a, b) => b.votes - a.votes || b.score - a.score);
    case 'cluster':
      return list.sort((a, b) => b.clusterSize - a.clusterSize || b.score - a.score);
    case 'done':
      list = list.filter((s) => s.status === 'implemented' || s.status === 'failed' || s.status === 'rejected');
      return list.sort((a, b) => b.updatedAt - a.updatedAt);
    default:
      return list;
  }
}

function renderStats(): void {
  const stats = $('#stats');
  const total = state.suggestions.length;
  const parents = parentIds();
  const queue = state.suggestions.filter(
    (s) => (s.status === 'approved' || s.status === 'implementing') && !parents.has(s.id),
  ).length;
  const implemented = state.suggestions.filter((s) => s.status === 'implemented').length;
  const votes = state.suggestions.reduce((sum, s) => sum + s.votes, 0);
  const clusters = new Set(state.suggestions.map((s) => s.canonicalId ?? s.id)).size;
  const cards = [
    { value: total, label: 'Vorschläge gesamt' },
    { value: queue, label: 'in der Queue' },
    { value: implemented, label: 'umgesetzt' },
    { value: votes, label: 'Stimmen' },
    { value: clusters, label: 'Cluster' },
  ];
  stats.innerHTML = cards
    .map((c) => `<div class="stat"><div class="value">${c.value}</div><div class="label">${c.label}</div></div>`)
    .join('');
}

function renderCategories(): void {
  const container = $('#categories');
  const cats = ['all', ...Object.keys(CATEGORY_LABELS)];
  container.innerHTML = cats
    .map(
      (cat) =>
        `<button class="chip ${(state.category ?? 'all') === cat ? 'active' : ''}" data-category="${cat}">${
          cat === 'all' ? 'Alle' : CATEGORY_LABELS[cat]
        }</button>`,
    )
    .join('');
}

function renderCard(s: SuggestionView, children: number[]): string {
  const expanded = state.expanded.has(s.id);
  const isClusterCanonical = s.canonicalId === null || s.canonicalId === s.id;
  const hasChildren = children.length > 0;
  const run = s.run;
  const runBadge =
    run && (run.status === 'running' || run.status === 'queued')
      ? `<span class="badge status-implementing">Run ${run.status === 'queued' ? 'in Warteschlange' : 'läuft'}</span>`
      : '';
  const commit = run?.commitHash ? ` · <code>${escapeHtml(run.commitHash)}</code>` : '';
  return `
    <article class="card" id="suggestion-${s.id}" data-id="${s.id}">
      <div class="card-head">
        <span class="badge cat-${s.category}">${CATEGORY_LABELS[s.category] ?? s.category}</span>
        <span class="badge status-${s.status}">${STATUS_LABELS[s.status] ?? s.status}</span>
        ${runBadge}
        ${s.clusterSize > 1 ? `<span title="ähnliche Vorschläge">🧩 ${s.clusterSize}</span>` : ''}
        ${s.parentId != null ? `<span class="badge split-child" title="Teilauftrag von #${s.parentId}">↳ Teil von #${s.parentId}</span>` : ''}
        ${hasChildren ? `<span class="badge split-parent" title="In Einzelaufträge aufgeteilt">✂ ${children.length}</span>` : ''}
        <span>#${s.id}</span>
        <span>${escapeHtml(s.author)}</span>
        <span>${timeAgo(s.createdAt)}</span>
        <span class="score" title="Prioritäts-Score (ohne KI berechnet)">Score ${s.score}</span>
      </div>
      <p class="card-text">${escapeHtml(s.text)}</p>
      ${run?.resultSummary ? `<p class="card-summary"><span class="summary-label">🤖 Umsetzung:</span> ${escapeHtml(run.resultSummary)}</p>` : ''}
      <div class="card-meta">
        <span>👍 ${s.votes} Stimmen</span>
        ${s.discordMessageId ? '<span title="an Discord gesendet">📨 Discord</span>' : ''}
        ${run && run.status !== 'running' ? `<span>🤖 ${run.status}${commit}</span>` : ''}
        ${run?.scope ? `<span title="Scope aus scripts/scopes.mjs">📁 ${escapeHtml(scopeLabel(run, state.manifest))}</span>` : ''}
        ${!isClusterCanonical ? `<span>gehört zu Cluster #${s.canonicalId}</span>` : ''}
        ${hasChildren ? `<span>Aufgeteilt in ${children.length} Einzelaufträge: ${children.map((id) => `#${id}`).join(', ')}</span>` : ''}
      </div>
      <div class="card-actions">
        <button class="vote" data-action="vote" data-id="${s.id}">👍 Stimme</button>
        ${
          s.status !== 'approved' && s.status !== 'implemented' && s.status !== 'implementing'
            ? `<button class="approve" data-action="approve" data-id="${s.id}">✓ Genehmigen</button>`
            : ''
        }
        ${
          s.status !== 'rejected' && s.status !== 'implemented'
            ? `<button class="reject" data-action="reject" data-id="${s.id}">✕ Ablehnen</button>`
            : ''
        }
        ${
          s.status !== 'implementing' && !hasChildren
            ? `<button class="implement" data-action="implement" data-id="${s.id}">🤖 In OpenCode umsetzen</button>`
            : ''
        }
        ${
          s.status !== 'implemented' && s.status !== 'implementing' && !hasChildren
            ? `<button data-action="split" data-id="${s.id}">✂ Aufteilen</button>`
            : ''
        }
        <button data-action="details" data-id="${s.id}">${expanded ? '▴ Details' : '▾ Details'}</button>
      </div>
      ${
        expanded
          ? `<div class="details">
              <strong>Score-Zerlegung</strong>
              <div class="breakdown">
                <div>Stimmen: +${s.breakdown.votes}</div>
                <div>Cluster: +${s.breakdown.cluster}</div>
                <div>Frische: +${s.breakdown.recency.toFixed(1)}</div>
                <div>Kategorie: +${s.breakdown.category}</div>
                <div>Qualität: +${s.breakdown.quality}</div>
                <div>Malus: −${s.breakdown.penalty}</div>
              </div>
              ${s.clusterIds.length > 1 ? `<div style="margin-top:8px"><strong>Cluster:</strong> ${s.clusterIds.map((id) => `#${id}`).join(', ')}</div>` : ''}
              ${run ? `<div style="margin-top:8px"><strong>Letzter Run:</strong> ${run.id} · ${run.status} · ${run.cost != null ? `$${run.cost.toFixed(4)}` : 'Kosten unbekannt'}${run.tokensInput != null ? ` · ${run.tokensInput}/${run.tokensOutput} Tokens` : ''}${attemptLabel(run) ? ` · ${attemptLabel(run)}` : ''}</div>` : ''}
              <div style="margin-top:8px"><strong>Quelle:</strong> ${escapeHtml(s.source)} · erstellt ${new Date(s.createdAt).toLocaleString('de-DE')}</div>
              ${s.clientKey ? `<div style="margin-top:8px"><strong>Client-Key:</strong> <code>${escapeHtml(s.clientKey)}</code> · ein Retry mit diesem Schlüssel legt keine zweite Zeile an</div>` : ''}
            </div>`
          : ''
      }
    </article>
  `;
}

function renderList(): void {
  const list = visibleSuggestions();
  const container = $('#list');
  $('#empty').hidden = list.length > 0;
  container.innerHTML = list.map((s) => renderCard(s, childrenOf(s.id))).join('');
  const hash = location.hash.match(/^#suggestion-(\d+)$/);
  if (hash) {
    const el = document.getElementById(`suggestion-${hash[1]}`);
    if (el) {
      el.classList.add('highlight');
      el.scrollIntoView({ block: 'center' });
    }
  }
}

function renderRuns(): void {
  const active = $('#active-run');
  const running = state.activeRun && state.activeRun.status === 'running' ? state.activeRun : null;
  const runningCount = state.runs.filter((r) => r.status === 'running').length;
  const queued = state.runs.filter((r) => r.status === 'queued').slice(0, 20);

  renderQueueState();

  let html = '';
  // A server restart can leave several runs marked as "running" at once. Surface
  // that clearly and offer a one-click cleanup instead of silently showing the
  // newest one.
  if (runningCount > 1) {
    html += `
      <div class="run-warning">
        <span>⚠ ${runningCount} Runs sind gleichzeitig als „läuft“ markiert (z. B. nach einem Neustart).</span>
        <button data-action="reconcile-runs">🧹 Jetzt aufräumen</button>
      </div>`;
  }
  if (running) {
    const activity = describeRunActivity({
      lastActivityAt: state.lastActivityAt,
      startedAt: running.startedAt,
      connected: state.connected,
      alive: state.activeRunAlive ?? undefined,
    });
    const lines = state.runEvents
      .slice(-400)
      .map((event) => `<div class="line ${event.kind}">${escapeHtml(event.text)}</div>`)
      .join('');
    const warning = scopeWarning(state.audit);
    html += `
      <div class="run-card activity-${activity.level}" id="active-run-card">
        <div class="run-title">
          <span>🤖 Vorschlag #${running.suggestionId}</span>
          <span>${state.activeRunAlive === false ? '⚠ Prozess weg' : '⚙ läuft'}</span>
        </div>
        <div class="run-sub" id="run-budget">${escapeHtml(runBudgetLine(running))}</div>
        <div class="run-sub">📁 ${escapeHtml(scopeLabel(running, state.manifest))}</div>
        ${
          warning
            ? `<div class="run-warning" title="Der Run hat Dateien außerhalb seines Scopes angefasst">⚠ ${escapeHtml(warning)}</div>`
            : ''
        }
        <div class="run-activity ${activity.level}" id="run-activity" title="Zeit seit der letzten Ausgabe von OpenCode">
          ${escapeHtml(activity.label)}
        </div>
        <div class="console" id="active-console">${lines}</div>
        <div class="card-actions">
          <button data-action="cancel-run" data-run="${running.id}">⏹ Abbrechen</button>
          ${
            activity.level === 'stale' || activity.level === 'offline'
              ? '<button data-action="reconcile-runs">🧹 Als beendet markieren</button>'
              : ''
          }
        </div>
      </div>
    `;
  } else {
    html += '<p class="run-sub">Kein aktiver Run. Klicke bei einem Vorschlag auf „In OpenCode umsetzen“.</p>';
  }

  if (queued.length > 0) {
    html += `
      <div class="run-title" style="margin-top:14px">
        <span>⏳ Warteschlange</span>
        <span>${queued.length}</span>
      </div>
    `;
    html += queued
      .map((run) => {
        const badge = attemptLabel(run);
        const wait =
          run.notBefore && run.notBefore > Date.now() ? ` · startet in ${formatCountdown(run.notBefore - Date.now())}` : '';
        return `
      <div class="run-card">
        <div class="run-title">
          <span>#${run.suggestionId}${badge ? ` · ${escapeHtml(badge)}` : ''}</span>
          <span>wartet</span>
        </div>
        <div class="run-sub">${escapeHtml(run.id)}${escapeHtml(wait)}</div>
        <div class="card-actions">
          <button data-action="cancel-run" data-run="${run.id}">⏹ Entfernen</button>
        </div>
      </div>`;
      })
      .join('');
  }

  active.innerHTML = html;
  const consoleEl = document.getElementById('active-console');
  if (consoleEl) consoleEl.scrollTop = consoleEl.scrollHeight;
  updateRunActivity();

  $('#run-history').innerHTML = renderRunHistory();
  renderScopes();
}

/** Pause chip plus the policy that is currently in force. */
function renderQueueState(): void {
  const container = $('#queue-state');
  const button = $('#toggle-pause') as HTMLButtonElement | null;
  if (!state.queue) {
    container.innerHTML = '<span class="chip muted">Queue unbekannt</span>';
    if (button) button.disabled = true;
    return;
  }
  if (button) {
    button.disabled = false;
    button.textContent = state.queue.paused ? '▶' : '⏸';
    button.title = state.queue.paused
      ? 'Warteschlange fortsetzen'
      : 'Warteschlange anhalten — der laufende Run läuft weiter';
  }
  const summary = describeQueue(state.queue, Date.now());
  container.innerHTML = `
    <span class="chip ${summary.paused ? 'paused' : 'active'}">${escapeHtml(summary.label)}</span>
    <span class="policy" id="queue-policy">${escapeHtml(summary.policyLabel)}</span>
    <span class="policy" id="queue-waiting">${summary.waiting} wartend${summary.startsIn ? ` · ${escapeHtml(summary.startsIn)}` : ''}</span>
  `;
}

/**
 * Ticks the countdown of a pending backoff without rebuilding the panel. Only
 * the text node changes, so a queued run does not re-render every second.
 */
function updateQueueCountdown(): void {
  const el = document.getElementById('queue-waiting');
  if (!el || !state.queue) return;
  const summary = describeQueue(state.queue, Date.now());
  el.textContent = `${summary.waiting} wartend${summary.startsIn ? ` · ${summary.startsIn}` : ''}`;
}

/** Finished runs: why they ended, which attempt, and which scope they touched. */
function renderRunHistory(): string {
  const history = state.runs
    .filter((r) => r.status !== 'running' && r.status !== 'queued')
    .slice(0, 8)
    .map((run) => {
      const badge = outcomeBadge(run);
      const attempt = attemptLabel(run);
      const audit = run.id === state.audit?.runId ? state.audit : parseStoredAudit(run);
      const warning = scopeWarning(audit);
      return `
      <div class="run-card">
        <div class="run-title">
          <span>#${run.suggestionId}${attempt ? ` · ${escapeHtml(attempt)}` : ''}</span>
          <span>${badge ? `${badge.icon} ${escapeHtml(badge.label)}` : escapeHtml(run.status)}</span>
        </div>
        <div class="run-sub">
          ${escapeHtml(run.id)}${run.commitHash ? ` · <code>${escapeHtml(run.commitHash)}</code>` : ''}
          ${run.cost != null ? ` · $${run.cost.toFixed(4)}` : ''}
          ${run.finishedAt ? ` · ${timeAgo(run.finishedAt)}` : ''}
        </div>
        <div class="run-sub">📁 ${escapeHtml(scopeLabel(run, state.manifest))}${
          run.retryOf ? ` · ↻ wiederholt ${escapeHtml(run.retryOf)}` : ''
        }</div>
        ${warning ? `<div class="run-warning">⚠ ${escapeHtml(warning)}</div>` : ''}
        <div class="card-actions">
          ${
            run.status === 'failed' || run.status === 'cancelled'
              ? `<button data-action="retry-run" data-run="${run.id}">↻ Wiederholen</button>`
              : ''
          }
        </div>
      </div>`;
    })
    .join('');
  return history || '<p class="run-sub" style="margin-top:10px">Noch keine Runs.</p>';
}

/** The scope layout, grouped by owning agent, with the active run highlighted. */
function renderScopes(): void {
  const list = $('#scope-list');
  if (!list) return;
  $('#scope-headline').textContent = manifestHeadline(state.manifest);
  if (!state.manifest || state.manifest.scopes.length === 0) {
    list.innerHTML = '<p class="run-sub">Keine Scopes geladen.</p>';
    return;
  }
  const active = state.activeRun?.scopes ?? [];
  list.innerHTML = groupScopes(state.manifest.scopes)
    .map(
      (group) => `
      <div class="scope-group">
        <div class="scope-agent">${escapeHtml(group.agent)} · ${group.scopes.length}</div>
        ${group.scopes
          .map(
            (scope) => `
          <div class="scope-row ${active.includes(scope.id) ? 'current' : ''}">
            <span class="scope-id">${escapeHtml(scope.id)}</span>
            <span class="scope-label">${escapeHtml(scope.label)}</span>
            <span class="scope-meta" title="${escapeHtml(scope.own.join('\n'))}">${scope.own.length} eigene${
              scope.suites.length ? ` · ${scope.suites.length} Suiten` : ''
            }</span>
          </div>`,
          )
          .join('')}
      </div>`,
    )
    .join('');
}

/** Reads the audit that the runner stored with the run. */
function parseStoredAudit(run: RunRecord): ScopeAudit | null {
  if (!run.scopeIssues) return null;
  try {
    const stored = JSON.parse(run.scopeIssues) as Partial<ScopeAudit>;
    return {
      runId: run.id,
      scopes: run.scopes,
      agent: null,
      ok: (stored.violations?.length ?? 0) === 0,
      violations: stored.violations ?? [],
      shared: stored.shared ?? [],
      unclaimed: stored.unclaimed ?? [],
      notes: stored.notes ?? [],
      checked: stored.checked ?? 0,
    };
  } catch {
    return null;
  }
}

/** One line with run id, runtime and the remaining hard-timeout budget. */
function runBudgetLine(run: RunRecord): string {
  const elapsed = run.startedAt ? `läuft seit ${formatDuration(Date.now() - run.startedAt)}` : 'startet gerade';
  if (run.timeoutMs <= 0 || !run.startedAt) return `${run.id} · ${elapsed} · ohne Zeitlimit`;
  const left = Math.max(0, run.startedAt + run.timeoutMs - Date.now());
  return `${run.id} · ${elapsed} · Restzeit ${formatCountdown(left)} von ${formatCountdown(run.timeoutMs)}`;
}

/** Refreshes the live "last output" indicator without rebuilding the whole panel. */
function updateRunActivity(): void {
  const el = document.getElementById('run-activity');
  const budget = document.getElementById('run-budget');
  const running = state.activeRun && state.activeRun.status === 'running' ? state.activeRun : null;
  if (budget && running) budget.textContent = runBudgetLine(running);
  if (!el || !running) return;
  const activity = describeRunActivity({
    lastActivityAt: state.lastActivityAt,
    startedAt: running.startedAt,
    connected: state.connected,
    alive: state.activeRunAlive ?? undefined,
  });
  el.className = `run-activity ${activity.level}`;
  el.textContent = activity.label;
  const card = document.getElementById('active-run-card');
  if (card) card.className = `run-card activity-${activity.level}`;
}

/**
 * Re-fetches the running run from the API. This recovers events missed while the
 * SSE stream was interrupted and provides an accurate "last output" timestamp
 * when the run has been quiet for a while.
 */
async function syncActiveRun(): Promise<void> {
  const running = state.activeRun;
  if (!running || running.status !== 'running') return;
  const base = state.lastActivityAt ?? running.startedAt;
  const silentMs = base == null ? 0 : Date.now() - base;
  // While the stream is delivering we do not need to poll.
  if (state.connected && silentMs < ACTIVITY_RESYNC_MS) return;
  try {
    const view = await api<RunView>(`/api/runs/${running.id}`);
    if (state.activeRun?.id !== running.id) return;
    if (view.status !== 'running') {
      // The finish event was missed: refresh so the run leaves the active panel.
      await refreshAll();
      return;
    }
    state.runEvents = view.events;
    state.activeRunAlive = view.alive;
    markActivity(lastEventTimestamp(view.events) ?? view.startedAt ?? undefined);
    renderRuns();
  } catch {
    /* run view is best-effort */
  }
}

function render(): void {
  renderStats();
  renderCategories();
  renderList();
  renderRuns();
}

async function loadSuggestions(): Promise<void> {
  const data = await api<{ suggestions: SuggestionView[] }>('/api/suggestions');
  state.suggestions = data.suggestions;
}

async function loadRuns(): Promise<void> {
  const data = await api<{ runs: RunRecord[] }>('/api/runs');
  state.runs = data.runs;
  // Only one run executes at a time: show the actually running one, not the last queued.
  const running = data.runs.find((r) => r.status === 'running') ?? null;
  const changedRun = state.activeRun?.id !== running?.id;
  state.activeRun = running;
  if (!running) {
    state.runEvents = [];
    state.lastActivityAt = null;
    state.activeRunAlive = null;
    state.audit = null;
    return;
  }
  // A fresh run starts with an empty console and activity clock.
  if (changedRun) {
    state.runEvents = [];
    state.lastActivityAt = null;
    state.activeRunAlive = null;
    state.audit = null;
  }
  // Populate/refresh the console from the server, so an already running run shows
  // its progress (and last-output time) even when SSE events were missed.
  try {
    const view = await api<RunView>(`/api/runs/${running.id}`);
    if (state.activeRun?.id === running.id) {
      state.runEvents = view.events;
      state.activeRunAlive = view.alive;
      state.audit = view.scopeAudit;
      markActivity(lastEventTimestamp(view.events) ?? view.startedAt ?? undefined);
    }
  } catch {
    /* run view is best-effort */
  }
}

async function loadQueue(): Promise<void> {
  try {
    state.queue = await api<QueueState & { runnerEnabled: boolean }>('/api/runner');
  } catch {
    state.queue = null;
  }
}

async function loadManifest(): Promise<void> {
  try {
    state.manifest = await api<ScopeManifest>('/api/scopes');
  } catch {
    state.manifest = null;
  }
}

/** Pauses or resumes the queue. The running run keeps its process either way. */
async function togglePause(): Promise<void> {
  if (!state.queue) return;
  const paused = !state.queue.paused;
  try {
    const next = await api<QueueState>('/api/runner/pause', {
      method: 'POST',
      body: JSON.stringify({ paused }),
    });
    state.queue = next;
    toast(paused ? 'Warteschlange pausiert — der laufende Run läuft weiter.' : 'Warteschlange läuft weiter.', 'success');
    await refreshAll();
  } catch (err) {
    toast((err as Error).message, 'error');
  }
}

/** Starts another attempt of a finished run. */
async function retryRun(runId: string): Promise<void> {
  try {
    const result = await api<{ run: RunRecord }>(`/api/runs/${runId}/retry`, {
      method: 'POST',
      body: JSON.stringify({}),
    });
    toast(`Neuer Versuch für #${result.run.suggestionId} in der Warteschlange`, 'success');
    await refreshAll();
  } catch (err) {
    toast((err as Error).message, 'error');
  }
}

async function loadSettings(): Promise<void> {
  const settings = await api<{
    discordWebhook: string;
    model: string;
    extraInstructions: string;
    autoApprove: boolean;
    autoApproveScore: number;
    runTimeoutMinutes: number;
    retryLimit: number;
    retryBackoffSeconds: number;
    webhookConfigured: boolean;
    envWebhook: boolean;
  }>('/api/settings');
  ($('#setting-webhook') as HTMLInputElement).value = settings.envWebhook ? '' : '';
  ($('#setting-webhook') as HTMLInputElement).placeholder = settings.webhookConfigured
    ? `konfiguriert (${settings.discordWebhook})`
    : 'https://discord.com/api/webhooks/…';
  ($('#setting-model') as HTMLInputElement).value = settings.model;
  ($('#setting-instructions') as HTMLTextAreaElement).value = settings.extraInstructions;
  ($('#setting-autoapprove') as HTMLInputElement).checked = settings.autoApprove;
  ($('#setting-autoscore') as HTMLInputElement).value = String(settings.autoApproveScore);
  ($('#setting-timeout') as HTMLInputElement).value = String(settings.runTimeoutMinutes);
  ($('#setting-retries') as HTMLInputElement).value = String(settings.retryLimit);
  ($('#setting-backoff') as HTMLInputElement).value = String(settings.retryBackoffSeconds);
  $('#webhook-state').textContent = settings.webhookConfigured
    ? settings.envWebhook
      ? 'Webhook kommt aus .env'
      : `Gespeichert: ${settings.discordWebhook}`
    : 'Noch kein Webhook gesetzt — Vorschläge werden nicht an Discord gesendet.';
}

async function refreshAll(): Promise<void> {
  try {
    await Promise.all([loadSuggestions(), loadRuns(), loadQueue(), loadManifest()]);
    render();
    void maybeAutoReconcile();
  } catch (err) {
    toast((err as Error).message, 'error');
  }
}

function splitTasksFromArea(): string[] {
  const area = $('#split-tasks') as HTMLTextAreaElement;
  return area.value
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
}

function updateSplitCount(): void {
  const count = splitTasksFromArea().length;
  $('#split-count').textContent = `${count} Einzelauftrag${count === 1 ? '' : 'träge'} — jede Zeile wird ein eigener Auftrag.`;
  ($('#split-create') as HTMLButtonElement).disabled = count < 2;
}

/** Open the split dialog and pre-fill it with the automatic split suggestion. */
async function openSplitDialog(id: number): Promise<void> {
  try {
    const data = await api<{ suggestion: SuggestionView; tasks: string[] }>(`/api/suggestions/${id}/split`);
    state.splitFor = id;
    $('#split-parent').textContent = `#${id} · ${data.suggestion.text}`;
    const area = $('#split-tasks') as HTMLTextAreaElement;
    area.value = data.tasks.join('\n');
    updateSplitCount();
    const dialog = $('#split-dialog') as HTMLDialogElement;
    if (!dialog.open) dialog.showModal();
    area.focus();
  } catch (err) {
    toast((err as Error).message, 'error');
  }
}

/** Finalizes runs whose opencode process is gone (e.g. after a crash/restart). */
async function reconcileRuns(): Promise<void> {
  try {
    const result = await api<{ fixed: RunRecord[] }>('/api/runs/reconcile', { method: 'POST' });
    if (result.fixed.length === 0) toast('Keine verwaisten Runs gefunden.');
    else toast(`${result.fixed.length} verwaiste${result.fixed.length === 1 ? 'r' : ''} Run${result.fixed.length === 1 ? '' : 's'} aufgeräumt`, 'success');
    await refreshAll();
  } catch (err) {
    toast((err as Error).message, 'error');
  }
}

/**
 * Self-healing: when the dashboard notices phantom running rows (e.g. it was
 * reopened after a run was interrupted), it cleans them up automatically
 * instead of leaving the user with a confusing list of "running" runs.
 */
async function maybeAutoReconcile(): Promise<void> {
  const runningCount = state.runs.filter((r) => r.status === 'running').length;
  if (!needsRunCleanup({ runningCount, activeRunAlive: state.activeRunAlive })) return;
  if (autoReconcileRunning) return;
  if (Date.now() - lastAutoReconcileAt < AUTO_RECONCILE_COOLDOWN_MS) return;
  autoReconcileRunning = true;
  lastAutoReconcileAt = Date.now();
  try {
    await reconcileRuns();
  } finally {
    autoReconcileRunning = false;
  }
}

async function act(action: string, id: number, runId?: string): Promise<void> {
  if (action === 'split') {
    await openSplitDialog(id);
    return;
  }
  try {
    if (action === 'vote') {
      const result = await api<{ votes: number }>(`/api/suggestions/${id}/vote`, {
        method: 'POST',
        body: JSON.stringify({ voterId: voterId() }),
      });
      toast(`Stimme gezählt (${result.votes})`, 'success');
    } else if (action === 'approve') {
      await api(`/api/suggestions/${id}`, { method: 'PATCH', body: JSON.stringify({ status: 'approved' }) });
      toast(`#${id} genehmigt`, 'success');
    } else if (action === 'reject') {
      await api(`/api/suggestions/${id}`, { method: 'PATCH', body: JSON.stringify({ status: 'rejected' }) });
      toast(`#${id} abgelehnt`);
    } else if (action === 'implement') {
      await api<{ run: RunRecord }>(`/api/suggestions/${id}/implement`, {
        method: 'POST',
        body: JSON.stringify({}),
      });
      toast(`Run für #${id} in die Warteschlange gestellt`, 'success');
    } else if (action === 'cancel-run' && runId) {
      await api(`/api/runs/${runId}/cancel`, { method: 'POST', body: JSON.stringify({}) });
      toast('Run abgebrochen');
    } else if (action === 'retry-run' && runId) {
      await retryRun(runId);
      return;
    } else if (action === 'details') {
      if (state.expanded.has(id)) state.expanded.delete(id);
      else state.expanded.add(id);
      renderList();
      return;
    }
    await refreshAll();
  } catch (err) {
    toast((err as Error).message, 'error');
  }
}

function connectEvents(): void {
  const source = new EventSource('/api/events');
  // The first open happens right after `main` already loaded everything; later
  // opens follow an interruption (e.g. server restart) and must resync the whole
  // view because events may have been missed or runs silently finalized.
  let hadConnection = false;
  source.onopen = () => {
    state.connected = true;
    const el = $('#connection');
    el.classList.add('online');
    el.classList.remove('offline');
    el.innerHTML = '<span class="dot"></span> live';
    updateRunActivity();
    if (hadConnection) void refreshAll();
    else void syncActiveRun();
    hadConnection = true;
  };
  source.onerror = () => {
    state.connected = false;
    const el = $('#connection');
    el.classList.remove('online');
    el.classList.add('offline');
    el.innerHTML = '<span class="dot"></span> getrennt';
    updateRunActivity();
  };
  source.onmessage = (message) => {
    let event: BusEvent;
    try {
      event = JSON.parse(message.data) as BusEvent;
    } catch {
      return;
    }
    if (event.type === 'suggestion:new') {
      const existing = state.suggestions.findIndex((s) => s.id === event.suggestion.id);
      if (existing >= 0) state.suggestions[existing] = event.suggestion;
      else state.suggestions.push(event.suggestion);
      toast(`Neuer Vorschlag #${event.suggestion.id}: ${event.suggestion.text.slice(0, 60)}…`, 'success');
      render();
    } else if (event.type === 'suggestion:updated' || event.type === 'suggestion:vote') {
      const index = state.suggestions.findIndex((s) => s.id === event.suggestion.id);
      if (index >= 0) state.suggestions[index] = event.suggestion;
      else state.suggestions.push(event.suggestion);
      renderStats();
      renderList();
      renderRuns();
    } else if (event.type === 'run:started') {
      state.activeRun = event.run;
      state.runEvents = [];
      state.activeRunAlive = true;
      state.lastActivityAt = event.run.startedAt ?? Date.now();
      renderRuns();
      // Refresh so the started run leaves the queue list.
      void refreshAll();
    } else if (event.type === 'run:log') {
      if (state.activeRun && event.runId === state.activeRun.id) {
        state.runEvents.push(event.event);
        // Any streamed event is proof that the runner just did something.
        markActivity();
        if (state.runEvents.length > 1500) state.runEvents.splice(0, state.runEvents.length - 1500);
        const consoleEl = document.getElementById('active-console');
        if (consoleEl) {
          const line = document.createElement('div');
          line.className = `line ${event.event.kind}`;
          line.textContent = event.event.text;
          consoleEl.appendChild(line);
          consoleEl.scrollTop = consoleEl.scrollHeight;
        } else {
          renderRuns();
        }
        updateRunActivity();
      }
    } else if (event.type === 'run:finished') {
      toast(`Run für #${event.run.suggestionId}: ${event.run.status}`, event.run.status === 'succeeded' ? 'success' : 'error');
      state.activeRun = null;
      state.runEvents = [];
      state.lastActivityAt = null;
      state.activeRunAlive = null;
      void refreshAll();
    } else if (event.type === 'queue:state') {
      state.queue = event.state;
      renderQueueState();
      renderRuns();
    }
  };
}

function setupUi(): void {
  $('#tabs').addEventListener('click', (event) => {
    const button = (event.target as HTMLElement).closest('button[data-tab]') as HTMLButtonElement | null;
    if (!button) return;
    state.tab = button.dataset.tab as Tab;
    document.querySelectorAll('#tabs button').forEach((b) => b.classList.toggle('active', b === button));
    renderList();
  });
  $('#categories').addEventListener('click', (event) => {
    const button = (event.target as HTMLElement).closest('button[data-category]') as HTMLButtonElement | null;
    if (!button) return;
    state.category = button.dataset.category === 'all' ? null : (button.dataset.category ?? null);
    renderCategories();
    renderList();
  });
  $('#search').addEventListener('input', (event) => {
    state.search = (event.target as HTMLInputElement).value.trim();
    renderList();
  });
  $('#list').addEventListener('click', (event) => {
    const button = (event.target as HTMLElement).closest('button[data-action]') as HTMLButtonElement | null;
    if (!button) return;
    const id = Number(button.dataset.id);
    void act(button.dataset.action ?? '', id);
  });
  $('#active-run').addEventListener('click', (event) => {
    const target = event.target as HTMLElement;
    if (target.closest('button[data-action="reconcile-runs"]')) {
      void reconcileRuns();
      return;
    }
    const button = target.closest('button[data-action="cancel-run"]') as HTMLButtonElement | null;
    if (!button) return;
    void act('cancel-run', 0, button.dataset.run);
  });
  $('#run-history').addEventListener('click', (event) => {
    const button = (event.target as HTMLElement).closest('button[data-action="retry-run"]') as HTMLButtonElement | null;
    if (!button?.dataset.run) return;
    void retryRun(button.dataset.run);
  });
  $('#toggle-pause').addEventListener('click', () => void togglePause());
  $('#cleanup-runs').addEventListener('click', () => void reconcileRuns());
  $('#refresh-runs').addEventListener('click', () => void refreshAll());
  $('#reload-content').addEventListener('click', async () => {
    try {
      await api('/api/content/reload', { method: 'POST' });
      toast('Content neu geladen — das Spiel übernimmt ihn beim nächsten Start.', 'success');
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  });
  const dialog = $('#settings-dialog') as HTMLDialogElement;
  $('#open-settings').addEventListener('click', async () => {
    await loadSettings();
    dialog.showModal();
  });
  $('#close-settings').addEventListener('click', () => dialog.close());
  $('#save-settings').addEventListener('click', async () => {
    const body: Record<string, unknown> = {
      model: ($('#setting-model') as HTMLInputElement).value.trim(),
      extraInstructions: ($('#setting-instructions') as HTMLTextAreaElement).value,
      autoApprove: ($('#setting-autoapprove') as HTMLInputElement).checked,
      autoApproveScore: Number(($('#setting-autoscore') as HTMLInputElement).value) || 0,
      runTimeoutMinutes: Number(($('#setting-timeout') as HTMLInputElement).value) || 0,
      retryLimit: Number(($('#setting-retries') as HTMLInputElement).value) || 0,
      retryBackoffSeconds: Number(($('#setting-backoff') as HTMLInputElement).value) || 0,
    };
    const webhook = ($('#setting-webhook') as HTMLInputElement).value.trim();
    if (webhook) body.discordWebhook = webhook;
    try {
      await api('/api/settings', { method: 'PUT', body: JSON.stringify(body) });
      toast('Einstellungen gespeichert', 'success');
      await loadSettings();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  });
  $('#test-webhook').addEventListener('click', async () => {
    const webhook = ($('#setting-webhook') as HTMLInputElement).value.trim();
    try {
      await api('/api/discord/test', { method: 'POST', body: JSON.stringify(webhook ? { webhook } : {}) });
      toast('Testnachricht gesendet — prüfe deinen Discord-Kanal.', 'success');
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  });
  const splitDialog = $('#split-dialog') as HTMLDialogElement;
  $('#split-tasks').addEventListener('input', updateSplitCount);
  $('#split-auto').addEventListener('click', () => {
    if (state.splitFor != null) void openSplitDialog(state.splitFor);
  });
  $('#split-cancel').addEventListener('click', () => splitDialog.close());
  $('#split-create').addEventListener('click', async () => {
    if (state.splitFor == null) return;
    const tasks = splitTasksFromArea();
    if (tasks.length < 2) {
      toast('Bitte mindestens zwei Einzelaufträge angeben.', 'error');
      return;
    }
    try {
      const result = await api<{ created: SuggestionView[] }>(`/api/suggestions/${state.splitFor}/split`, {
        method: 'POST',
        body: JSON.stringify({ tasks }),
      });
      toast(`${result.created.length} Einzelaufträge angelegt`, 'success');
      splitDialog.close();
      state.splitFor = null;
      await refreshAll();
    } catch (err) {
      toast((err as Error).message, 'error');
    }
  });
  window.addEventListener('hashchange', () => {
    const hash = location.hash.match(/^#suggestion-(\d+)$/);
    if (hash) {
      state.expanded.add(Number(hash[1]));
      renderList();
    }
  });
}

function applyDefaultTab(): void {
  if (visibleSuggestions().length > 0) return;
  const candidates: Tab[] = ['queue', 'new', 'done', 'cluster', 'top'];
  for (const tab of candidates) {
    state.tab = tab;
    if (visibleSuggestions().length > 0) break;
  }
  document.querySelectorAll('#tabs button').forEach((button) => {
    button.classList.toggle('active', (button as HTMLElement).dataset.tab === state.tab);
  });
}

async function main(): Promise<void> {
  setupUi();
  await refreshAll();
  applyDefaultTab();
  connectEvents();
  setInterval(() => {
    if (!state.connected) void refreshAll();
  }, 8000);
  // Keep the "last output" indicator ticking while a run is active.
  setInterval(() => {
    if (state.activeRun?.status === 'running') updateRunActivity();
    updateQueueCountdown();
  }, ACTIVITY_TICK_MS);
  // Re-check quiet/interrupted runs against the API so a stuck run is detected
  // even when the stream stalls silently.
  setInterval(() => void syncActiveRun(), ACTIVITY_TICK_MS * 10);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') void syncActiveRun();
  });
  const hash = location.hash.match(/^#suggestion-(\d+)$/);
  if (hash) state.expanded.add(Number(hash[1]));
  render();
}

void main();
