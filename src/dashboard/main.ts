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
import { OPERATOR_SOURCE } from '../shared/types';
import {
  attemptLabel,
  describeQueue,
  formatCountdown,
  describeLaneRisks,
  groupScopes,
  laneRisks,
  manifestHeadline,
  outcomeBadge,
  scopeLabel,
  type QueueSummary,
} from './queueControls';
import { describeRunActivity, formatDuration, lastEventTimestamp, needsRunCleanup } from './runActivity';

type Tab = 'queue' | 'new' | 'top' | 'cluster' | 'done';

interface DashboardState {
  suggestions: SuggestionView[];
  runs: RunRecord[];
  /** Runs currently holding a lane, oldest first — one card each. */
  activeRuns: RunRecord[];
  /** Live output per run id, so parallel sessions do not overwrite each other. */
  runEvents: Map<string, RunEvent[]>;
  /** Wall-clock time of the last received/synced event, per run id. */
  lastActivityAt: Map<string, number>;
  /** Whether the server still tracks a live process, per run id. */
  alive: Map<string, boolean>;
  /**
   * Suggestions the owner closed in the "done" tab. Client-side only: nothing is
   * deleted and nothing is sent to the server, because "Schließen" means "out of
   * my sight", not "erase this from the record". They come back on reload, which
   * is the honest behaviour for a view filter.
   */
  dismissed: Set<number>;
  /** Pause state, policy and pending runs as the server reports them. */
  queue: QueueState | null;
  /** Scope layout the runner depends on (from scripts/scopes.mjs). */
  manifest: ScopeManifest | null;
  /** Which files a run touched relative to its declared scope, per run id. */
  audits: Map<string, ScopeAudit>;
  tab: Tab;
  category: string | null;
  search: string;
  expanded: Set<number>;
  connected: boolean;
  /** Suggestion id currently being split in the dialog, or null. */
  splitFor: number | null;
  /** State of the repo-committed backup file. */
  backup: BackupState | null;
  /** True while an operator order is being sent, so the button cannot double-fire. */
  taskSending: boolean;
  /**
   * Last failure of a *background* load, `null` while everything works. It is
   * shown once in the top bar and never as a toast: the page refreshes itself
   * every few seconds, and a toast per attempt is a wall of identical text that
   * says nothing the status line does not.
   */
  loadError: string | null;
}

/** What the dashboard knows about `backup/dashboard.json` in the repository. */
interface BackupState {
  /** Repo-relative path of the file. */
  path: string;
  exists: boolean;
  writtenAt: number | null;
  /** Machine that wrote it — the first question when two histories disagree. */
  machine: string | null;
  suggestionCount: number;
  runCount: number;
  voteCount: number;
  /** Suggestions in the file that this database does not know yet. */
  missingHere: number;
  /** Suggestions here that the file has never seen. */
  missingThere: number;
  /** Suggestions that exist in both but differ — two machines, one history. */
  differing: number;
  older: number;
  newer: number;
  /** Runs the file has that this database has not. */
  runsMissingHere: number;
  /** German one-liner from the server, so both sides word it the same way. */
  headline: string;
  /** Set when the file exists but cannot be read (broken JSON, newer version). */
  error: string | null;
}

const state: DashboardState = {
  suggestions: [],
  runs: [],
  activeRuns: [],
  runEvents: new Map(),
  lastActivityAt: new Map(),
  alive: new Map(),
  queue: null,
  manifest: null,
  audits: new Map(),
  tab: 'queue',
  category: null,
  search: '',
  expanded: new Set(),
  dismissed: new Set(),
  connected: false,
  splitFor: null,
  backup: null,
  taskSending: false,
  loadError: null,
};

/** Newest live event per run id; an empty array means "nothing seen yet". */
function eventsOf(runId: string): RunEvent[] {
  return state.runEvents.get(runId) ?? [];
}

function lastActivityOf(runId: string): number | null {
  return state.lastActivityAt.get(runId) ?? null;
}

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

/**
 * Records the newest activity of one run, ignoring out-of-order times. Per run
 * id, because several sessions write to the stream at the same time and a single
 * shared clock would report lane 2 as silent while lane 1 talks.
 */
function markActivity(runId: string, timestamp?: number): void {
  const now = Date.now();
  const t = Math.min(timestamp ?? now, now);
  const seen = state.lastActivityAt.get(runId) ?? null;
  state.lastActivityAt.set(runId, seen === null ? t : Math.max(seen, t));
}

