import './style.css';
import type {
  BusEvent,
  QueueState,
  RunEvent,
  RunRecord,
  RunView,
  ScopeAudit,
  ScopeManifest,
  SuggestionCategory,
  SuggestionView,
} from '../shared/types';
import { OPERATOR_SOURCE } from '../shared/types';
import { sortSuggestions } from '../shared/sorting';
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
  scopeWarning,
  waitingLabel,
  type QueueSummary,
} from './queueControls';
import { describeRunActivity, formatDuration, lastEventTimestamp, needsRunCleanup } from './runActivity';
import {
  effortOptions,
  findChoice,
  groupModelChoices,
  joinModelSetting,
  splitModelSetting,
  type ModelChoice,
  type ModelList,
} from './models';

type Tab = 'queue' | 'new' | 'top' | 'cluster' | 'done';

interface DashboardState {
  suggestions: SuggestionView[];
  runs: RunRecord[];
  /** Runs currently holding a lane, oldest first — one card each. */
  activeRuns: RunRecord[];
  /** Live output per run id, so parallel sessions do not overwrite each other. */
  runEvents: Map<string, RunEvent[]>;
  /** Wall-clock time of the last received/synced output, per run id. */
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
  /** What `opencode` can run on this machine, from `/api/models`. */
  models: ModelChoice[];
  /** False when the effort levels are missing because the catalog was unreadable. */
  modelCatalog: boolean;
  /** One fetch per page: the list does not change while the panel is open. */
  modelsLoaded: boolean;
  /** Why the model list is empty, so the field can say it instead of "lädt". */
  modelListError: string | null;
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
  models: [],
  modelCatalog: false,
  modelsLoaded: false,
  modelListError: null,
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

/** Guards `reconcileRuns` itself, which three different controls can call. */
let reconciling = false;

/** What `api` reports when the request never reached the server. */
const OFFLINE = 'Server nicht erreichbar';

/** Monotonic ids of the newest `/api/suggestions` and `/api/runs` request. */
let suggestionsSeq = 0;
let runsSeq = 0;

/**
 * Category names, typed with the shared union so a new category is a compile
 * error here and not a card that silently shows its raw id. The wording is
 * duplicated from `server/discord.ts` on purpose: the server cannot import from
 * the dashboard bundle, so one of the two copies has to be hand-kept.
 */
const CATEGORY_LABELS: Record<SuggestionCategory, string> = {
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

/**
 * Escapes a value for an HTML text node or a double-quoted attribute.
 *
 * The apostrophe is escaped as well: it cannot break a `title="…"` today, but a
 * hand-rolled escaper that leaves one of the five metacharacters out is a trap
 * for whoever adds a single-quoted attribute next.
 */
function escapeHtml(value: string): string {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/**
 * Escapes a value that will end up inside an unquoted-ish `class="…"` token.
 * Category and status ids are closed unions today, so this is belt and braces —
 * but the fallback `?? s.category` in the card template is exactly the place
 * where a new id would arrive unescaped, and a class is not a text node.
 */
function escapeAttr(value: string): string {
  return escapeHtml(String(value).replace(/\s+/g, '_'));
}

/** `CATEGORY_LABELS[c] ?? c` for a text node, escaped on both branches. */
function categoryLabel(category: string): string {
  return escapeHtml(CATEGORY_LABELS[category as SuggestionCategory] ?? category);
}

/**
 * A run id as it can live in a `data-run-card="…"` attribute and still be found
 * again by `updateRunActivity`. Both sides must use this, or a tick silently
 * stops updating a row whose id contains a space.
 */
function runKey(runId: string): string {
  return runId.replace(/\s+/g, '_');
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
    throw new Error(OFFLINE);
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

/**
 * The split hierarchy of the loaded suggestions, in one pass.
 *
 * `parentIds()` and `childrenOf()` each scanned the whole list, and
 * `childrenOf` was called once per rendered card — quadratic in the number of
 * suggestions, on every 8 s tick and on every stream event. Both directions come
 * out of the same walk, and the result is memoised until the list actually
 * changes.
 */
interface SplitIndex {
  /** Ids of suggestions that were split into sub-tasks (container orders). */
  parents: Set<number>;
  /** Sub-task ids per parent id. */
  children: Map<number, number[]>;
}

let splitIndexCache: { source: SuggestionView[]; rev: number; index: SplitIndex } | null = null;

/** Bumped by every write to `state.suggestions`, which the stream mutates in place. */
let suggestionsRev = 0;

function splitIndex(): SplitIndex {
  const cached = splitIndexCache;
  if (cached && cached.source === state.suggestions && cached.rev === suggestionsRev) return cached.index;
  const parents = new Set<number>();
  const children = new Map<number, number[]>();
  for (const s of state.suggestions) {
    if (s.parentId == null) continue;
    parents.add(s.parentId);
    const list = children.get(s.parentId);
    if (list) list.push(s.id);
    else children.set(s.parentId, [s.id]);
  }
  const index: SplitIndex = { parents, children };
  splitIndexCache = { source: state.suggestions, rev: suggestionsRev, index };
  return index;
}

/** Replaces the loaded suggestions and invalidates the split index. */
function setSuggestions(list: SuggestionView[]): void {
  state.suggestions = list;
  suggestionsRev += 1;
}

/** Applies one stream update in place, then invalidates the split index. */
function patchSuggestion(id: number, view: SuggestionView): void {
  const index = state.suggestions.findIndex((s) => s.id === id);
  if (index >= 0) state.suggestions[index] = view;
  else state.suggestions.push(view);
  suggestionsRev += 1;
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
      const { parents } = splitIndex();
      list = list.filter((s) => (s.status === 'approved' || s.status === 'implementing') && !parents.has(s.id));
      return sortSuggestions(list, 'top');
    }
    case 'new':
      list = list.filter((s) => s.status === 'new');
      return sortSuggestions(list, 'new');
    case 'top':
      list = list.filter((s) => s.status !== 'rejected');
      return sortSuggestions(list, 'top');
    case 'cluster':
      return sortSuggestions(list, 'cluster');
    case 'done':
      // Only here: a closed entry must not vanish from the open tabs.
      list = list.filter((s) => !state.dismissed.has(s.id));
      list = list.filter((s) => s.status === 'implemented' || s.status === 'failed' || s.status === 'rejected');
      // The "done" tab is ordered by when the entry last moved, which the shared
      // sort modes do not know; `byId` keeps it from reshuffling between polls.
      return list.sort((a, b) => b.updatedAt - a.updatedAt || b.id - a.id);
    default:
      return list;
  }
}

function renderStats(): void {
  const stats = $('#stats');
  const total = state.suggestions.length;
  const { parents } = splitIndex();
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
  const cats: string[] = ['all', ...Object.keys(CATEGORY_LABELS)];
  container.innerHTML = cats
    .map(
      (cat) =>
        `<button class="chip ${(state.category ?? 'all') === cat ? 'active' : ''}" data-category="${escapeAttr(cat)}">${
          cat === 'all' ? 'Alle' : categoryLabel(cat)
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
  const childIds = hasChildren
    ? `Aufgeteilt in ${children.length} Einzelaufträge: ${children.map((id) => `#${id}`).join(', ')}`
    : '';
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
        <span class="badge cat-${escapeAttr(s.category)}">${categoryLabel(s.category)}</span>
        <span class="badge status-${escapeAttr(s.status)}">${escapeHtml(STATUS_LABELS[s.status] ?? s.status)}</span>
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
      </div>
      <p class="card-text">${escapeHtml(s.text)}</p>
      ${run?.resultSummary && !settled ? `<p class="card-summary"><span class="summary-label">🤖 Umsetzung:</span> ${escapeHtml(run.resultSummary)}</p>` : ''}
      <div class="card-meta">
        <span>👍 ${s.votes} Stimmen</span>
        ${s.discordMessageId ? '<span title="an Discord gesendet">📨 Discord</span>' : ''}
        ${run && run.status !== 'running' && !settled ? `<span>🤖 ${escapeHtml(run.status)}${commit}</span>` : ''}
        ${run?.scope && !settled ? `<span title="Scope aus scripts/scopes.mjs">📁 ${escapeHtml(scopeLabel(run, state.manifest))}</span>` : ''}
        ${!isClusterCanonical ? `<span>gehört zu Cluster #${s.canonicalId}</span>` : ''}
        ${childIds ? `<span>${childIds}</span>` : ''}
      </div>
      <div class="card-actions">
        <button class="vote" data-action="vote" data-id="${s.id}" data-focus-key="vote:${s.id}">👍 Stimme</button>
        ${
          s.status !== 'approved' && s.status !== 'implemented' && s.status !== 'implementing'
            ? `<button class="approve" data-action="approve" data-id="${s.id}" data-focus-key="approve:${s.id}">✓ Genehmigen</button>`
            : ''
        }
        ${
          s.status !== 'rejected' && s.status !== 'implemented'
            ? `<button class="reject" data-action="reject" data-id="${s.id}" data-focus-key="reject:${s.id}">✕ Ablehnen</button>`
            : ''
        }
        ${
          // Never on a settled card: a task that is already done cannot be
          // implemented, and offering it only invites the question.
          !settled && s.status !== 'implementing' && !hasChildren
            ? `<button class="implement" data-action="implement" data-id="${s.id}" data-focus-key="implement:${s.id}">🤖 In OpenCode umsetzen</button>`
            : ''
        }
        ${
          !settled && s.status !== 'implemented' && s.status !== 'implementing' && !hasChildren
            ? `<button data-action="split" data-id="${s.id}" data-focus-key="split:${s.id}">✂ Aufteilen</button>`
            : ''
        }
        <button data-action="details" data-id="${s.id}" data-focus-key="details:${s.id}" aria-expanded="${expanded}">${
          expanded ? '▴ Details' : '▾ Details'
        }</button>
        ${
          // Two verbs for two different intentions. On open work the entry is a
          // test run, a duplicate or a typo and should be gone. On a settled
          // suggestion there is nothing to clean up: the owner wants it out of
          // sight, not out of existence, and "Löschen" there reads as "erase this
          // from the record".
          settled
            ? `<button class="danger" data-action="dismiss" data-id="${s.id}" data-focus-key="dismiss:${s.id}">✕ Schließen</button>`
            : s.status === 'implementing' || s.run?.status === 'running'
              ? ''
              : `<button class="danger" data-action="delete" data-id="${s.id}" data-focus-key="delete:${s.id}">Löschen</button>`
        }
      </div>
      ${
        expanded
          ? `<div class="details">
              ${s.clusterIds.length > 1 ? `<div><strong>Cluster:</strong> ${s.clusterIds.map((id) => `#${id}`).join(', ')}</div>` : ''}
              ${run ? `<div style="margin-top:8px"><strong>Letzter Run:</strong> ${escapeHtml(run.id)} · ${escapeHtml(run.status)} · ${run.cost != null ? `$${run.cost.toFixed(4)}` : 'Kosten unbekannt'}${run.tokensInput != null ? ` · ${run.tokensInput}/${run.tokensOutput} Tokens` : ''}${attemptLabel(run) ? ` · ${escapeHtml(attemptLabel(run) as string)}` : ''}</div>` : ''}
              <div style="margin-top:8px"><strong>Quelle:</strong> ${escapeHtml(s.source)} · erstellt ${new Date(s.createdAt).toLocaleString('de-DE')}</div>
              ${s.clientKey ? `<div style="margin-top:8px"><strong>Client-Key:</strong> <code>${escapeHtml(s.clientKey)}</code> · ein Retry mit diesem Schlüssel legt keine zweite Zeile an</div>` : ''}
            </div>`
          : ''
      }
    </article>
  `;
}

/**
 * Remembers which control has the keyboard focus, so a re-render can put it back.
 *
 * Every card is rebuilt through `innerHTML`, which destroys the focused node. A
 * keyboard user tabbing to "Genehmigen" therefore lost the focus — and the
 * document's focus position — every eight seconds, when the next poll landed. A
 * stable `data-focus-key` on every clickable row is what survives the rebuild.
 */
function captureFocusKey(): string | null {
  const el = document.activeElement as HTMLElement | null;
  const key = el?.dataset?.focusKey;
  return key ?? null;
}

function restoreFocusKey(key: string | null): void {
  if (!key) return;
  const el = document.querySelector<HTMLElement>(`[data-focus-key="${CSS.escape(key)}"]`);
  if (el) {
    // preventScroll: the scroll position is the panel's business, and jumping
    // back to the top on every poll would be its own kind of loss.
    el.focus({ preventScroll: true });
    return;
  }
  // The control is gone — "Genehmigen" disappears once the suggestion is
  // approved. Focus then fell back to the document, and a keyboard user had to
  // start over from the top; the list itself is where staying makes sense.
  if (document.activeElement === document.body) {
    document.getElementById('list')?.focus({ preventScroll: true });
  }
}

function renderList(): void {
  const list = visibleSuggestions();
  const container = $('#list');
  const focusKey = captureFocusKey();
  $('#empty').hidden = list.length > 0;
  const { children } = splitIndex();
  container.innerHTML = list
    .map((s) => renderCard(s, children.get(s.id) ?? []))
    .join('');
  const hash = location.hash.match(/^#suggestion-(\d+)$/);
  if (hash) {
    const el = document.getElementById(`suggestion-${hash[1]}`);
    if (el) {
      el.classList.add('highlight');
      el.scrollIntoView({ block: 'center' });
    }
  }
  restoreFocusKey(focusKey);
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
  // The session's output, as the run wrote it. This is the panel the owner
  // watches: what the agent says, in order, while it is doing it.
  const lines = eventsOf(run.id)
    .slice(-400)
    .map((event) => `<div class="line ${event.kind}">${escapeHtml(event.text)}</div>`)
    .join('');
  const operator = suggestionAuthor(run.suggestionId) === 'Betreiber' ? ' · Auftrag' : '';
  // The audit is what `describeLaneRisks` promises the operator when it says two
  // lanes may write to the same broad scope. It was computed, shipped, stored and
  // never read, so the promise had nothing behind it.
  const audit = scopeWarning(state.audits.get(run.id));
  const auditLine = audit
    ? `<div class="run-audit" title="Was dieser Run an Dateien angefasst hat, verglichen mit seinem Scope">📁 ${escapeHtml(audit)}</div>`
    : '';
  return `
    <div class="run-card activity-${activity.level}" data-run-card="${escapeAttr(runKey(run.id))}">
      <div class="run-title">
        <span>🤖 #${run.suggestionId}${operator} <span class="lane-tag" title="Diese Spur in der Warteschlange">Spur ${run.lane ?? '?'}</span></span>
        <span>${alive === false ? '⚠ Prozess weg' : '⚙ läuft'}</span>
      </div>
      <div class="run-sub run-task" title="${escapeHtml(suggestionText(run.suggestionId))}">${escapeHtml(suggestionText(run.suggestionId))}</div>
      <div class="run-sub" data-run-budget="${escapeAttr(runKey(run.id))}">${escapeHtml(runBudgetLine(run))}</div>
      ${auditLine}
      <div class="run-activity ${activity.level}" data-run-activity="${escapeAttr(runKey(run.id))}" title="Zeit seit der letzten Ausgabe von OpenCode">
        ${escapeHtml(activity.label)}
      </div>
      <div class="console" data-run-console="${escapeAttr(runKey(run.id))}">${lines}</div>
      <div class="card-actions">
        <button data-action="cancel-run" data-run="${escapeAttr(runKey(run.id))}" data-focus-key="cancel:${escapeAttr(runKey(run.id))}">⏹ Abbrechen</button>
        ${
          activity.level === 'stale' || activity.level === 'offline' || alive === false
            ? '<button data-action="reconcile-runs" data-focus-key="reconcile">🧹 Als beendet markieren</button>'
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
        // Two different waits, and the owner has to be able to tell them apart:
        // a run waiting for a free lane is one click away, a run waiting out a
        // retry backoff is not. "wartet" alone is what made both look broken.
        const inBackoff = run.notBefore != null && run.notBefore > Date.now();
        const waitReason = inBackoff
          ? 'wartet auf die Wartezeit'
          : blocked.has(run.id)
            ? 'wartet auf eine freie Spur'
            : 'wartet';
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
          <button data-action="cancel-run" data-run="${escapeAttr(runKey(run.id))}" data-focus-key="dequeue:${escapeAttr(runKey(run.id))}">⏹ Entfernen</button>
        </div>
      </div>`;
      })
      .join('');
  }

  const focusKey = captureFocusKey();
  active.innerHTML = html;
  // Every console shows the end of its own log, which is where the newest line
  // is. Only after the innerHTML swap, because before it the elements are old.
  for (const run of running) {
    const consoleEl = document.querySelector(`[data-run-console="${runKey(run.id)}"]`);
    if (consoleEl) consoleEl.scrollTop = consoleEl.scrollHeight;
  }
  updateRunActivity();

  $('#run-history').innerHTML = renderRunHistory();
  renderScopes();
  restoreFocusKey(focusKey);
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
    <span class="policy" title="Zeitlimit, Wiederholungen, Wartezeit und Spuren">${escapeHtml(summary.policyLabel)}</span>
    <span class="policy" id="queue-waiting">${escapeHtml(waitingLabel(summary))}</span>
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
  el.textContent = waitingLabel(summary);
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
      // The audit outlives the run: a run that wrote outside its scope is exactly
      // the thing the owner wants to see after it is over, not only while the
      // lane card is still on screen.
      const audit = scopeWarning(state.audits.get(run.id));
      return `
      <div class="run-card">
        <div class="run-title">
          <span>#${run.suggestionId}${attempt ? ` · ${escapeHtml(attempt)}` : ''}</span>
          <span>${badge ? `${badge.icon} ${escapeHtml(badge.label)}` : escapeHtml(run.status)}</span>
        </div>
        <div class="run-sub run-task" title="${escapeHtml(text)}">${escapeHtml(text)}</div>
        <div class="run-sub">${run.finishedAt ? timeAgo(run.finishedAt) : ''}${
          run.retryOf ? (run.resumesSession ? ' · ▶ fortgesetzt' : ' · ↻ wiederholt') : ''
        }</div>
        ${audit ? `<div class="run-audit">📁 ${escapeHtml(audit)}</div>` : ''}
        <div class="card-actions">
          ${
            run.status === 'failed' || run.status === 'cancelled'
              ? `<button data-action="retry-run" data-run="${escapeAttr(runKey(run.id))}" data-focus-key="retry:${escapeAttr(runKey(run.id))}">↻ Wiederholen</button>`
              : ''
          }
          ${
            // Fortsetzen keeps the session: the agent still knows what it read and
            // wrote, which is the whole difference after a time limit. Without a
            // session there is nothing to continue, so the button is not offered
            // rather than failing on click.
            run.status === 'failed' || run.status === 'cancelled'
              ? run.sessionId
                ? `<button data-action="resume-run" data-run="${escapeAttr(runKey(run.id))}" data-focus-key="resume:${escapeAttr(runKey(run.id))}" title="Setzt die OpenCode-Sitzung fort, statt neu anzufangen">▶ Fortsetzen</button>`
                : ''
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
    const key = CSS.escape(runKey(run.id));
    const el = document.querySelector(`[data-run-activity="${key}"]`);
    const budget = document.querySelector(`[data-run-budget="${key}"]`);
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
    const card = document.querySelector(`[data-run-card="${key}"]`);
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
  if (due.length === 0) return;
  let finished = false;
  let changed = false;
  for (const run of due) {
    try {
      const view = await api<RunView>(`/api/runs/${run.id}`);
      if (view.status !== 'running') {
        // The finish event was missed: note it and keep going, so one ended run
        // does not skip the re-check of every other lane behind it.
        finished = true;
        continue;
      }
      applyRunView(view);
      changed = true;
    } catch {
      /* run view is best-effort */
    }
  }
  // One render for the whole pass, not one per run, and a single refresh when a
  // run left the lane while the stream was quiet.
  if (finished) void refreshAll();
  else if (changed) renderRuns();
}

function render(): void {
  renderStats();
  renderCategories();
  renderList();
  renderRuns();
}

async function loadSuggestions(): Promise<void> {
  const seq = ++suggestionsSeq;
  const data = await api<{ suggestions: SuggestionView[] }>('/api/suggestions');
  // A response of an older request must not overwrite a newer one: a `run:started`
  // event arrives while this is in flight, and the snapshot taken before it still
  // says the run is queued. The lane card would then blink out of existence.
  if (seq < suggestionsSeq) return;
  setSuggestions(data.suggestions);
}

/**
 * Newest output time of a run. The server ships a scalar `lastEventAt` alongside
 * the event array; the array is only walked while that scalar is missing, so a
 * dashboard on a fresh server stops transferring a full log every eight seconds.
 * Nothing is retained — only the timestamp, which is all the panel ever drew.
 */
function lastOutputAt(view: RunView): number | null {
  const scalar = (view as RunView & { lastEventAt?: number | null }).lastEventAt;
  if (typeof scalar === 'number') return scalar;
  return lastEventTimestamp(view.events ?? []);
}

/** Folds one run view into the client bookkeeping. */
function applyRunView(view: RunView): void {
  // The server's event array is the console's content: this is what makes a
  // reload or a missed SSE line show the session again instead of an empty box.
  state.runEvents.set(view.id, view.events ?? []);
  state.alive.set(view.id, view.alive);
  if (view.scopeAudit) state.audits.set(view.id, view.scopeAudit);
  markActivity(view.id, lastOutputAt(view) ?? view.startedAt ?? undefined);
}

async function loadRuns(): Promise<void> {
  const seq = ++runsSeq;
  const data = await api<{ runs: RunRecord[] }>('/api/runs');
  if (seq < runsSeq) return;
  state.runs = data.runs;
  // Every run that holds a lane gets a card; the newest queued one does not, it
  // belongs in the waiting list below.
  const running = data.runs
    .filter((r) => r.status === 'running')
    .sort((a, b) => (a.startedAt ?? a.createdAt) - (b.startedAt ?? b.createdAt));
  const before = new Set(state.activeRuns.map((r) => r.id));
  state.activeRuns = running;
  // Forget a lane that ended while the page was closed, so its console does not
  // stay in memory and reappear on the next start event. The audit stays: it is
  // the evidence of what the run touched, and it is the one thing the run card
  // shows about a finished session.
  for (const id of before) {
    if (running.some((r) => r.id === id)) continue;
    state.runEvents.delete(id);
    state.lastActivityAt.delete(id);
    state.alive.delete(id);
  }
  pruneAudits();
  // Refresh console and per-run bookkeeping from the server, so runs that are
  // already going show their output and their last-output time even when SSE
  // events were missed.
  await Promise.all(
    running.map(async (run) => {
      try {
        applyRunView(await api<RunView>(`/api/runs/${run.id}`));
      } catch {
        /* run view is best-effort */
      }
    }),
  );
}

/** Keeps the audit map bounded; a run id is never reused, so insertion order is age. */
function pruneAudits(keep = 200): void {
  const overflow = state.audits.size - keep;
  if (overflow <= 0) return;
  const ids = [...state.audits.keys()].slice(0, overflow);
  for (const id of ids) state.audits.delete(id);
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

/**
 * The two dropdowns of the settings dialog: which model, and how hard it thinks.
 *
 * The model list comes from `/api/models`, which answers with what `opencode
 * models` reports on this machine plus the effort levels from opencode's public
 * catalog. It is fetched once per page: opening the dialog must not spawn a
 * process, and a list of thirty-odd models does not change while the panel is
 * open.
 *
 * An effort level that the chosen model does not support is a failed run, not a
 * slower one — opencode exits with `Variant unavailable for …` — which is why the
 * effort options come from the model and not from a fixed list of levels.
 */
function renderModelSelects(storedValue: string): void {
  const modelSelect = $('#setting-model') as HTMLSelectElement;
  const effortSelect = $('#setting-effort') as HTMLSelectElement;
  const { model, effort } = splitModelSetting(storedValue);
  const groups = groupModelChoices(state.models, model);
  const options = [
    `<option value=""${model === '' ? ' selected' : ''}>Standard — opencode wählt selbst</option>`,
    ...groups.map(
      (group) =>
        `<optgroup label="${escapeAttr(group.provider)}">${group.options
          .map((option) => `<option value="${escapeAttr(option.value)}"${option.value === model ? ' selected' : ''}>${escapeHtml(option.label)}</option>`)
          .join('')}</optgroup>`,
    ),
  ];
  modelSelect.innerHTML = options.join('');
  // A model the owner picked but the list does not know: the effort levels are
  // unknown, and offering any would be offering a guess.
  const choice = findChoice(state.models, model);
  // Three states, told apart: still loading, failed, or loaded. "lädt" that never
  // ends is a lie, and a failed load has to be visible — otherwise the owner sees
  // an empty box and blames the dialog.
  $('#model-state').textContent =
    state.models.length > 0
      ? !state.modelCatalog
        ? 'Katalog nicht erreichbar — Modell wählbar, Anstrengung nicht.'
        : choice && choice.efforts.length === 0
          ? `${choice.name} hat keine Anstrengungsstufen.`
          : ''
      : state.modelListError
        ? `Modelliste nicht ladbar (${state.modelListError}) — der gespeicherte Wert bleibt erhalten.`
        : 'Modellliste wird geladen …';
  renderEffortSelect(choice, effort);
}

/** The effort options of one model. A level it does not have is never offered. */
function renderEffortSelect(choice: ModelChoice | null, effort: string): void {
  const effortSelect = $('#setting-effort') as HTMLSelectElement;
  const options = effortOptions(choice);
  const known = options.some((option) => option.value === effort);
  effortSelect.innerHTML = options
    .map((option) => `<option value="${escapeAttr(option.value)}"${option.value === effort && known ? ' selected' : ''}>${escapeHtml(option.label)}</option>`)
    .join('');
  effortSelect.disabled = (choice?.efforts.length ?? 0) === 0;
  $('#effort-state').textContent = choice && choice.efforts.length > 0
    ? 'Höher = mehr Nachdenken, mehr Kosten, längere Laufzeit.'
    : '';
}

/** Fetches the model list once; a failure leaves the dropdowns as they are. */
async function loadModelChoices(): Promise<void> {
  if (state.modelsLoaded) return;
  try {
    const list = await api<ModelList>('/api/models');
    state.models = list.models;
    state.modelCatalog = list.catalog;
    state.modelListError = null;
    state.modelsLoaded = true;
  } catch (err) {
    // The dialog stays usable and says so: the stored value stays in the field,
    // and the note under it names the reason instead of leaving "wird geladen".
    state.modelListError = errorText(err);
    state.modelsLoaded = true;
  }
}

async function loadSettings(): Promise<void> {
  const settings = await api<{
    discordWebhook: string;
    model: string;
    extraInstructions: string;
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
  renderModelSelects(settings.model);
  ($('#setting-instructions') as HTMLTextAreaElement).value = settings.extraInstructions;
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

/** Message of a rejected load, never a raw `unknown`. */
function errorText(err: unknown): string {
  return err instanceof Error && err.message ? err.message : String(err);
}

/**
 * Loads everything and re-renders. Deliberately quiet: this is what the page
 * calls on a timer, so a failure here is a *state*, not an event. The last good
 * data stays on screen — a dashboard that empties itself because a server is
 * restarting has thrown away the information the operator is looking for.
 *
 * Each endpoint carries its own failure. One 500 from `/api/suggestions` used to
 * reject the whole `Promise.all` and paint "server unreachable" in the top bar of
 * a server that was answering everything else perfectly; now the bar names the
 * endpoint that failed and the other panels keep their data.
 */
async function refreshOnce(): Promise<void> {
  const [suggestions, runs] = await Promise.all([
    loadSuggestions().catch((err) => `Vorschläge: ${errorText(err)}`),
    loadRuns().catch((err) => `Runs: ${errorText(err)}`),
    loadQueue(),
    loadManifest(),
  ]);
  // The bar has room for one line, so the first failure is the one that is
  // named — and the wording says a single endpoint, not the whole server.
  setLoadError(suggestions ?? runs ?? null);
  render();
  void maybeAutoReconcile();
}

/**
 * One refresh at a time, and a request that arrives while one is running is
 * remembered rather than dropped. `refreshAll` has nine callers — the 8 s timer,
 * five stream handlers and every operator action — and two concurrent runs
 * interleaved their writes: a poll started before a `run:started` event finished
 * after it and put the run back to "queued", so its lane card disappeared.
 */
let refreshRunning: Promise<void> | null = null;
let refreshQueued = false;

function refreshAll(): Promise<void> {
  if (refreshRunning) {
    refreshQueued = true;
    return refreshRunning;
  }
  refreshRunning = (async () => {
    try {
      do {
        refreshQueued = false;
        await refreshOnce();
      } while (refreshQueued);
    } finally {
      refreshRunning = null;
    }
  })();
  return refreshRunning;
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
  const networkDown = state.loadError !== null && state.loadError.includes(OFFLINE);
  el.textContent = offline
    ? `${state.loadError} — ${networkDown ? 'lädt nach, sobald er wieder da ist' : 'der Rest lädt weiter'}`
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
  // Three entry points reach this — the cleanup button, the run card and the
  // automatic pass — and a second POST while the first was still running marked
  // the same runs a second time.
  if (reconciling) return;
  reconciling = true;
  try {
    const result = await api<{ fixed: RunRecord[] }>('/api/runs/reconcile', { method: 'POST' });
    if (result.fixed.length === 0) toast('Keine verwaisten Runs gefunden.');
    else toast(`${result.fixed.length} verwaiste${result.fixed.length === 1 ? 'r' : ''} Run${result.fixed.length === 1 ? '' : 's'} aufgeräumt`, 'success');
    await refreshAll();
  } catch (err) {
    toast((err as Error).message, 'error');
  } finally {
    reconciling = false;
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

/**
 * Actions currently in flight, keyed by what they act on. Two clicks on
 * "Genehmigen" fired two PATCHes and two votes before this existed; the key is
 * per action *and* per target, so cancelling one run never blocks another.
 */
const acting = new Set<string>();

function actionKey(action: string, id: number, runId?: string): string {
  return `${action}:${runId ?? id}`;
}

/**
 * Runs one operator action. Every branch owns its own follow-up: an action that
 * only changes the view returns, and an unknown one says so. Falling through to
 * a `refreshAll()` after a branch that did nothing is how a typo in a
 * `data-action` attribute became a silent no-op that looked like a reload.
 */
async function act(action: string, id: number, runId?: string, button?: HTMLButtonElement): Promise<void> {
  const key = actionKey(action, id, runId);
  if (acting.has(key)) return;
  acting.add(key);
  // The clicked button is dimmed until the answer is in, so the guard is visible
  // and not only felt.
  if (button) button.disabled = true;
  try {
    if (action === 'split') {
      await openSplitDialog(id);
      return;
    }
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
    } else if (action === 'cancel-run') {
      if (!runId) {
        toast('Run ohne Kennung — der Knopf gehört auf eine Run-Karte.', 'error');
        return;
      }
      await api(`/api/runs/${runId}/cancel`, { method: 'POST', body: JSON.stringify({}) });
      toast('Run abgebrochen');
    } else if (action === 'resume-run') {
      const result = await api<{ run: RunRecord }>(`/api/runs/${runId}/resume`, {
        method: 'POST',
        body: JSON.stringify({}),
      });
      toast(`Setzt den Run für #${result.run.suggestionId} in seiner Sitzung fort`, 'success');
      await refreshAll();
    } else if (action === 'retry-run') {
      if (!runId) {
        toast('Run ohne Kennung — der Knopf gehört auf eine Run-Karte.', 'error');
        return;
      }
      await retryRun(runId);
      return;
    } else if (action === 'details') {
      if (state.expanded.has(id)) state.expanded.delete(id);
      else state.expanded.add(id);
      renderList();
      return;
    } else {
      // An action nobody implements is a bug in a template, and the operator
      // deserves to hear it instead of watching a reload that changed nothing.
      toast(`Unbekannte Aktion „${action}“ — nichts passiert.`, 'error');
      return;
    }
    await refreshAll();
  } catch (err) {
    toast((err as Error).message, 'error');
  } finally {
    acting.delete(key);
    // The list is rebuilt by the refresh above, so this node may be gone by now;
    // disabling a detached node is harmless either way.
    if (button) button.disabled = false;
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
      patchSuggestion(event.suggestion.id, event.suggestion);
      toast(`Neuer Vorschlag #${event.suggestion.id}: ${event.suggestion.text.slice(0, 60)}…`, 'success');
      render();
    } else if (event.type === 'suggestion:updated' || event.type === 'suggestion:vote') {
      patchSuggestion(event.suggestion.id, event.suggestion);
      renderStats();
      renderList();
      renderRuns();
    } else if (event.type === 'run:started') {
      // A new lane: add it next to the ones already running instead of replacing
      // whatever was on screen.
      state.activeRuns = [...state.activeRuns.filter((r) => r.id !== event.run.id), event.run];
      // A run id is never reused, but a card that kept a stale console would be
      // a lie; starting empty is also what the server sends.
      state.runEvents.set(event.run.id, []);
      state.alive.set(event.run.id, true);
      markActivity(event.run.id, event.run.startedAt ?? Date.now());
      renderRuns();
      // Refresh so the started run leaves the queue list and its lane is known.
      // `refreshAll` serialises: a poll already in flight finishes first, then
      // this one re-reads the list — so the run cannot be put back to "queued".
      void refreshAll();
    } else if (event.type === 'run:log') {
      // One line into the run's own console, in place, so the owner watches the
      // session instead of re-reading it in the history afterwards.
      const buffer = eventsOf(event.runId).slice();
      buffer.push(event.event);
      // Bounded: a long run would otherwise keep every line it ever wrote.
      if (buffer.length > 1500) buffer.splice(0, buffer.length - 1500);
      state.runEvents.set(event.runId, buffer);
      markActivity(event.runId);
      const consoleEl = document.querySelector(`[data-run-console="${runKey(event.runId)}"]`);
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
    } else if (event.type === 'run:finished') {
      // `toast` writes textContent, so this value needs no escaping — the
      // browser does it. Escaping here would show the entities themselves.
      toast(`Run für #${event.run.suggestionId}: ${event.run.status}`, event.run.status === 'succeeded' ? 'success' : 'error');
      state.activeRuns = state.activeRuns.filter((r) => r.id !== event.run.id);
      state.runEvents.delete(event.run.id);
      state.lastActivityAt.delete(event.run.id);
      state.alive.delete(event.run.id);
      void refreshAll();
    } else if (event.type === 'queue:state') {
      state.queue = event.state;
      // `renderRuns` draws the pause chip, the lanes and the waiting line itself;
      // calling `renderQueueState` first painted the same row twice per event.
      renderRuns();
    }
  };
}

function setupUi(): void {
  $('#tabs').addEventListener('click', (event) => {
    const button = (event.target as HTMLElement).closest('button[data-tab]') as HTMLButtonElement | null;
    if (!button) return;
    selectTab(button.dataset.tab as Tab);
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
  // Left/right through the tab row, as a tablist is expected to behave.
  $('#tabs').addEventListener('keydown', (event) => {
    const key = event as KeyboardEvent;
    if (key.key !== 'ArrowRight' && key.key !== 'ArrowLeft') return;
    const buttons = [...document.querySelectorAll<HTMLButtonElement>('#tabs button')];
    const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
    if (index < 0) return;
    key.preventDefault();
    const next = buttons[(index + (key.key === 'ArrowRight' ? 1 : buttons.length - 1)) % buttons.length];
    next.focus();
    selectTab(next.dataset.tab as Tab);
  });
  $('#list').addEventListener('click', (event) => {
    const button = (event.target as HTMLElement).closest('button[data-action]') as HTMLButtonElement | null;
    if (!button) return;
    const id = Number(button.dataset.id);
    void act(button.dataset.action ?? '', id, button.dataset.run, button);
  });
  $('#active-run').addEventListener('click', (event) => {
    const target = event.target as HTMLElement;
    if (target.closest('button[data-action="reconcile-runs"]')) {
      void reconcileRuns();
      return;
    }
    const button = target.closest('button[data-action="cancel-run"]') as HTMLButtonElement | null;
    if (!button) return;
    void act('cancel-run', 0, button.dataset.run, button);
  });
  $('#run-history').addEventListener('click', (event) => {
    const button = (event.target as HTMLElement).closest('button[data-action="retry-run"]') as HTMLButtonElement | null;
    if (!button?.dataset.run) return;
    // Through `act`, so the retry is guarded like every other action: a double
    // click queued two attempts of the same run.
    void act('retry-run', 0, button.dataset.run, button);
  });
  $('#toggle-pause').addEventListener('click', () => void togglePause());
  $('#cleanup-runs').addEventListener('click', () => void reconcileRuns());
  $('#refresh-runs').addEventListener('click', () => void refreshAll());
  $('#backup-write').addEventListener('click', () => void writeBackup());
  $('#backup-read').addEventListener('click', () => void readBackup());
  // Opening the panel is the signal that the numbers may have moved (a commit on
  // another machine, a merge by hand), so that is when it re-reads them. The
  // scope panel needed the same listener: it is drawn once at boot and the
  // manifest is regenerated by `scripts/scopes.mjs` — opening it was the only
  // moment a changed scope list could have been noticed.
  $('#backup-panel').addEventListener('toggle', () => void loadBackup());
  $('#scope-panel').addEventListener('toggle', () => {
    void loadManifest().then(() => renderScopes());
  });
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
  $('#restart-server').addEventListener('click', async () => {
    const button = $('#restart-server') as HTMLButtonElement;
    try {
      await api('/api/server/restart', { method: 'POST' });
      // The connection dies here by design: the process answering this request is
      // the one being replaced. A `fetch` that rejects with "Failed to fetch" is
      // therefore the expected answer, not a failure — reporting it as an error
      // would tell the owner the restart did not work when it did.
      toast('Server startet neu — das Dashboard verbindet sich von selbst wieder.', 'success');
      button.disabled = true;
      // The SSE stream dies with the server; the reconnect path takes over, and a
      // poll that lands before the new process listens must not read as "server
      // unreachable" forever. `hadConnection` is what stops that loop.
      setTimeout(() => {
        button.disabled = false;
      }, 8000);
    } catch (err) {
      toast((err as Error).message, 'error');
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
    // The list in the background: the dialog opens with the stored value and
    // fills in, instead of the owner waiting for `opencode models` and a catalog.
    void loadModelChoices().then(() => {
      const current = joinModelSetting(
        ($('#setting-model') as HTMLSelectElement).value,
        ($('#setting-effort') as HTMLSelectElement).value,
      );
      renderModelSelects(current);
    });
    await loadSettings();
    dialog.showModal();
  });
  $('#close-settings').addEventListener('click', () => dialog.close());
  $('#setting-model').addEventListener('change', (event) => {
    const id = (event.target as HTMLSelectElement).value;
    renderEffortSelect(findChoice(state.models, id), '');
  });
  $('#save-settings').addEventListener('click', async () => {
    const body: Record<string, unknown> = {
      model: joinModelSetting(
        ($('#setting-model') as HTMLSelectElement).value,
        ($('#setting-effort') as HTMLSelectElement).value,
      ),
      extraInstructions: ($('#setting-instructions') as HTMLTextAreaElement).value,
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
      // The lane count and the timeout are part of the queue policy line above
      // the composer, and that line comes from `/api/runner` — re-reading it
      // here is what makes the saved numbers visible at once instead of on the
      // next poll.
      await loadQueue();
      renderQueueState();
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

/**
 * Switches the visible tab and keeps the tab row's state in sync: the active
 * class, `aria-selected` and a roving tabindex, so the row is one tab stop
 * instead of five and the arrow keys move inside it.
 */
function selectTab(tab: Tab): void {
  state.tab = tab;
  for (const button of document.querySelectorAll<HTMLButtonElement>('#tabs button')) {
    const active = button.dataset.tab === tab;
    button.classList.toggle('active', active);
    button.setAttribute('aria-selected', String(active));
    button.tabIndex = active ? 0 : -1;
  }
  renderList();
}

function applyDefaultTab(): void {
  if (visibleSuggestions().length === 0) {
    const candidates: Tab[] = ['queue', 'new', 'done', 'cluster', 'top'];
    for (const tab of candidates) {
      state.tab = tab;
      if (visibleSuggestions().length > 0) break;
    }
  }
  selectTab(state.tab);
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
