import { EventEmitter } from 'node:events';
import { timingSafeEqual } from 'node:crypto';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import Fastify, { type FastifyInstance, type FastifyRequest } from 'fastify';
import fastifyStatic from '@fastify/static';
import type { BusEvent, RunRecord, Suggestion, SuggestionStatus, SuggestionView } from '../src/shared/types';
import { OPERATOR_SOURCE } from '../src/shared/types';
import { classify, decorate, decorateAll, sortSuggestions, type SortMode } from '../src/shared/sorting';
import { ContentStore } from './content';
import { Store } from './db';
import * as discord from './discord';
import * as telegram from './telegram';
import { TelegramBot } from './telegramBot';
import { findOpencodeBinary, Runner } from './runner';
import { findTerminal } from './terminal';
import {
  backupPath,
  backupStatus,
  buildSnapshot,
  describeBackup,
  mergeSnapshot,
  readSnapshotFile,
  writeSnapshotFile,
} from './backup';
import { CheckRunner } from './checkrunner';
import { CHECKS_BY_ID, CHECK_SPECS } from './checks/catalogue';
import { scopeForSuggestion, scopeManifest } from './scopes';
import { normalizeTasks, planSplit, splitIntoTasks, splitRepeatError } from './split';

export interface AppOptions {
  dataDir: string;
  contentDir: string;
  projectRoot: string;
  distDir: string;
  dashboardUrl?: string;
  runnerEnabled?: boolean;
  /**
   * Run each session in a terminal window instead of the dashboard's log pane.
   * Set from `server/index.ts`; off by default, and `S80_TERMINAL=0` overrides
   * it without touching code.
   */
  terminalRuns?: boolean;
  /**
   * Give every run its own git worktree and its own branch, instead of having all
   * runs write into the shared tree. Set from `server/index.ts`; off by default,
   * and `S80_ISOLATE_RUNS=1` turns it on without touching code.
   *
   * With it on, a finished run's commits are on `agent/suggestion-<id>` and not
   * on `main` — `npm run merge-gate` is what merges them, verifies the result
   * and pushes. See `server/isolation.ts` for the failure modes it removes.
   */
  isolateRuns?: boolean;
}

// The main page is the dashboard; `/dashboard.html` only redirects there.
const DASHBOARD_URL = process.env.DASHBOARD_URL || 'http://localhost:5173/';

/** Header carrying the shared secret of `SINGULAR80_TOKEN`. */
const TOKEN_HEADER = 'x-singular80-token';

/**
 * Routes that stay reachable without a token, and the only ones.
 *
 * They are the two a player's device talks to. The game knows a server address
 * and nothing else — it cannot send a header nobody ever told it about — so a
 * guard here would not secure anything, it would only turn every suggestion into
 * one that never arrives. Everything that starts an agent, changes settings or
 * deletes history is behind the token.
 */
const PUBLIC_POST_ROUTES = [/^\/api\/suggestions$/, /^\/api\/suggestions\/\d+\/vote$/];

/** The shared secret, or `''` for a server that runs open. Read per request so
 * a test can set it after the app was built. */
function apiToken(): string {
  return (process.env.SINGULAR80_TOKEN ?? '').trim();
}

/** The path without the query string — route patterns must not see the search. */
function pathOf(req: FastifyRequest): string {
  return req.url.split('?')[0];
}

/** Constant-time comparison, and false on a length mismatch (which `timingSafeEqual`
 * treats as an error rather than as a mismatch). */
