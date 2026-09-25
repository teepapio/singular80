import { EventEmitter } from 'node:events';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import Fastify, { type FastifyInstance } from 'fastify';
import fastifyStatic from '@fastify/static';
import type { BusEvent, Suggestion, SuggestionStatus, SuggestionView } from '../src/shared/types';
import { classify, decorate, findCanonical, scoreSuggestion, sortSuggestions, type SortMode } from '../src/shared/sorting';
import { ContentStore } from './content';
import { Store } from './db';
import * as discord from './discord';
import { findOpencodeBinary, Runner } from './runner';
import { normalizeTasks, splitIntoTasks } from './split';

export interface AppOptions {
  dataDir: string;
  contentDir: string;
  projectRoot: string;
  distDir: string;
  dashboardUrl?: string;
  runnerEnabled?: boolean;
}

const DASHBOARD_URL = process.env.DASHBOARD_URL || 'http://localhost:5173/dashboard.html';

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
          onFinished: (run) => {
            emit({ type: 'run:finished', run });
            const suggestion = store.getSuggestion(run.suggestionId);
            const view = viewOf(run.suggestionId);
            if (view) emit({ type: 'suggestion:updated', suggestion: view });
            const webhook = store.getSettings().discordWebhook || process.env.DISCORD_WEBHOOK_URL || '';
            if (suggestion && webhook) {
              void discord.notifyRunResult(suggestion, run, webhook, dashboardUrl);
            }
          },
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
    const body = (req.body ?? {}) as { text?: string; author?: string; source?: string };
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
    const suggestion = store.createSuggestion({
      text,
      author,
      source,
      category,
      canonicalId: canon?.canonicalId ?? null,
      status: 'new',
    });
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
    const updated = store.updateSuggestionStatus(id, body.status);
    if (!updated) return reply.code(404).send({ error: 'Vorschlag nicht gefunden' });
    const view = viewOf(id)!;
    const webhook = store.getSettings().discordWebhook || process.env.DISCORD_WEBHOOK_URL || '';
    if (webhook && view.discordMessageId) {
      await discord.updateSuggestionMessage(view, webhook, dashboardUrl);
    }
    emit({ type: 'suggestion:updated', suggestion: view });
    return view;
  });

  app.post('/api/suggestions/:id/implement', async (req, reply) => {
    if (!runner) return reply.code(503).send({ error: 'Runner ist deaktiviert' });
    const id = Number((req.params as { id: string }).id);
    const suggestion = store.getSuggestion(id);
    if (!suggestion) return reply.code(404).send({ error: 'Vorschlag nicht gefunden' });
    if (runner.isBusyForSuggestion(suggestion)) {
      return reply.code(409).send({ error: 'Für diesen Vorschlag läuft bereits ein Run.' });
    }
    const body = (req.body ?? {}) as { extraInstructions?: string };
    const settings = store.getSettings();
    const merged = { ...settings };
    const extra = (body.extraInstructions ?? '').trim();
    if (extra) merged.extraInstructions = [settings.extraInstructions, extra].filter(Boolean).join('\n');
    const all = store.listSuggestions();
    const canonical = suggestion.canonicalId ?? suggestion.id;
    const cluster = all.filter((s) => (s.canonicalId ?? s.id) === canonical);
    const run = runner.enqueue(suggestion, merged, cluster);
    const view = viewOf(id)!;
    emit({ type: 'suggestion:updated', suggestion: view });
    return { run, suggestion: view };
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
        .send('Dev-Modus: Spieldashboard unter http://localhost:5173 (Vite). API läuft hier.'),
    );
  }

  app.setErrorHandler((error: Error & { statusCode?: number }, _req, reply) => {
    reply.code(error.statusCode ?? 500).send({ error: error.message });
  });

  (app as FastifyInstance & { _singular80?: unknown })._singular80 = { store, content, runner, bus };
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
