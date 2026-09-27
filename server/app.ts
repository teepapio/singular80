import { EventEmitter } from 'node:events';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import Fastify, { type FastifyInstance } from 'fastify';
import fastifyStatic from '@fastify/static';
import type { BusEvent, RunRecord, Suggestion, SuggestionStatus, SuggestionView } from '../src/shared/types';
import { OPERATOR_SOURCE } from '../src/shared/types';
import { classify, decorate, findCanonical, scoreSuggestion, sortSuggestions, type SortMode } from '../src/shared/sorting';
import { ContentStore } from './content';
import { Store } from './db';
import * as discord from './discord';
import * as telegram from './telegram';
import { TelegramBot } from './telegramBot';
import { findOpencodeBinary, Runner } from './runner';
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
import { normalizeTasks, splitIntoTasks } from './split';

export interface AppOptions {
  dataDir: string;
  contentDir: string;
  projectRoot: string;
  distDir: string;
  dashboardUrl?: string;
  runnerEnabled?: boolean;
}

// Die Hauptseite ist das Dashboard; `/dashboard.html` leitet nur noch um.
const DASHBOARD_URL = process.env.DASHBOARD_URL || 'http://localhost:5173/';

export function createApp(options: AppOptions): FastifyInstance {
  const app = Fastify({ logger: false, bodyLimit: 1024 * 256 });
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
              void discord.notifyRunResult(suggestion, run, webhook, dashboardUrl);
            }
            // Telegram läuft unabhängig vom Webhook: wer Discord nicht hat,
            // bekommt das Ergebnis trotzdem. Der Fehler landet bewusst nur im
            // Log — ein kaputter Kanal darf keinen Run als fehlgeschlagen
            // melden, der Erfolg hängt an `run.status`, nicht an der Zustellung.
            if (suggestion && telegram.isConfigured()) {
              void telegram
                .notifyRunResult(suggestion, run, dashboardUrl)
                .then((sent) => {
                  if (!sent.ok) console.warn('[telegram] Run-Ergebnis nicht zugestellt:', sent.error);
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
    callbacks: {
      onStarted: (check) => emit({ type: 'check:started', check }),
      onFinished: (check) => emit({ type: 'check:finished', check }),
      onQueueState: (state) => emit({ type: 'check:queue', state }),
    },
  });

  app.addHook('onSend', async (_req, reply, payload) => {
    reply.header('Access-Control-Allow-Origin', '*');
    reply.header('Access-Control-Allow-Headers', 'Content-Type');
    reply.header('Access-Control-Allow-Methods', 'GET,POST,PATCH,PUT,OPTIONS');
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
    let views = all.map((s) => {
      const v = decorate(s, all, Date.now());
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
    const id = Number((req.params as { id: string }).id);
    const view = viewOf(id);
    if (!view) return reply.code(404).send({ error: 'Vorschlag nicht gefunden' });
    const runs = runner?.listSuggestionRuns(id) ?? store.listRuns(200).filter((r) => r.suggestionId === id);
    return { suggestion: view, runs };
  });

  app.post('/api/suggestions', async (req, reply) => {
    const body = (req.body ?? {}) as { text?: string; author?: string; source?: string; clientKey?: unknown };
    const text = (body.text ?? '').trim();
    if (text.length < 3 || text.length > 2000) {
      return reply.code(400).send({ error: 'Der Vorschlag muss zwischen 3 und 2000 Zeichen lang sein.' });
    }
    const author = (body.author ?? '').trim().slice(0, 60) || 'Anonym';
    const source = body.source === 'dashboard' ? 'dashboard' : 'game';
    const existing = store.listSuggestions();
    const candidates = existing.filter((s) => s.status !== 'rejected');
    const canon = findCanonical(text, candidates);
    const category = classify(text);
    const settings = store.getSettings();
    // The store decides whether this is a new row or a replay: a lost response
    // makes the client send the same `clientKey` again, and only the unique
    // index can tell a retry from a genuine second suggestion.
    const { suggestion, created } = store.createSuggestionOnce({
      text,
      author,
      source,
      category,
      canonicalId: canon?.canonicalId ?? null,
      status: 'new',
      clientKey: body.clientKey,
    });
    if (!created) {
      // Replay: no row, no Discord post, no event. The client gets the current
      // state of its suggestion in the same shape as the first answer, and the
      // header makes the replay visible to the dashboard and to tests without
      // adding a field the client would have to know.
      return reply.header('X-Suggestion-Replay', '1').send(viewOf(suggestion.id)!);
    }
    if (settings.autoApprove) {
      const clusterSize = canon ? canon.clusterIds.length + 1 : 1;
      const { score } = scoreSuggestion(suggestion, Date.now(), clusterSize);
      if (score >= settings.autoApproveScore) {
        store.updateSuggestionStatus(suggestion.id, 'approved');
      }
    }
    let view = viewOf(suggestion.id)!;
    const webhook = settings.discordWebhook || process.env.DISCORD_WEBHOOK_URL || '';
    if (webhook) {
      const result = await discord.notifyNewSuggestion(view, webhook, dashboardUrl);
      if (result.ok && result.messageId) {
        store.setSuggestionDiscordMessage(suggestion.id, result.messageId);
        view = viewOf(suggestion.id)!;
      }
    }
    // Ein Kanal ist optional und der andere genügt: die Einreichung ist zu
    // diesem Zeitpunkt bereits in der Datenbank, also kostet ein Fehler hier
    // nichts als eine Logzeile.
    if (telegram.isConfigured()) {
      const sent = await telegram.notifyNewSuggestion(view, dashboardUrl);
      if (!sent.ok) console.warn('[telegram] Vorschlag nicht zugestellt:', sent.error);
    }
    emit({ type: 'suggestion:new', suggestion: view });
    return view;
  });

  app.post('/api/suggestions/:id/vote', async (req, reply) => {
    const id = Number((req.params as { id: string }).id);
    const body = (req.body ?? {}) as { voterId?: string };
    const voterId = (body.voterId ?? '').trim();
    if (!store.getSuggestion(id)) return reply.code(404).send({ error: 'Vorschlag nicht gefunden' });
    if (voterId.length < 6) return reply.code(400).send({ error: 'voterId fehlt' });
    store.addVote(id, voterId.slice(0, 64));
    const view = viewOf(id)!;
    emit({ type: 'suggestion:vote', suggestion: view });
    return { votes: view.votes, changed: true };
  });

  app.patch('/api/suggestions/:id', async (req, reply) => {
    const id = Number((req.params as { id: string }).id);
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
   * Startet einen Lauf für einen bestehenden Vorschlag.
   *
   * Das ist die **eine** Stelle, die das tut. Der HTTP-Knopf und der
   * Telegram-Befehl `/run` gehen beide hierher; zwei Kopien wären zwei Stellen,
   * an denen sich Dashboard und Chat stillschweigend unterscheiden — und der
   * Unterschied fällt erst auf, wenn ein Lauf im einen Weg startet und im
   * anderen nicht.
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
   * Status setzen und beide Enden informieren. Auch das hat nur eine Quelle,
   * damit der Chat keine eigene Wahrheit bekommt.
   */
  const setStatus = (id: number, status: SuggestionStatus): { ok: boolean; error?: string } => {
    const updated = store.updateSuggestionStatus(id, status);
    if (!updated) return { ok: false, error: `Vorschlag #${id} gibt es nicht.` };
    const view = viewOf(id)!;
    const webhook = store.getSettings().discordWebhook || process.env.DISCORD_WEBHOOK_URL || '';
    if (webhook && view.discordMessageId) {
      void discord.updateSuggestionMessage(view, webhook, dashboardUrl);
    }
    if (telegram.isConfigured()) {
      const sent = telegram.sendMessage(
        `${status === 'approved' ? '👍' : status === 'rejected' ? '❌' : 'ℹ️'} #${id} ist jetzt <b>${status}</b>\n${dashboardUrl}#suggestion-${id}`,
      );
      void sent.then((r) => {
        if (!r.ok) console.warn('[telegram] Statuswechsel nicht zugestellt:', r.error);
      });
    }
    emit({ type: 'suggestion:updated', suggestion: view });
    return { ok: true };
  };

  app.post('/api/suggestions/:id/implement', async (req, reply) => {
    if (!runner) return reply.code(503).send({ error: 'Runner ist deaktiviert' });
    const id = Number((req.params as { id: string }).id);
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
    const text = (body.text ?? '').trim();
    if (text.length < 3) {
      return reply.code(400).send({ error: 'Der Auftrag braucht mindestens 3 Zeichen.' });
    }
    if (text.length > 4000) {
      return reply.code(400).send({ error: 'Der Auftrag ist länger als 4000 Zeichen — bitte kürzen.' });
    }
    const settings = store.getSettings();
    const merged = { ...settings };
    const extra = (body.extraInstructions ?? '').trim();
    if (extra) merged.extraInstructions = [settings.extraInstructions, extra].filter(Boolean).join('\n');
    const suggestion = store.createSuggestion({
      text,
      author: 'Betreiber',
      source: OPERATOR_SOURCE,
      category: classify(text),
      canonicalId: null,
      status: 'approved',
    });
    const run = runner.enqueue(suggestion, merged, [suggestion]);
    const view = viewOf(suggestion.id)!;
    emit({ type: 'suggestion:new', suggestion: view });
    return { run, suggestion: view, scope: runner.auditScopeOf(run.id) };
  });

  // Preview: which sub-tasks would an automatic split produce?
  app.get('/api/suggestions/:id/split', async (req, reply) => {
    const id = Number((req.params as { id: string }).id);
    const suggestion = store.getSuggestion(id);
    if (!suggestion) return reply.code(404).send({ error: 'Vorschlag nicht gefunden' });
    return { suggestion: viewOf(id)!, tasks: splitIntoTasks(suggestion.text) };
  });

  // Turn one suggestion into several independent sub-tasks so each one can be
  // implemented (and run) separately.
  app.post('/api/suggestions/:id/split', async (req, reply) => {
    const id = Number((req.params as { id: string }).id);
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
    const status: SuggestionStatus =
      suggestion.status === 'approved' || suggestion.status === 'implementing' ? 'approved' : 'new';
    const created = tasks.map((task) =>
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
    return { parent: viewOf(id)!, created: views };
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
    return { check: result.check };
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
    const id = Number((req.params as { id: string }).id);
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
    return {
      ...settings,
      discordWebhook: maskWebhook(settings.discordWebhook || process.env.DISCORD_WEBHOOK_URL || ''),
      webhookConfigured: Boolean(settings.discordWebhook || process.env.DISCORD_WEBHOOK_URL),
      envWebhook: Boolean(process.env.DISCORD_WEBHOOK_URL && !settings.discordWebhook),
    };
  });

  app.put('/api/settings', async (req) => {
    const body = (req.body ?? {}) as Record<string, unknown>;
    const patch: Record<string, string | boolean | number> = {};
    if (typeof body.discordWebhook === 'string') patch.discordWebhook = body.discordWebhook.trim();
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
    const result = await discord.sendTest(webhook, dashboardUrl);
    if (!result.ok) return reply.code(502).send({ error: result.error });
    return { ok: true };
  });

  // Der Testknopf für Telegram. Die Konfiguration kommt aus der Umgebung und
  // nicht aus dem Request: ein Token, den der Client mitschickt, landet im
  // Serverlog, sobald sich etwas verwirrt.
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
    const views = all.map((s) => decorate(s, all, Date.now()));
    return { stats: statsOf(views), runs: store.listRuns(5) };
  });

  app.get('/api/events', (req, reply) => {
    reply.raw.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      'Access-Control-Allow-Origin': '*',
      'X-Accel-Buffering': 'no',
    });
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

  // Der Telegram-Bot läuft nur, wenn ein Token hinterlegt ist. Ohne Token
  // passiert hier nichts — ein Spielstand ohne Chatbedienung soll nicht an
  // einem leeren Bot hängen.
  const bot = new TelegramBot({
    store,
    runner: runner ?? null,
    bus,
    dashboardUrl,
    viewOf,
    startRun: (id) => startRun(id),
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