function hasToken(req: FastifyRequest): boolean {
  const expected = apiToken();
  if (!expected) return true;
  const header = req.headers[TOKEN_HEADER];
  const provided = Array.isArray(header) ? (header[0] ?? '') : (header ?? '');
  const a = Buffer.from(provided, 'utf8');
  const b = Buffer.from(expected, 'utf8');
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

/**
 * The `Access-Control-Allow-Origin` to send, or nothing.
 *
 * Without a token the API is what it always was and the answer is `*`. With a
 * token it is no longer a public read surface, so a browser only gets the grant
 * when it actually presented the token — a dashboard on another device then gets
 * no CORS answer at all instead of the whole history.
 */
function corsOrigin(req: FastifyRequest): string | null {
  if (!apiToken()) return '*';
  if (!hasToken(req)) return null;
  const origin = req.headers.origin;
  return (Array.isArray(origin) ? origin[0] : origin) ?? '*';
}

let openServerWarned = false;

export function createApp(options: AppOptions): FastifyInstance {
  const app = Fastify({ logger: false, bodyLimit: 1024 * 256 });
  if (!apiToken() && !openServerWarned) {
    openServerWarned = true;
    // Once per process, not once per app: a test builds a dozen apps, and the
    // operator needs to read this exactly once.
    console.warn(
      '[security] SINGULAR80_TOKEN ist nicht gesetzt — jede schreibende /api-Route ist ohne Anmeldung offen. Auf einem Netzbinding (HOST=0.0.0.0) kann damit jedes Gerät Aufträge starten, die committet und pusht werden.',
    );
  }
  const store = new Store(options.dataDir);
  const content = new ContentStore(options.contentDir);
  const bus = new EventEmitter();
  bus.setMaxListeners(0);

  const dashboardUrl = options.dashboardUrl ?? DASHBOARD_URL;

  const viewOf = (id: number): SuggestionView | null => {
    const all = store.listSuggestions();
    const found = all.find((s) => s.id === id);
    if (!found) return null;
    const view = decorate(found, all, Date.now());
    if (found.runId) view.run = store.getRun(found.runId);
    return view;
  };

  const emit = (event: BusEvent) => bus.emit('event', event);

  const runner = options.runnerEnabled === false
    ? null
    : new Runner(store, {
        projectRoot: options.projectRoot,
        dataDir: options.dataDir,
        contentDir: options.contentDir,
        // Only the application may turn this on. Tests build a Runner directly
        // and would otherwise open a window on the desktop for every case.
        terminalMode: options.terminalRuns === true && findTerminal() !== null,
        isolateRuns: options.isolateRuns === true,
        callbacks: {
          onStarted: (run) => {
            emit({ type: 'run:started', run });
            const view = viewOf(run.suggestionId);
            if (view) emit({ type: 'suggestion:updated', suggestion: view });
          },
          onEvent: (runId, event) => emit({ type: 'run:log', runId, event }),
          onQueueState: (state) => emit({ type: 'queue:state', state }),
          onFinished: (run) => {
            emit({ type: 'run:finished', run });
            const suggestion = store.getSuggestion(run.suggestionId);
            const view = viewOf(run.suggestionId);
            if (view) emit({ type: 'suggestion:updated', suggestion: view });
            const webhook = store.getSettings().discordWebhook || process.env.DISCORD_WEBHOOK_URL || '';
            if (suggestion && webhook) {
              // Fire-and-forget, so it needs a rejection handler of its own:
              // Node 22 aborts the process on an unhandled rejection, and one
              // broken webhook address would take the server with it.
              void discord.notifyRunResult(suggestion, run, webhook, dashboardUrl).catch((err) => {
                console.warn('[discord] Laufergebnis nicht zugestellt:', (err as Error).message);
              });
            }
            // The outcome is written **into** the task's own message instead of
            // as a new one. That is what keeps the chat short: one message per
            // task, shrinking to one line when it is done. If the id is unknown
            // — an older suggestion, or one re-announced on another machine — the
            // line is sent instead, so the owner is never left without a result.
            if (suggestion && telegram.isConfigured()) {
              const text = telegram.runResultText(suggestion.id, run.status === 'succeeded');
              const messageId = store.getSuggestionTelegramMessage(suggestion.id);
              void (messageId ? telegram.editMessageText(messageId, text) : telegram.sendMessage(text))
                .then((sent) => {
                  if (!sent.ok) console.warn('[telegram] Ergebnis nicht zugestellt:', sent.error);
                })
                .catch((err) => {
                  console.warn('[telegram] Ergebnis nicht zugestellt:', (err as Error).message);
                });
            }
          },
        },
      });

  /**
   * The check queue exists whether or not the suggestion runner is enabled: the
   * two answer different questions, and an operator who turned the agent off
   * still wants to know which buttons are dead. Static checks read the
   * repository, so they need neither `opencode` nor a device.
   */
  const checkRunner = new CheckRunner({
    projectRoot: options.projectRoot,
    store,
    // A static scan reads the whole repository; running it inline would block
    // the event loop for every SSE client, every agent control and /api/health
    // for the duration. Answer first, scan on the next tick.
    deferWork: true,
    callbacks: {
      onStarted: (check) => emit({ type: 'check:started', check }),
      onFinished: (check) => emit({ type: 'check:finished', check }),
      onQueueState: (state) => emit({ type: 'check:queue', state }),
    },
  });

  app.addHook('preHandler', async (req, reply) => {
    if (!apiToken()) return;
    if (req.method === 'GET' || req.method === 'HEAD' || req.method === 'OPTIONS') return;
    if (!req.url.startsWith('/api/')) return;
    if (PUBLIC_POST_ROUTES.some((route) => route.test(pathOf(req)))) return;
    if (hasToken(req)) return;
    return reply.code(401).send({
      error: `Ungültiges oder fehlendes Token — der Header ${TOKEN_HEADER} wird für diese Anfrage verlangt.`,
    });
  });

  app.addHook('onSend', async (req, reply, payload) => {
    const origin = corsOrigin(req);
    if (origin) reply.header('Access-Control-Allow-Origin', origin);
    reply.header('Access-Control-Allow-Headers', `Content-Type, ${TOKEN_HEADER}`);
    reply.header('Access-Control-Allow-Methods', 'GET,POST,PATCH,PUT,DELETE,OPTIONS');
    return payload;
  });

  app.options('/*', async (_req, reply) => reply.code(204).send());

  app.get('/api/health', async () => {
    const bin = findOpencodeBinary();
    return {
      ok: true,
      uptime: process.uptime(),
      opencodeBin: bin,
      opencodeFound: existsSync(bin),
      activeRun: runner?.activeRun() ?? null,
      activeRuns: runner?.activeRuns() ?? [],
      suggestions: store.listSuggestions().length,
    };
  });

  app.get('/api/suggestions', async (req) => {
    const query = req.query as { status?: string; category?: string; sort?: string; q?: string };
    const all = store.listSuggestions();
    // One pass over the whole list: `decorate` per row would rebuild the cluster
    // index per row, which is quadratic on a table this route polls every few
    // seconds.
    const decorated = decorateAll(all, Date.now());
    let views = all.map((s, i) => {
      const v = decorated[i];
      if (s.runId) v.run = store.getRun(s.runId);
      return v;
    });
    if (query.status) {
      const statuses = query.status.split(',');
      views = views.filter((v) => statuses.includes(v.status));
    }
    if (query.category) {
      const cats = query.category.split(',');
      views = views.filter((v) => cats.includes(v.category));
    }
    if (query.q) {
      const needle = query.q.toLowerCase();
      views = views.filter((v) => v.text.toLowerCase().includes(needle));
    }
    views = sortSuggestions(views, (query.sort as SortMode) ?? 'score');
    return { suggestions: views, stats: statsOf(views) };
  });

  app.get('/api/suggestions/:id', async (req, reply) => {
    const id = intParam(req);
    if (id === null) return reply.code(404).send({ error: 'Vorschlag nicht gefunden' });
    const view = viewOf(id);
    if (!view) return reply.code(404).send({ error: 'Vorschlag nicht gefunden' });
    const runs = runner?.listSuggestionRuns(id) ?? store.listRuns(200).filter((r) => r.suggestionId === id);
    return { suggestion: view, runs };
  });

  /**
   * There is no `POST /api/suggestions`.
   *
   * A suggestion from the device goes straight to the owner's Telegram chat —
   * `telegram_relay.gd` in the game, and nothing in between. It used to be posted
   * here whenever the game had a server address configured, and that was the
   * reason a suggestion typed on the tablet never arrived: the address pointed
   * somewhere that did not answer, the post failed, and the one route that would
   * have worked was never tried. Two ways out meant the wrong one was chosen by a
   * stale config file rather than by what actually works, so the second way is
   * gone.
   *
   * What a player writes is not a row in this database: it has no number, no
   * score, no cluster and nothing the runner could ever pick up. Everything this
   * server stores arrives through `POST /api/tasks` — the dashboard's button and
   * the chat's `/task` — and every one of those is announced in the same chat.
   */
  app.post('/api/suggestions/:id/vote', async (req, reply) => {
    const id = intParam(req);
    const body = (req.body ?? {}) as { voterId?: string };
    const voterId = (body.voterId ?? '').trim();
    if (id === null || !store.getSuggestion(id)) return reply.code(404).send({ error: 'Vorschlag nicht gefunden' });
    if (voterId.length < 6) return reply.code(400).send({ error: 'voterId fehlt' });
    // The store decides `changed`: a second vote from the same device is ignored
    // by the primary key, and the route used to answer `changed: true` for it
    // anyway — the dashboard then re-animated a vote that never counted.
    const vote = store.addVote(id, voterId.slice(0, 64));
    const view = viewOf(id)!;
    emit({ type: 'suggestion:vote', suggestion: view });
    return { votes: view.votes, changed: vote.changed };
  });

  app.patch('/api/suggestions/:id', async (req, reply) => {
    const id = intParam(req);
    if (id === null) return reply.code(404).send({ error: 'Vorschlag nicht gefunden' });
    const body = (req.body ?? {}) as { status?: SuggestionStatus };
    const allowed: SuggestionStatus[] = ['new', 'approved', 'rejected', 'implementing', 'implemented', 'failed'];
    if (!body.status || !allowed.includes(body.status)) {
      return reply.code(400).send({ error: `status muss einer von ${allowed.join(', ')} sein` });
    }
    const result = setStatus(id, body.status);
    if (!result.ok) return reply.code(404).send({ error: result.error });
    return viewOf(id);
  });

  /**
   * Deleting — for test entries, duplicates and phantom input from the game.
   *
   * Going through `rejected` is not enough: a rejected suggestion stays in the
   * history and in `backup/dashboard.json`. Someone who really wants it gone has
   * to be able to delete it.
   *
   * **Not while a run is executing.** The runner holds the suggestion in memory
   * and writes the result back later; deleting now would leave a run pointing at
   * a suggestion that no longer exists. 409 beats silent data loss.
   */
  app.delete('/api/suggestions/:id', async (req, reply) => {
    const id = intParam(req);
    if (id === null) return reply.code(404).send({ error: 'Vorschlag nicht gefunden' });
    const suggestion = store.getSuggestion(id);
    if (!suggestion) return reply.code(404).send({ error: 'Vorschlag nicht gefunden' });
    if (runner?.isBusyForSuggestion(suggestion)) {
      return reply.code(409).send({ error: `Für #${id} läuft gerade ein Run — Abbrechen oder warten.` });
    }
    if (!store.deleteSuggestion(id)) return reply.code(404).send({ error: 'Vorschlag nicht gefunden' });
    // No `emit`: a new event type would have to live in `src/shared/types.ts`,
    // which AGENTS.md forbids changing. The UI reloads its list after a delete,
    // which it has to do anyway to drop the entry locally.
    return { ok: true, id };
  });

  /**
   * Starts a run for an existing suggestion.
   *
   * This is the **one** place that does. The HTTP button and the Telegram
   * command `/run` both come here; two copies would be two places where
   * dashboard and chat silently diverge, and the divergence only shows up once a
   * run starts by one route and not by the other.
   */
  const startRun = (
    id: number,
    extraInstructions = '',
  ): { ok: boolean; error?: string; runId?: string; run?: RunRecord; view?: SuggestionView } => {
    if (!runner) return { ok: false, error: 'Der Runner ist abgeschaltet.' };
    const suggestion = store.getSuggestion(id);
    if (!suggestion) return { ok: false, error: `Vorschlag #${id} gibt es nicht.` };
    if (runner.isBusyForSuggestion(suggestion)) {
      return { ok: false, error: `Für #${id} läuft bereits ein Run.` };
    }
    const settings = store.getSettings();
    const merged = { ...settings };
    const extra = extraInstructions.trim();
    if (extra) merged.extraInstructions = [settings.extraInstructions, extra].filter(Boolean).join('\n');
    const all = store.listSuggestions();
    const canonical = suggestion.canonicalId ?? suggestion.id;
    const cluster = all.filter((s) => (s.canonicalId ?? s.id) === canonical);
    const run = runner.enqueue(suggestion, merged, cluster);
    const view = viewOf(id)!;
    emit({ type: 'suggestion:updated', suggestion: view });
    return { ok: true, runId: run.id, run, view };
  };

  /**
   * Creates a free order and queues it immediately.
   *
   * Single source for that too: the dashboard's "Direkter Auftrag" button and the
   * chat's `/task` command both call here. Two copies would be two places where
   * an order behaves differently depending on where it came from — and the
   * difference only shows up once an order reaches the queue by one route and not
   * by the other.
   *
   * The order is stored as a suggestion with `OPERATOR_SOURCE` rather than held
   * in memory: scope prediction, retry rules, commit guard and history then keep
   * working unchanged, and it appears in the dashboard next to the player
   * suggestions instead of existing beside them.
   */
  const createTask = async (
    text: string,
    extraInstructions = '',
  ): Promise<{ ok: boolean; error?: string; runId?: string; suggestionId?: number }> => {
    if (!runner) return { ok: false, error: 'Der Runner ist abgeschaltet.' };
    const clean = text.trim();
    if (clean.length < 3) return { ok: false, error: 'Der Auftrag braucht mindestens 3 Zeichen.' };
    if (clean.length > 4000) {
      return { ok: false, error: `Der Auftrag ist ${clean.length} Zeichen lang — bitte auf 4000 kürzen.` };
    }
    const settings = store.getSettings();
    const merged = { ...settings };
    const extra = extraInstructions.trim();
    if (extra) merged.extraInstructions = [settings.extraInstructions, extra].filter(Boolean).join('\n');
    const suggestion = store.createSuggestion({
      text: clean,
      author: 'Betreiber',
      source: OPERATOR_SOURCE,
      category: classify(clean),
      canonicalId: null,
      status: 'approved',
    });
    const run = runner.enqueue(suggestion, merged, [suggestion]);
    const view = viewOf(suggestion.id);
    if (view) {
      if (telegram.isConfigured()) {
        // Announced once, so the result can replace this message rather than
        // follow it.
        const sent = await telegram.notifyNewSuggestion(view, dashboardUrl);
        if (!sent.ok) console.warn('[telegram] Auftrag nicht zugestellt:', sent.error);
        else if (sent.messageId) store.setSuggestionTelegramMessage(suggestion.id, sent.messageId);
      }
      emit({ type: 'suggestion:new', suggestion: view });
    }
    return { ok: true, runId: run.id, suggestionId: suggestion.id };
  };

  /**
   * Sets the status and tells both ends. Single source as well, so the chat does
   * not grow its own truth.
   */
  const setStatus = (id: number, status: SuggestionStatus): { ok: boolean; error?: string } => {
    const updated = store.updateSuggestionStatus(id, status);
    if (!updated) return { ok: false, error: `Vorschlag #${id} gibt es nicht.` };
    const view = viewOf(id)!;
    const webhook = store.getSettings().discordWebhook || process.env.DISCORD_WEBHOOK_URL || '';
    if (webhook && view.discordMessageId) {
      void discord.updateSuggestionMessage(view, webhook, dashboardUrl).catch((err) => {
        console.warn('[discord] Nachricht nicht aktualisiert:', (err as Error).message);
      });
    }
    // Only a decision the owner made is worth a message. `implementing`,
    // `implemented` and `failed` arrive on their own as a rewritten task message,
    // and announcing them again would put three lines per task back into the chat
    // — the noise this is meant to remove.
    if (telegram.isConfigured() && (status === 'approved' || status === 'rejected')) {
      const sent = telegram.sendMessage(`Aufruf ${id} ${status === 'approved' ? 'freigegeben' : 'abgelehnt'}`);
      void sent
        .then((r) => {
          if (!r.ok) console.warn('[telegram] Statuswechsel nicht zugestellt:', r.error);
        })
        .catch((err) => {
          console.warn('[telegram] Statuswechsel nicht zugestellt:', (err as Error).message);
        });
    }
    emit({ type: 'suggestion:updated', suggestion: view });
    return { ok: true };
  };

  app.post('/api/suggestions/:id/implement', async (req, reply) => {
    if (!runner) return reply.code(503).send({ error: 'Runner ist deaktiviert' });
    const id = intParam(req);
    if (id === null) return reply.code(404).send({ error: 'Vorschlag nicht gefunden' });
    const body = (req.body ?? {}) as { extraInstructions?: string };
    const started = startRun(id, body.extraInstructions ?? '');
    if (!started.ok) {
      const code = started.error?.includes('gibt es nicht') ? 404 : 409;
      return reply.code(code).send({ error: started.error });
    }
    return { run: started.run, suggestion: started.view };
  });

  /**
   * The task composer: the operator writes an order into the dashboard and it
   * goes straight into the queue — no suggestion to approve first, no vote, no
   * Discord post. It is still a *suggestion* row on purpose: the runner, the
   * scope prediction, the retry policy, the commit guard and the history all
   * work on suggestions, and a second parallel kind of order would mean a
   * second copy of every one of them.
   *
   * The trade-off is deliberate: an operator order is not a player complaint, so
   * it never reaches Discord, and it is created `approved` because the operator
   * asking for it is the approval.
   */
  app.post('/api/tasks', async (req, reply) => {
    if (!runner) return reply.code(503).send({ error: 'Runner ist deaktiviert' });
    const body = (req.body ?? {}) as { text?: string; extraInstructions?: string };
    const result = await createTask(body.text ?? '', body.extraInstructions ?? '');
    if (!result.ok) {
      const code = /abschaltet/.test(result.error ?? '') ? 503 : 400;
      return reply.code(code).send({ error: result.error });
    }
    const id = result.suggestionId!;
    return {
      run: result.runId ? store.getRun(result.runId) : null,
      suggestion: viewOf(id),
      scope: runner.auditScopeOf(result.runId!),
    };
  });

  // Preview: which sub-tasks would an automatic split produce?
  app.get('/api/suggestions/:id/split', async (req, reply) => {
    const id = intParam(req);
    if (id === null) return reply.code(404).send({ error: 'Vorschlag nicht gefunden' });
    const suggestion = store.getSuggestion(id);
    if (!suggestion) return reply.code(404).send({ error: 'Vorschlag nicht gefunden' });
    return { suggestion: viewOf(id)!, tasks: splitIntoTasks(suggestion.text) };
  });

  // Turn one suggestion into several independent sub-tasks so each one can be
  // implemented (and run) separately.
  app.post('/api/suggestions/:id/split', async (req, reply) => {
    const id = intParam(req);
    if (id === null) return reply.code(404).send({ error: 'Vorschlag nicht gefunden' });
    const suggestion = store.getSuggestion(id);
    if (!suggestion) return reply.code(404).send({ error: 'Vorschlag nicht gefunden' });
    if (runner?.isBusyForSuggestion(suggestion)) {
      return reply.code(409).send({ error: 'Für diesen Vorschlag läuft bereits ein Run.' });
    }
    const body = (req.body ?? {}) as { tasks?: unknown };
    let tasks: string[];
    if (body.tasks !== undefined) {
      const normalized = normalizeTasks(body.tasks);
      if (normalized.error || !normalized.tasks) {
        return reply.code(400).send({ error: normalized.error ?? 'Ungültige Einzelaufträge.' });
      }
      tasks = normalized.tasks;
    } else {
      tasks = splitIntoTasks(suggestion.text);
    }
    if (tasks.length < 2) {
      return reply.code(400).send({
        error: 'Es wurden keine sinnvollen Einzelaufträge erkannt — bitte den Vorschlag manuell aufteilen.',
      });
    }
    // Splitting is not idempotent by itself: the same parent split twice would
    // create a second copy of every child and therefore a second copy of the
    // work. Children that already exist are reported instead of recreated, so a
    // double-click adds nothing.
    const existingChildren = store
      .listSuggestions()
      .filter((s) => s.parentId === suggestion.id)
      .map((s) => s.text);
    const plan = planSplit(existingChildren, tasks);
    if (plan.repeated) {
      return reply.code(409).send({ error: splitRepeatError(plan) });
    }
    const status: SuggestionStatus =
      suggestion.status === 'approved' || suggestion.status === 'implementing' ? 'approved' : 'new';
    const created = plan.fresh.map((task) =>
      store.createSuggestion({
        text: task,
        author: suggestion.author,
        source: 'dashboard',
        category: classify(task),
        canonicalId: null,
        status,
        parentId: suggestion.id,
      }),
    );
    const views = created.map((c) => viewOf(c.id)!);
    for (const view of views) emit({ type: 'suggestion:new', suggestion: view });
    return { parent: viewOf(id)!, created: views, existing: plan.existing.length };
  });

  app.post('/api/runs/:id/cancel', async (req, reply) => {
    if (!runner) return reply.code(503).send({ error: 'Runner ist deaktiviert' });
    const id = (req.params as { id: string }).id;
    const result = runner.cancel(id);
    if (!result.ok) return reply.code(400).send({ error: result.error });
    return { ok: true };
  });

  app.get('/api/runs', async () => ({ runs: store.listRuns(100) }));

  app.get('/api/runs/:id', async (req, reply) => {
    if (!runner) return reply.code(503).send({ error: 'Runner ist deaktiviert' });
    const id = (req.params as { id: string }).id;
    const view = runner.getRunView(id);
    if (!view) return reply.code(404).send({ error: 'Run nicht gefunden' });
    return view;
  });

  // Cleans up runs whose opencode process is gone (e.g. after a crash or a
  // restart) without requiring a server restart.
  app.post('/api/runs/reconcile', async () => {
    if (!runner) return { fixed: [] };
    const fixed = runner.reconcileNow();
    for (const run of fixed) {
      emit({ type: 'run:finished', run });
      const view = viewOf(run.suggestionId);
      if (view) emit({ type: 'suggestion:updated', suggestion: view });
    }
    return { fixed };
  });

  // Queue control: what the operator needs to steer the runner, and what the
  // dashboard needs to draw the panel. Works with a disabled runner too, so the
  // page has one shape to render.
  app.get('/api/runner', async () => {
    if (!runner) {
      const settings = store.getSettings();
      return {
        runnerEnabled: false,
        paused: false,
        activeRun: null,
        activeRuns: [] as RunRecord[],
        queue: [] as RunRecord[],
        blockedRunIds: [] as string[],
        policy: {
          timeoutMinutes: settings.runTimeoutMinutes,
          retryLimit: settings.retryLimit,
          retryBackoffSeconds: settings.retryBackoffSeconds,
          maxParallelRuns: settings.maxParallelRuns,
        },
      };
    }
    return { runnerEnabled: true, ...runner.queueState() };
  });

  app.post('/api/runner/pause', async (req, reply) => {
    if (!runner) return reply.code(503).send({ error: 'Runner ist deaktiviert' });
    const body = (req.body ?? {}) as { paused?: unknown };
    if (typeof body.paused !== 'boolean') {
      return reply.code(400).send({ error: 'paused muss true oder false sein' });
    }
    const paused = runner.setPaused(body.paused);
    return { ...runner.queueState(), paused };
  });

  // --- backup in the repository ---------------------------------------------
  //
  // The database under data/ is gitignored, so the dashboard's whole memory —
  // every suggestion, decision, vote and run — would be lost with it. These
  // three routes keep a committed JSON copy in sync: one to write it, one to read
  // it back, one to ask what the difference currently is. Merging is a merge and
  // not a restore (see server/backup.ts), so reading the file can never undo a
  // decision made here.
  app.get('/api/backup', async () => {
    const status = backupStatus(store, options.projectRoot);
    return { ...status, headline: describeBackup(status) };
  });

  app.post('/api/backup/write', async () => {
    const path = backupPath(options.projectRoot);
    const snapshot = buildSnapshot(store, options.projectRoot);
    try {
      writeSnapshotFile(path, snapshot);
    } catch (err) {
      return { ok: false, error: `Backup konnte nicht geschrieben werden: ${(err as Error).message}` };
    }
    const status = backupStatus(store, options.projectRoot);
    return { ok: true, path: status.path, counts: snapshot.counts, headline: describeBackup(status) };
  });

  app.post('/api/backup/read', async (req, reply) => {
    const path = backupPath(options.projectRoot);
    let snapshot;
    try {
      snapshot = readSnapshotFile(path);
    } catch (err) {
      return reply.code(400).send({ error: (err as Error).message });
    }
    if (!snapshot) {
      return reply.code(404).send({
        error: `Keine Backup-Datei gefunden (${backupStatus(store, options.projectRoot).path}).`,
      });
    }
    const report = mergeSnapshot(store, snapshot, { projectRoot: options.projectRoot });
    // A restored suggestion is news to every open dashboard, exactly like one
    // that arrives from the game — and only for the rows that really changed.
    for (const id of [...report.suggestionIdsAdded, ...report.suggestionIdsUpdated]) {
      const view = viewOf(id);
      if (view) emit({ type: 'suggestion:updated', suggestion: view });
    }
    const status = backupStatus(store, options.projectRoot);
    return { ok: true, report, headline: describeBackup(status), path: status.path };
  });

  // --- deployed-version check queue -----------------------------------------
  //
  // A second queue next to the suggestion runner. Separate routes, separate
  // pause, separate table: an operator can stop handing out work without losing
  // the list of what is broken on the phone.
  app.get('/api/checks/catalogue', async () => ({ specs: CHECK_SPECS }));

  app.get('/api/checks', async () => ({
    ...checkRunner.queueState(),
    recent: store.listChecks(50),
  }));

  app.post('/api/checks', async (req, reply) => {
    const body = (req.body ?? {}) as { specId?: unknown };
    if (typeof body.specId !== 'string' || body.specId.trim() === '') {
      return reply.code(400).send({ error: 'specId muss eine Prüfungs-ID sein' });
    }
    const result = checkRunner.enqueue(body.specId.trim());
    if (result.error) return reply.code(400).send({ error: result.error });
    emit({ type: 'check:queue', state: checkRunner.queueState() });
    // 202, not 200: the record is queued, the scan has not run yet.
    return reply.code(202).send({ check: result.check });
  });

  app.get('/api/checks/:id', async (req, reply) => {
    const id = (req.params as { id: string }).id;
    const check = store.getCheck(id);
    if (!check) return reply.code(404).send({ error: 'Prüfung nicht gefunden' });
    return { check, spec: CHECKS_BY_ID.get(check.specId) ?? null };
  });

  app.post('/api/checks/:id/cancel', async (req, reply) => {
    const id = (req.params as { id: string }).id;
    const result = checkRunner.cancel(id);
    if (!result.ok) {
      const status = /nicht gefunden/.test(result.error ?? '') ? 404 : 409;
      return reply.code(status).send({ error: result.error });
    }
    emit({ type: 'check:queue', state: checkRunner.queueState() });
    return { ok: true };
  });

  /**
   * Turns a finding into a suggestion, so a check that found something can
   * actually become somebody's task instead of a line in a report.
   */
  app.post('/api/checks/:id/promote', async (req, reply) => {
    const id = (req.params as { id: string }).id;
    const result = checkRunner.promote(id);
    if (result.error) return reply.code(409).send({ error: result.error });
    const suggestionId = result.suggestionId!;
    // Same treatment as a suggestion from the game: Discord hears about it, so
    // a promoted finding is not a second-class entry in the queue.
    const webhook = store.getSettings().discordWebhook || process.env.DISCORD_WEBHOOK_URL || '';
    if (webhook) {
      const sent = await discord.notifyNewSuggestion(viewOf(suggestionId)!, webhook, dashboardUrl);
      if (sent.ok && sent.messageId) store.setSuggestionDiscordMessage(suggestionId, sent.messageId);
    }
    if (telegram.isConfigured()) {
      const sent = await telegram.notifyNewSuggestion(viewOf(suggestionId)!, dashboardUrl);
      if (!sent.ok) console.warn('[telegram] Befund nicht zugestellt:', sent.error);
      else if (sent.messageId) store.setSuggestionTelegramMessage(suggestionId, sent.messageId);
    }
    const view = viewOf(suggestionId);
    if (view) emit({ type: 'suggestion:new', suggestion: view });
    return { suggestionId, suggestion: view };
  });

  app.post('/api/checks/pause', async (req, reply) => {
    const body = (req.body ?? {}) as { paused?: unknown };
    if (typeof body.paused !== 'boolean') {
      return reply.code(400).send({ error: 'paused muss true oder false sein' });
    }
    const paused = checkRunner.setPaused(body.paused);
    emit({ type: 'check:queue', state: checkRunner.queueState() });
    return { ...checkRunner.queueState(), paused };
  });

  // The scope layout the runner depends on. Read straight from the manifest, so
  // the dashboard can never disagree with `scopes.mjs check`.
  app.get('/api/scopes', async () => scopeManifest());

  // Which scope(s) a suggestion maps to, before anything is started.
  app.get('/api/suggestions/:id/scope', async (req, reply) => {
    const id = intParam(req);
    if (id === null) return reply.code(404).send({ error: 'Vorschlag nicht gefunden' });
    const suggestion = store.getSuggestion(id);
    if (!suggestion) return reply.code(404).send({ error: 'Vorschlag nicht gefunden' });
    const all = store.listSuggestions();
    const canonical = suggestion.canonicalId ?? suggestion.id;
    const cluster = all.filter((s) => (s.canonicalId ?? s.id) === canonical);
    return { suggestion: viewOf(id)!, scope: scopeForSuggestion(suggestion, cluster) };
  });

  // What a run actually touched compared to the scope it declared.
  app.get('/api/runs/:id/scope', async (req, reply) => {
    if (!runner) return reply.code(503).send({ error: 'Runner ist deaktiviert' });
    const id = (req.params as { id: string }).id;
    const audit = runner.auditScopeOf(id);
    if (!audit) return reply.code(404).send({ error: 'Run nicht gefunden' });
    return audit;
  });

  // Manual retry. The automatic one follows the policy in the settings; this is
  // for the case where an operator looks at a failed run and disagrees.
  app.post('/api/runs/:id/retry', async (req, reply) => {
    if (!runner) return reply.code(503).send({ error: 'Runner ist deaktiviert' });
    const id = (req.params as { id: string }).id;
    const body = (req.body ?? {}) as { force?: unknown };
    const result = runner.retry(id, { force: body.force === true });
    if (!result.ok) {
      const status = /nicht gefunden/.test(result.error ?? '') ? 404 : 409;
      return reply.code(status).send({ error: result.error });
    }
    const run = result.run!;
    const view = viewOf(run.suggestionId);
    if (view) emit({ type: 'suggestion:updated', suggestion: view });
    return { ok: true, run };
  });

  app.get('/api/settings', async () => {
    const settings = store.getSettings();
    const token = (process.env.TELEGRAM_BOT_TOKEN ?? '').trim();
    const chat = (process.env.TELEGRAM_CHAT_ID ?? '').trim();
    return {
      ...settings,
      discordWebhook: maskWebhook(settings.discordWebhook || process.env.DISCORD_WEBHOOK_URL || ''),
      webhookConfigured: Boolean(settings.discordWebhook || process.env.DISCORD_WEBHOOK_URL),
      envWebhook: Boolean(process.env.DISCORD_WEBHOOK_URL && !settings.discordWebhook),
      // Yes/no and the reason only. The token itself does not go over the wire:
      // `/api/settings` is exactly the answer a screen needs to display, and
      // nothing more.
      telegramConfigured: Boolean(token && chat),
      telegramTokenSet: Boolean(token),
      telegramChatSet: Boolean(chat),
    };
  });

  app.put('/api/settings', async (req, reply) => {
    const body = (req.body ?? {}) as Record<string, unknown>;
    const patch: Record<string, string | boolean | number> = {};
    if (typeof body.discordWebhook === 'string') {
      const webhook = body.discordWebhook.trim();
      // Checked here and not only when the webhook is used: a stored webhook is
      // a URL this server posts to on every new suggestion. An empty string
      // still means "clear it", everything else has to be a Discord host —
      // through the very same helper `postWebhook` uses, so nothing can be saved
      // that would be refused later and nothing outside Discord can be stored.
      if (webhook !== '') {
        const check = discord.checkWebhook(webhook);
        if (!check.ok) return reply.code(400).send({ error: check.error });
      }
      patch.discordWebhook = webhook;
    }
    if (typeof body.model === 'string') patch.model = body.model.trim();
    if (typeof body.extraInstructions === 'string') patch.extraInstructions = body.extraInstructions;
    if (typeof body.autoApprove === 'boolean') patch.autoApprove = body.autoApprove;
    if (typeof body.autoApproveScore === 'number') patch.autoApproveScore = body.autoApproveScore;
    // Runner policy. The store clamps these to its bounds, so a typo cannot
    // disable the timeout or ask for a thousand retries.
    for (const key of ['runTimeoutMinutes', 'retryLimit', 'retryBackoffSeconds', 'maxParallelRuns'] as const) {
      const value = body[key];
      if (typeof value === 'number' && Number.isFinite(value)) patch[key] = value;
      else if (typeof value === 'string' && value.trim() !== '' && Number.isFinite(Number(value))) {
        patch[key] = Number(value);
      }
    }
    const settings = store.saveSettings(patch);
    return {
      ...settings,
      discordWebhook: maskWebhook(settings.discordWebhook),
      webhookConfigured: Boolean(settings.discordWebhook || process.env.DISCORD_WEBHOOK_URL),
    };
  });

  app.post('/api/discord/test', async (req, reply) => {
    const body = (req.body ?? {}) as { webhook?: string };
    const webhook = (body.webhook ?? '').trim() || store.getSettings().discordWebhook || process.env.DISCORD_WEBHOOK_URL || '';
    if (!webhook) return reply.code(400).send({ error: 'Kein Webhook konfiguriert' });
    // The address comes from the request body, so it is refused here for what it
    // is — a bad URL is the caller's mistake (400), not Discord's answer (502).
    // `postWebhook` checks the same thing again; two checks on purpose, one
    // readable error for the dashboard and no way around the gate in between.
    const check = discord.checkWebhook(webhook);
    if (!check.ok) return reply.code(400).send({ error: check.error });
    const result = await discord.sendTest(webhook, dashboardUrl);
    if (!result.ok) return reply.code(502).send({ error: result.error });
    return { ok: true };
  });

  // The Telegram test button. Configuration comes from the environment, not the
  // request: a token the client sends along ends up in the server log the moment
  // anything goes sideways.
  app.post('/api/telegram/test', async (_req, reply) => {
    if (!telegram.isConfigured()) {
      return reply
        .code(400)
        .send({ error: 'Kein Telegram konfiguriert: TELEGRAM_BOT_TOKEN und TELEGRAM_CHAT_ID in der .env setzen' });
    }
    const result = await telegram.sendTest(dashboardUrl);
    if (!result.ok) return reply.code(502).send({ error: result.error });
    return { ok: true };
  });

  app.get('/api/content', async () => content.load());

  app.post('/api/content/reload', async () => {
    content.load(true);
    emit({ type: 'content:reloaded' });
    return content.load(true);
  });

  app.get('/api/stats', async () => {
    const all = store.listSuggestions();
    const views = decorateAll(all, Date.now());
    return { stats: statsOf(views), runs: store.listRuns(5) };
  });

  app.get('/api/events', (req, reply) => {
    // The same CORS decision as the `onSend` hook, which this route bypasses: it
    // writes its own head and therefore never passes through it.
    const origin = corsOrigin(req);
    const headers: Record<string, string> = {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    };
    if (origin) headers['Access-Control-Allow-Origin'] = origin;
    reply.raw.writeHead(200, headers);
    reply.raw.write(': connected\n\n');
    const listener = (event: BusEvent) => {
      reply.raw.write(`data: ${JSON.stringify(event)}\n\n`);
    };
    bus.on('event', listener);
    const ping = setInterval(() => reply.raw.write(': ping\n\n'), 15000);
    req.raw.on('close', () => {
      clearInterval(ping);
      bus.off('event', listener);
    });
  });

  if (existsSync(options.distDir)) {
    app.register(fastifyStatic, { root: options.distDir, prefix: '/' });
  } else {
    app.get('/', async (_req, reply) =>
      reply
        .type('text/plain')
        .send('Dev-Modus: Dashboard unter http://localhost:5173 (Vite). API läuft hier.'),
    );
  }

  // The Telegram bot only runs when a token is set. Without one nothing happens
  // here — a game that works without chat control must not hang on an empty bot.
  const bot = new TelegramBot({
    projectRoot: options.projectRoot,
    store,
    runner: runner ?? null,
    bus,
    dashboardUrl,
    viewOf,
    startRun: (id) => startRun(id),
    createTask: (text) => createTask(text),
    setStatus: (id, status) => setStatus(id, status),
    onError: (err) => console.warn('[telegram]', err.message),
  });
  bot.start();

  app.addHook('onClose', async () => {
    // Only the timers: a run that is still going must survive the server, that
    // is what the PID registry and the adoption in `recover()` are for.
    runner?.dispose();
    await bot.stop();
  });

  app.setErrorHandler((error: Error & { statusCode?: number }, _req, reply) => {
    reply.code(error.statusCode ?? 500).send({ error: error.message });
  });

  (app as FastifyInstance & { _singular80?: unknown })._singular80 = { store, content, runner, bus, bot };
  return app;
}

function statsOf(views: SuggestionView[]) {
  const byStatus: Record<string, number> = {};
  for (const v of views) byStatus[v.status] = (byStatus[v.status] ?? 0) + 1;
  return {
    total: views.length,
    votes: views.reduce((sum, v) => sum + v.votes, 0),
    implemented: byStatus.implemented ?? 0,
    clusters: new Set(views.map((v) => v.canonicalId ?? v.id)).size,
    byStatus,
  };
}

/**
 * A route parameter as a suggestion number, or `null`.
 *
 * `Number('abc')` is `NaN`, and a `NaN` used as a key never matches a row: the
 * request therefore fell through to a 404 whose text mentioned `NaN` on some
 * routes and to a German error about a missing suggestion on others. Digits
 * only, so anything else is simply "no such suggestion".
 */
function intParam(req: FastifyRequest, key = 'id'): number | null {
  const raw = (req.params as Record<string, string | undefined>)[key] ?? '';
  if (!/^\d+$/.test(raw)) return null;
  const value = Number(raw);
  return Number.isSafeInteger(value) ? value : null;
}

function maskWebhook(url: string): string {
  if (!url) return '';
  try {
    const parsed = new URL(url);
    const parts = parsed.pathname.split('/');
    const last = parts[parts.length - 1] ?? '';
    parts[parts.length - 1] = last.length > 4 ? `${last.slice(0, 3)}…${last.slice(-3)}` : '***';
    parsed.pathname = parts.join('/');
    return parsed.toString();
  } catch {
    return url.slice(0, 12) + '…';
  }
}