async function api<T>(path: string, init?: RequestInit): Promise<T> {
  // Only advertise a JSON body when there actually is one. Otherwise Fastify
  // rejects empty POST/PATCH requests with
  // "Body cannot be empty when content-type is set to 'application/json'".
  const headers = new Headers(init?.headers);
  if (init?.body != null && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json');
  }
  let res: Response;
  try {
    res = await fetch(path, { ...init, headers });
  } catch {
    // `fetch` wirft bei jedem Netzfehler ein englisches "Failed to fetch". Das
    // stand unten im Fenster, im Acht-Sekunden-Takt, solange der Server weg
    // war: eine Meldung, die dem Betreiber nichts sagte, was „getrennt“ nicht
    // schon sagt. Eine fehlgeschlagene *Aktion* meldet ihren Fehler weiterhin
    // per Toast — nur der Hintergrund-Ladevorgang ist jetzt still.
    throw new Error('Server nicht erreichbar');
  }
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
      // Only here: a closed entry must not vanish from the open tabs.
      list = list.filter((s) => !state.dismissed.has(s.id));
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

/**
 * A settled suggestion: implemented, failed or rejected.
 *
 * The "done" tab exists to look back, and a card that offers to implement a
 * finished task is a contradiction the owner has to think about. Everything
 * about the *implementation* is removed there — the "Umsetzung:" summary, the
 * run status, the commit, the scope — because the changelog and the commit
 * already hold that, and the row only needs to say what the idea was and what
 * became of it. What stays is the number, the status, the author, the age and
 * the text.
 *
 * The three labels are the German words the owner asked to have removed:
 * "Umsetzung" and its siblings.
 */
function isSettled(s: SuggestionView): boolean {
  return s.status === 'implemented' || s.status === 'failed' || s.status === 'rejected';
}

function renderCard(s: SuggestionView, children: number[]): string {
  const expanded = state.expanded.has(s.id);
  const isClusterCanonical = s.canonicalId === null || s.canonicalId === s.id;
  const hasChildren = children.length > 0;
  const run = s.run;
  // Only for the "done" tab, not for a task that merely failed: there the run
  // is current information.
  const settled = state.tab === 'done' && isSettled(s);
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
        ${
          s.source === OPERATOR_SOURCE
            ? '<span class="badge operator" title="Direkt im Dashboard als Auftrag getippt, nicht von einem Spieler">📌 Betreiberauftrag</span>'
            : ''
        }
        ${hasChildren ? `<span class="badge split-parent" title="In Einzelaufträge aufgeteilt">✂ ${children.length}</span>` : ''}
        <span>#${s.id}</span>
        <span>${escapeHtml(s.author)}</span>
        <span>${timeAgo(s.createdAt)}</span>
        <span class="score" title="Prioritäts-Score (ohne KI berechnet)">Score ${s.score}</span>
      </div>
      <p class="card-text">${escapeHtml(s.text)}</p>
      ${run?.resultSummary && !settled ? `<p class="card-summary"><span class="summary-label">🤖 Umsetzung:</span> ${escapeHtml(run.resultSummary)}</p>` : ''}
      <div class="card-meta">
        <span>👍 ${s.votes} Stimmen</span>
        ${s.discordMessageId ? '<span title="an Discord gesendet">📨 Discord</span>' : ''}
        ${run && run.status !== 'running' && !settled ? `<span>🤖 ${run.status}${commit}</span>` : ''}
        ${run?.scope && !settled ? `<span title="Scope aus scripts/scopes.mjs">📁 ${escapeHtml(scopeLabel(run, state.manifest))}</span>` : ''}
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
          // Never on a settled card: a task that is already done cannot be
          // implemented, and offering it only invites the question.
          !settled && s.status !== 'implementing' && !hasChildren
            ? `<button class="implement" data-action="implement" data-id="${s.id}">🤖 In OpenCode umsetzen</button>`
            : ''
        }
        ${
          !settled && s.status !== 'implemented' && s.status !== 'implementing' && !hasChildren
            ? `<button data-action="split" data-id="${s.id}">✂ Aufteilen</button>`
            : ''
        }
        <button data-action="details" data-id="${s.id}">${expanded ? '▴ Details' : '▾ Details'}</button>
        ${
          // Two verbs for two different intentions. On open work the entry is a
          // test run, a duplicate or a typo and should be gone. On a settled
          // suggestion there is nothing to clean up: the owner wants it out of
          // sight, not out of existence, and "Löschen" there reads as "erase this
          // from the record".
          settled
            ? `<button class="danger" data-action="dismiss" data-id="${s.id}">✕ Schließen</button>`
            : s.status === 'implementing' || s.run?.status === 'running'
              ? ''
              : `<button class="danger" data-action="delete" data-id="${s.id}">Löschen</button>`
        }
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

/** One lane, drawn as a chip. Busy lanes name the run they carry. */
function renderLanes(summary: QueueSummary): string {
  if (summary.totalLanes <= 1) return '';
  const chips: string[] = [];
  for (let lane = 1; lane <= summary.totalLanes; lane += 1) {
    const run = state.activeRuns.find((r) => r.lane === lane);
    const busy = Boolean(run);
    const title = run
      ? `Spur ${lane}: #${run.suggestionId} · ${scopeLabel(run, state.manifest)}`
      : `Spur ${lane} ist frei`;
    chips.push(
      `<span class="chip lane ${busy ? 'busy' : 'free'}" title="${escapeHtml(title)}">` +
        `${busy ? '⚙' : '○'} Spur ${lane}${run ? ` · #${run.suggestionId}` : ''}</span>`,
    );
  }
  // The one collision parallel lanes deliberately allow, said out loud.
  const risk = describeLaneRisks(laneRisks(state.activeRuns));
  const note = risk ? `<div class="lane-risk">${escapeHtml(risk)}</div>` : '';
  return `<div class="lane-strip" title="Jede Spur ist ein eigener OpenCode-Sitzungsplatz">${chips.join('')}</div>${note}`;
}

/** The live card of one lane: header, budget, scope, activity, console, actions. */
function renderRunCard(run: RunRecord): string {
  const alive = state.alive.get(run.id);
  const activity = describeRunActivity({
    lastActivityAt: lastActivityOf(run.id),
    startedAt: run.startedAt,
    connected: state.connected,
    alive: alive ?? undefined,
  });
  const operator = suggestionAuthor(run.suggestionId) === 'Betreiber' ? ' · Auftrag' : '';
  return `
    <div class="run-card activity-${activity.level}" data-run-card="${run.id}">
      <div class="run-title">
        <span>🤖 #${run.suggestionId}${operator} <span class="lane-tag" title="Diese Spur in der Warteschlange">Spur ${run.lane ?? '?'}</span></span>
        <span>${alive === false ? '⚠ Prozess weg' : '⚙ läuft'}</span>
      </div>
      <div class="run-sub run-task" title="${escapeHtml(suggestionText(run.suggestionId))}">${escapeHtml(suggestionText(run.suggestionId))}</div>
      <div class="run-sub" data-run-budget="${run.id}">${escapeHtml(runBudgetLine(run))}</div>
      <div class="run-activity ${activity.level}" data-run-activity="${run.id}" title="Zeit seit der letzten Ausgabe von OpenCode">
        ${escapeHtml(activity.label)}
      </div>
      <div class="card-actions">
        <button data-action="cancel-run" data-run="${run.id}">⏹ Abbrechen</button>
        ${
          activity.level === 'stale' || activity.level === 'offline' || alive === false
            ? '<button data-action="reconcile-runs">🧹 Als beendet markieren</button>'
            : ''
        }
      </div>
    </div>
  `;
}

/** Author of a suggestion, for the badge that marks an operator order. */
function suggestionAuthor(id: number): string {
  return state.suggestions.find((s) => s.id === id)?.author ?? '';
}

/** The suggestion's own words, in one line — what a run is going to work on. */
function suggestionText(id: number): string {
  const text = state.suggestions.find((s) => s.id === id)?.text ?? '';
  if (!text.trim()) return '(Vorschlag nicht geladen)';
  // Newlines become spaces: a suggestion pasted from several lines would
  // otherwise break the row into a paragraph.
  const flat = text.replace(/\s+/g, ' ').trim();
  return flat.length > 140 ? `${flat.slice(0, 139)}…` : flat;
}

function renderRuns(): void {
  const active = $('#active-run');
  const running = state.activeRuns.filter((r) => r.status === 'running');
  const queued = state.runs.filter((r) => r.status === 'queued').slice(0, 20);
  const blocked = new Set(state.queue?.blockedRunIds ?? []);

  renderQueueState();

  let html = '';
  // A server restart can leave runs marked as "running" that no lane can hold —
  // more than the configured number of sessions. Surface that clearly and offer a
  // one-click cleanup instead of silently showing the newest ones.
  const capacity = Math.max(1, state.queue?.policy.maxParallelRuns ?? 1);
  if (running.length > capacity) {
    html += `
      <div class="run-warning">
        <span>⚠ ${running.length} Runs sind gleichzeitig als „läuft“ markiert, aber es sind nur ${capacity} Spuren eingestellt — vermutlich ein Neustart mitten im Lauf.</span>
        <button data-action="reconcile-runs">🧹 Jetzt aufräumen</button>
      </div>`;
  }
  if (running.length > 0) {
    html += running.map(renderRunCard).join('');
  } else {
    html += '<p class="run-sub">Kein aktiver Run. Klicke bei einem Vorschlag auf „In OpenCode umsetzen“ oder tippe unten einen Auftrag ein.</p>';
  }

  if (queued.length > 0) {
    html += `
      <div class="run-title" style="margin-top:14px">
        <span>⏳ Warteschlange</span>
        <span>${queued.length}${blocked.size > 0 ? ` · ${blocked.size} warten auf eine Spur` : ''}</span>
      </div>
    `;
    html += queued
      .map((run) => {
        const badge = attemptLabel(run);
        const wait =
          run.notBefore && run.notBefore > Date.now() ? ` · startet in ${formatCountdown(run.notBefore - Date.now())}` : '';
        const waitReason = blocked.has(run.id) ? 'wartet auf eine belegte Spur (gleicher Scope)' : 'wartet';
        // What is actually queued. The run id, the cost and the scope line said
        // how the runner works, not what it is about to do, and the owner
        // recognises a task by its text.
        const text = suggestionText(run.suggestionId);
        return `
      <div class="run-card${blocked.has(run.id) ? ' blocked' : ''}">
        <div class="run-title">
          <span>#${run.suggestionId}${badge ? ` · ${escapeHtml(badge)}` : ''}</span>
          <span>${waitReason}</span>
        </div>
        <div class="run-sub queued-task" title="${escapeHtml(text)}">${escapeHtml(text)}${escapeHtml(wait)}</div>
        <div class="card-actions">
          <button data-action="cancel-run" data-run="${run.id}">⏹ Entfernen</button>
        </div>
      </div>`;
      })
      .join('');
  }

  active.innerHTML = html;
  updateRunActivity();

  $('#run-history').innerHTML = renderRunHistory();
  renderScopes();
}

/** Pause chip, lane occupancy and the policy that is currently in force. */
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
      : 'Warteschlange anhalten — laufende Runs laufen weiter';
  }
  const summary = describeQueue(state.queue, Date.now());
  container.innerHTML = `
    <span class="chip ${summary.paused ? 'paused' : 'active'}">${escapeHtml(summary.label)}</span>
    <span class="chip lanes" title="So viele OpenCode-Sitzungen dürfen gleichzeitig laufen">${escapeHtml(summary.lanes)}</span>
    <span class="policy" id="queue-policy">${escapeHtml(summary.policyLabel)}</span>
    <span class="policy" id="queue-waiting">${summary.waiting} wartend${summary.startsIn ? ` · ${escapeHtml(summary.startsIn)}` : ''}</span>
    ${renderLanes(summary)}
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
  el.textContent = `${summary.waiting} wartend${summary.blocked > 0 ? ` · ${summary.blocked} auf Spur` : ''}${
    summary.startsIn ? ` · ${summary.startsIn}` : ''
  }`;
}

/** Finished runs: why they ended, which attempt, and which scope they touched. */
function renderRunHistory(): string {
  const history = state.runs
    .filter((r) => r.status !== 'running' && r.status !== 'queued')
    .slice(0, 8)
    .map((run) => {
      const badge = outcomeBadge(run);
      const attempt = attemptLabel(run);
      // Same reasoning as the queue: the text is what identifies the task. The
      // commit stays reachable through the changelog, and the scope and cost
      // lines are runner internals.
      const text = suggestionText(run.suggestionId);
      return `
      <div class="run-card">
        <div class="run-title">
          <span>#${run.suggestionId}${attempt ? ` · ${escapeHtml(attempt)}` : ''}</span>
          <span>${badge ? `${badge.icon} ${escapeHtml(badge.label)}` : escapeHtml(run.status)}</span>
        </div>
        <div class="run-sub run-task" title="${escapeHtml(text)}">${escapeHtml(text)}</div>
        <div class="run-sub">${run.finishedAt ? timeAgo(run.finishedAt) : ''}${
          run.retryOf ? ' · ↻ wiederholt' : ''
        }</div>
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

