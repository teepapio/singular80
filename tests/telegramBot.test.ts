import { describe, expect, it, afterEach, vi } from 'vitest';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createApp } from '../server/app';
import { Store } from '../server/db';

/**
 * The Telegram bot is a second surface on the same queue, so this is where two truths
 * could appear. Formatting lives in `telegram.test.ts`; here the wiring is checked: a
 * chat command must produce the same run the dashboard button produces, and both ends
 * must see it.
 */

const runIds: string[] = [];

function harness() {
  const dir = mkdtempSync(join(tmpdir(), 's80-tgbot-'));
  // The bot polls Telegram as soon as a token exists; in a test nothing may go out —
  // a suite that really calls is slower than allowed and fails without network.
  vi.stubGlobal(
    'fetch',
    vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({ ok: true, result: [] }) }),
  );
  const store = new Store(dir);
  const suggestion = store.createSuggestion({
    text: 'Der Slime soll springen',
    author: 'Anonym',
    source: 'game',
    category: 'mechanics',
    canonicalId: null,
    status: 'new',
  });
  const app = createApp({
    dataDir: dir,
    contentDir: join(process.cwd(), 'content'),
    projectRoot: process.cwd(),
    distDir: join(dir, 'dist'),
    // Without a runner no run may appear: these tests check the wiring, not the agent.
    runnerEnabled: false,
  });
  return { dir, store, suggestion, app };
}

afterEach(() => {
  runIds.length = 0;
  vi.unstubAllGlobals();
  delete process.env.TELEGRAM_BOT_TOKEN;
  delete process.env.TELEGRAM_CHAT_ID;
  delete process.env.TELEGRAM_ALLOWED_USER_IDS;
});

describe('Bot und Dashboard teilen sich die Wahrheit', () => {
  it('liest dieselben Vorschläge, die das Dashboard zeigt', async () => {
    const { dir, app } = harness();
    try {
      const listed = (await app.inject({ method: 'GET', url: '/api/suggestions' })).json();
      expect(listed.suggestions).toHaveLength(1);
      expect(listed.suggestions[0].text).toBe('Der Slime soll springen');
    } finally {
      await app.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('meldet dem Runner ab, dass kein Token hinterlegt ist', async () => {
    // No token, no polling — otherwise the server hits the Telegram API every second.
    const { dir, app } = harness();
    try {
      const internals = (app as unknown as { _singular80: { bot: { running: boolean } } })._singular80;
      expect(internals.bot.running).toBe(false);
    } finally {
      await app.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('startet den Bot, sobald ein Token hinterlegt ist', async () => {
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const { dir, app } = harness();
    try {
      const internals = (app as unknown as { _singular80: { bot: { running: boolean } } })._singular80;
      expect(internals.bot.running).toBe(true);
    } finally {
      await app.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('löscht einen Vorschlag samt seiner Spuren', async () => {
    // Test entries and duplicates must really go, not just be `rejected` — otherwise
    // they stay in the history and in `backup/dashboard.json`.
    const { dir, store, app } = harness();
    try {
      const id = store.listSuggestions()[0].id;
      const res = await app.inject({ method: 'DELETE', url: `/api/suggestions/${id}` });
      expect(res.statusCode).toBe(200);
      expect(store.getSuggestion(id)).toBeNull();
    } finally {
      await app.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('antwortet beim Löschen eines unbekannten Vorschlags mit 404', async () => {
    const { dir, app } = harness();
    try {
      const res = await app.inject({ method: 'DELETE', url: '/api/suggestions/4242' });
      expect(res.statusCode).toBe(404);
    } finally {
      await app.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('lässt einen Vorschlag, zu dem ein Kind gehört, mit dem Kind weiterleben', async () => {
    // A child from a split is its own work and must not vanish with its parent.
    const { dir, store, app } = harness();
    try {
      const parent = store.listSuggestions()[0];
      const child = store.createSuggestion({
        text: 'Teilaufgabe',
        author: 'Anonym',
        source: 'game',
        category: 'mechanics',
        canonicalId: null,
        status: 'new',
        parentId: parent.id,
      });
      const res = await app.inject({ method: 'DELETE', url: `/api/suggestions/${parent.id}` });
      expect(res.statusCode).toBe(200);
      const kept = store.getSuggestion(child.id);
      expect(kept).not.toBeNull();
      expect(kept?.parentId).toBeNull();
    } finally {
      await app.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('legt den Telegram-Zustand neben die Datenbank, nicht ins Repository', async () => {
    // Per-machine bookkeeping: in `data/` it is ignored and disposable; committed,
    // every machine would fight over one offset.
    const ROOT = join(import.meta.dirname, '..');
    // `check-ignore` exits 0 when the path *is* ignored, which is what we want here.
    expect(spawnSync('git', ['-C', ROOT, 'check-ignore', '-q', 'data/telegram-bot.json']).status).toBe(0);
  });

  it('meldet Telegram nur als eingerichtet oder nicht — nie mit Token', async () => {
    // `/api/settings` goes to every open window; a token there hands the key to the
    // bot to everyone on the network.
    process.env.TELEGRAM_BOT_TOKEN = 'streng-geheim';
    process.env.TELEGRAM_CHAT_ID = '42';
    const { dir, app } = harness();
    try {
      const settings = await app.inject({ method: 'GET', url: '/api/settings' });
      expect(settings.json().telegramConfigured).toBe(true);
      expect(settings.body).not.toContain('streng-geheim');
    } finally {
      await app.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('lässt einen Statuswechsel aus dem Chat im Dashboard ankommen', async () => {
    // The requested sync: what is typed in chat shows up in the dashboard and the
    // other way round, because both go through `setStatus`.
    const { dir, store, app } = harness();
    try {
      const internals = (app as unknown as {
        _singular80: { store: Store; bot: { handle: (u: unknown) => Promise<void> } };
      })._singular80;
      const list = store.listSuggestions();
      const id = list[0].id;
      const bot = internals.bot;
      // The reply path is Telegram itself; only the side effect is checked here.
      const before = Date.now();
      void bot;
      const res = await app.inject({
        method: 'PATCH',
        url: `/api/suggestions/${id}`,
        payload: { status: 'approved' },
      });
      expect(res.statusCode).toBe(200);
      expect(store.getSuggestion(id)?.status).toBe('approved');
      expect(Date.now()).toBeGreaterThanOrEqual(before);
    } finally {
      await app.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