/** The scope layout, grouped by owning agent, with the busy scopes highlighted. */
function renderScopes(): void {
  const list = $('#scope-list');
  if (!list) return;
  $('#scope-headline').textContent = manifestHeadline(state.manifest);
  if (!state.manifest || state.manifest.scopes.length === 0) {
    list.innerHTML = '<p class="run-sub">Keine Scopes geladen.</p>';
    return;
  }
  // Every lane at once: with three sessions running, three scopes are in use and
  // the panel has to say which.
  const busy = new Map<string, number>();
  for (const run of state.activeRuns) {
    for (const id of run.scopes) busy.set(id, run.lane ?? 0);
  }
  list.innerHTML = groupScopes(state.manifest.scopes)
    .map(
      (group) => `
      <div class="scope-group">
        <div class="scope-agent">${escapeHtml(group.agent)} · ${group.scopes.length}</div>
        ${group.scopes
          .map(
            (scope) => `
          <div class="scope-row ${busy.has(scope.id) ? 'current' : ''}">
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

/** Runtime and the remaining hard-timeout budget. The run id is not shown. */
function runBudgetLine(run: RunRecord): string {
  const elapsed = run.startedAt ? `läuft seit ${formatDuration(Date.now() - run.startedAt)}` : 'startet gerade';
  if (run.timeoutMs <= 0 || !run.startedAt) return `${elapsed} · ohne Zeitlimit`;
  const left = Math.max(0, run.startedAt + run.timeoutMs - Date.now());
  return `${elapsed} · Restzeit ${formatCountdown(left)} von ${formatCountdown(run.timeoutMs)}`;
}

/** Refreshes every lane's "last output" indicator without rebuilding the panel. */
function updateRunActivity(): void {
  for (const run of state.activeRuns) {
    const el = document.querySelector(`[data-run-activity="${run.id}"]`);
    const budget = document.querySelector(`[data-run-budget="${run.id}"]`);
    if (budget) budget.textContent = runBudgetLine(run);
    if (!el) continue;
    const activity = describeRunActivity({
      lastActivityAt: lastActivityOf(run.id),
      startedAt: run.startedAt,
      connected: state.connected,
      alive: state.alive.get(run.id) ?? undefined,
    });
    el.className = `run-activity ${activity.level}`;
    el.textContent = activity.label;
    const card = document.querySelector(`[data-run-card="${run.id}"]`);
    if (card) card.className = `run-card activity-${activity.level}`;
  }
}

/**
 * Re-fetches every running run from the API. This recovers events missed while
 * the SSE stream was interrupted and provides an accurate "last output"
 * timestamp when a lane has been quiet for a while. Each run is polled on its
 * own schedule: a chatty lane must not keep a silent one from being checked.
 */
async function syncActiveRuns(): Promise<void> {
  const running = state.activeRuns.filter((r) => r.status === 'running');
  if (running.length === 0) return;
  const due = running.filter((run) => {
    const base = lastActivityOf(run.id) ?? run.startedAt;
    const silentMs = base == null ? 0 : Date.now() - base;
    // While the stream is delivering we do not need to poll.
    return !(state.connected && silentMs < ACTIVITY_RESYNC_MS);
  });
  for (const run of due) {
    try {
      const view = await api<RunView>(`/api/runs/${run.id}`);
      if (view.status !== 'running') {
        // The finish event was missed: refresh so the run leaves the active panel.
        await refreshAll();
        return;
      }
      state.runEvents.set(view.id, view.events);
      state.alive.set(view.id, view.alive);
      if (view.scopeAudit) state.audits.set(view.id, view.scopeAudit);
      markActivity(view.id, lastEventTimestamp(view.events) ?? view.startedAt ?? undefined);
      renderRuns();
    } catch {
      /* run view is best-effort */
    }
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
  // Every run that holds a lane gets a card; the newest queued one does not, it
  // belongs in the waiting list below.
  const running = data.runs
    .filter((r) => r.status === 'running')
    .sort((a, b) => (a.startedAt ?? a.createdAt) - (b.startedAt ?? b.createdAt));
  const before = new Set(state.activeRuns.map((r) => r.id));
  state.activeRuns = running;
  // Forget a lane that ended while the page was closed, so its console does not
  // stay in memory and reappear on the next start event.
  for (const id of before) {
    if (running.some((r) => r.id === id)) continue;
    state.runEvents.delete(id);
    state.lastActivityAt.delete(id);
    state.alive.delete(id);
    state.audits.delete(id);
  }
  // Populate/refresh the consoles from the server, so runs that are already going
  // show their progress (and last-output time) even when SSE events were missed.
  await Promise.all(
    running.map(async (run) => {
      try {
        const view = await api<RunView>(`/api/runs/${run.id}`);
        state.runEvents.set(view.id, view.events);
        state.alive.set(view.id, view.alive);
        if (view.scopeAudit) state.audits.set(view.id, view.scopeAudit);
        markActivity(view.id, lastEventTimestamp(view.events) ?? view.startedAt ?? undefined);
      } catch {
        /* run view is best-effort */
      }
    }),
  );
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

/** Status line of the repository backup, with the button states that follow. */
async function loadBackup(): Promise<void> {
  try {
    state.backup = await api<BackupState>('/api/backup');
  } catch {
    state.backup = null;
  }
  renderBackup();
}

function renderBackup(): void {
  const headline = $('#backup-headline');
  if (!headline) return;
  const backup = state.backup;
  if (!backup) {
    headline.textContent = 'Backup-Status nicht erreichbar.';
    return;
  }
  headline.textContent = backup.headline;
  const read = $('#backup-read') as HTMLButtonElement | null;
  if (read) {
    // Nothing to load and nothing to reconcile: say so instead of offering a
    // button that would change nothing.
    const nothingToDo = !backup.error && backup.missingHere === 0 && backup.differing === 0;
    read.disabled = nothingToDo;
    read.title = nothingToDo
      ? 'Datei und Datenbank sind identisch — nichts nachzuladen.'
      : 'Alle Vorschläge, Stimmen und Runs aus der Datei übernehmen (neuere lokale Daten bleiben)';
  }
  const write = $('#backup-write') as HTMLButtonElement | null;
  if (write) write.title = `Momentaufnahme nach ${backup.path} schreiben — die Datei gehört mit ins Git.`;
}

/** Writes the snapshot into the repository. */
async function writeBackup(): Promise<void> {
  const button = $('#backup-write') as HTMLButtonElement;
  button.disabled = true;
  try {
    const result = await api<{ path: string; counts: { suggestions: number; runs: number; votes: number } }>(
      '/api/backup/write',
      { method: 'POST', body: JSON.stringify({}) },
    );
    const c = result.counts;
    toast(`Backup geschrieben: ${result.path} · ${c.suggestions} Vorschläge, ${c.runs} Runs — jetzt committen.`, 'success');
    await loadBackup();
  } catch (err) {
    toast((err as Error).message, 'error');
  } finally {
    button.disabled = false;
  }
}

/** Merges the repository file into the database. */
async function readBackup(): Promise<void> {
  const button = $('#backup-read') as HTMLButtonElement;
  button.disabled = true;
  try {
    const result = await api<{
      report: {
        suggestionsAdded: number;
        suggestionsUpdated: number;
        votesAdded: number;
        runsAdded: number;
        runsCompleted: number;
      };
    }>('/api/backup/read', { method: 'POST', body: JSON.stringify({}) });
    const r = result.report;
    toast(
      `Backup gelesen: ${r.suggestionsAdded} Vorschläge neu, ${r.suggestionsUpdated} aktualisiert, ` +
        `${r.votesAdded} Stimmen, ${r.runsAdded} Runs neu, ${r.runsCompleted} Runs mit Ergebnis nachgetragen.`,
      'success',
    );
    await refreshAll();
  } catch (err) {
    toast((err as Error).message, 'error');
  } finally {
    button.disabled = false;
  }
}
/** Pauses or resumes the queue. The running runs keep their process either way. */
async function togglePause(): Promise<void> {
  if (!state.queue) return;
  const paused = !state.queue.paused;
  try {
    const next = await api<QueueState>('/api/runner/pause', {
      method: 'POST',
      body: JSON.stringify({ paused }),
    });
    state.queue = next;
    toast(
      paused
        ? 'Warteschlange pausiert — die laufenden Runs laufen weiter.'
        : 'Warteschlange läuft weiter.',
      'success',
    );
    await refreshAll();
  } catch (err) {
    toast((err as Error).message, 'error');
  }
}

/**
 * Sends a free-form order to the runner. No suggestion, no vote, no approval:
 * the operator's own text is the order, and it goes into the same queue as
 * everything else.
 */
async function submitTask(text: string): Promise<void> {
  const area = $('#task-text') as HTMLTextAreaElement;
  const button = $('#task-send') as HTMLButtonElement;
  if (state.taskSending) return;
  state.taskSending = true;
  button.disabled = true;
  button.textContent = 'wird gesendet …';
  try {
    const result = await api<{ run: RunRecord; suggestion: SuggestionView }>('/api/tasks', {
      method: 'POST',
      body: JSON.stringify({ text }),
    });
    const label = scopeLabel(result.run, state.manifest);
    toast(`Auftrag #${result.suggestion.id} in der Warteschlange · ${label}`, 'success');
    area.value = '';
    await refreshAll();
  } catch (err) {
    toast((err as Error).message, 'error');
  } finally {
    state.taskSending = false;
    button.disabled = false;
    button.textContent = '🚀 Auftrag starten';
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
    maxParallelRuns: number;
    webhookConfigured: boolean;
    envWebhook: boolean;
    telegramConfigured: boolean;
    telegramTokenSet: boolean;
    telegramChatSet: boolean;
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
  ($('#setting-lanes') as HTMLInputElement).value = String(settings.maxParallelRuns);
  // The Telegram state is deliberately **not** remembered: the token lives in
  // `.env`, which changes outside the dashboard. A remembered state would be a
  // lie after a restart.
  $('#telegram-state').textContent = settings.telegramConfigured
    ? 'eingerichtet — Vorschläge und Befehle laufen'
    : !settings.telegramTokenSet
      ? 'kein TELEGRAM_BOT_TOKEN in der .env'
      : 'keine TELEGRAM_CHAT_ID in der .env';
  $('#webhook-state').textContent = settings.webhookConfigured
    ? settings.envWebhook
      ? 'Webhook kommt aus .env'
      : `Gespeichert: ${settings.discordWebhook}`
    : 'Noch kein Webhook gesetzt — Vorschläge werden nicht an Discord gesendet.';
}

/**
 * Loads everything and re-renders. Deliberately quiet: this is what the page
 * calls on a timer, so a failure here is a *state*, not an event. The last good
 * data stays on screen — a dashboard that empties itself because a server is
 * restarting has thrown away the information the operator is looking for.
 */
async function refreshAll(): Promise<void> {
  try {
    await Promise.all([loadSuggestions(), loadRuns(), loadQueue(), loadManifest()]);
    setLoadError(null);
    render();
    void maybeAutoReconcile();
  } catch (err) {
    setLoadError((err as Error).message);
  }
}

/** Records the background-load state and paints it into the top bar. */
function setLoadError(message: string | null): void {
  if (state.loadError === message) return;
  state.loadError = message;
  renderApiState();
}

/**
 * The server's own state, next to the stream's. They are different things and
 * the old single chip blurred them: the live stream can be up while every
 * request fails, and then nothing at all said so.
 */
function renderApiState(): void {
  const el = $('#api-state');
  if (!el) return;
  const offline = state.loadError !== null;
  el.hidden = !offline;
  el.className = offline ? 'connection api-down' : 'connection';
  el.textContent = offline
    ? `${state.loadError} — lädt nach, sobald er wieder da ist`
    : '';
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
 * Self-healing: when the dashboard notices running rows that no lane can hold, or
 * a run whose process is gone, it cleans them up automatically instead of
 * leaving the user with a confusing list of "running" runs. Several running rows
 * are normal now — that is what the lanes are for — so only the impossible counts
 * and the process-less runs count as a reason.
 */
async function maybeAutoReconcile(): Promise<void> {
  const runningCount = state.runs.filter((r) => r.status === 'running').length;
  const deadRunIds = state.activeRuns.filter((r) => state.alive.get(r.id) === false).map((r) => r.id);
  const capacity = state.queue?.policy.maxParallelRuns ?? 1;
  if (!needsRunCleanup({ runningCount, capacity, deadRunIds })) return;
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
    } else if (action === 'dismiss') {
      // No request, no confirmation: nothing is destroyed. The card leaves the
      // "done" list and a reload brings it back.
      state.dismissed.add(id);
      state.expanded.delete(id);
      renderList();
      renderStats();
      return;
    } else if (action === 'delete') {
      // One confirmation, because this cannot be undone: the entry is gone, and
      // with it its runs and votes. A `confirm` carrying the number is enough; a
      // second dialog would only be a second place to click "cancel" and then
      // wonder why nothing happened.
      if (!confirm(`Vorschlag #${id} endgültig löschen?\n\nMit ihm verschwinden auch seine Läufe und Stimmen. Das lässt sich nicht rückgängig machen.`)) {
        return;
      }
      await api(`/api/suggestions/${id}`, { method: 'DELETE' });
      toast(`#${id} gelöscht`);
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
    renderApiState();
    const el = $('#connection');
    el.classList.add('online');
    el.classList.remove('offline');
    el.innerHTML = '<span class="dot"></span> live';
    updateRunActivity();
    if (hadConnection) void refreshAll();
    else void syncActiveRuns();
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
      // A new lane: add it next to the ones already running instead of replacing
      // whatever was on screen.
      state.activeRuns = [...state.activeRuns.filter((r) => r.id !== event.run.id), event.run];
      state.runEvents.set(event.run.id, []);
      state.alive.set(event.run.id, true);
      markActivity(event.run.id, event.run.startedAt ?? Date.now());
      renderRuns();
      // Refresh so the started run leaves the queue list and its lane is known.
      void refreshAll();
    } else if (event.type === 'run:log') {
      const events = state.runEvents.get(event.runId);
      // An event for a run this page has not seen as running (a run started
      // while the stream was down) is not dropped: buffer it and let the next
      // full sync replace it with the server's version.
      const buffer = events ?? [];
      buffer.push(event.event);
      // Any streamed event is proof that the runner just did something.
      markActivity(event.runId);
      if (buffer.length > 1500) buffer.splice(0, buffer.length - 1500);
      state.runEvents.set(event.runId, buffer);
      // The session runs in a terminal window now, so there is no log pane to
      // append to. The activity indicator is the only thing that updates in
      // place; everything else waits for the next full render.
      updateRunActivity();
    } else if (event.type === 'run:finished') {
      toast(`Run für #${event.run.suggestionId}: ${event.run.status}`, event.run.status === 'succeeded' ? 'success' : 'error');
      state.activeRuns = state.activeRuns.filter((r) => r.id !== event.run.id);
      state.runEvents.delete(event.run.id);
      state.lastActivityAt.delete(event.run.id);
      state.alive.delete(event.run.id);
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
  $('#backup-write').addEventListener('click', () => void writeBackup());
  $('#backup-read').addEventListener('click', () => void readBackup());
  // Opening the panel is the signal that the numbers may have moved (a commit on
  // another machine, a merge by hand), so that is when it re-reads them.
  $('#backup-panel').addEventListener('toggle', () => void loadBackup());
  $('#task-form').addEventListener('submit', (event) => {
    event.preventDefault();
    const area = $('#task-text') as HTMLTextAreaElement;
    const text = area.value.trim();
    if (text.length < 3) {
      toast('Der Auftrag braucht mindestens 3 Zeichen.', 'error');
      area.focus();
      return;
    }
    void submitTask(text);
  });
  // Ctrl/Cmd+Enter sends from the textarea, so a long order needs no mouse.
  $('#task-text').addEventListener('keydown', (event) => {
    const key = event as KeyboardEvent;
    if (key.key === 'Enter' && (key.ctrlKey || key.metaKey)) {
      key.preventDefault();
      ($('#task-form') as HTMLFormElement).requestSubmit();
    }
  });
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
      maxParallelRuns: Math.max(1, Number(($('#setting-lanes') as HTMLInputElement).value) || 1),
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
  $('#test-telegram').addEventListener('click', async () => {
    // The server's error text is passed through because it names the most
    // common causes: missing token, missing chat id, or a bot that has not
    // received a message yet.
    try {
      await api('/api/telegram/test', { method: 'POST', body: JSON.stringify({}) });
      toast('Testnachricht gesendet — prüfe deinen Telegram-Chat.', 'success');
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
  void loadBackup();
  connectEvents();
  setInterval(() => {
    // Keep retrying after a load error: the server may be back long before the
    // page gets around to its next attempt.
    if (!state.connected || state.loadError !== null) void refreshAll();
  }, 8000);
  // Keep the "last output" indicator ticking while a run is active.
  setInterval(() => {
    if (state.activeRuns.length > 0) updateRunActivity();
    updateQueueCountdown();
  }, ACTIVITY_TICK_MS);
  // Re-check quiet/interrupted runs against the API so a stuck run is detected
  // even when the stream stalls silently.
  setInterval(() => void syncActiveRuns(), ACTIVITY_TICK_MS * 10);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') void syncActiveRuns();
  });
  const hash = location.hash.match(/^#suggestion-(\d+)$/);
  if (hash) state.expanded.add(Number(hash[1]));
  render();
}

void main();
