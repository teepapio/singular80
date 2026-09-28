import { describe, expect, it, afterEach, vi } from 'vitest';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
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
/**
 * The repository root, derived from this file. `process.cwd()` would make the
 * suite depend on the directory it happened to be started from: from anywhere
 * else it would read a different `content/`, and a missing file would look like
 * a broken assertion rather than a wrong root.
 */
const ROOT = join(import.meta.dirname, '..');
let previousBin: string | undefined;

function harness(options: { runnerEnabled?: boolean } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 's80-tgbot-'));
  // The project root is a directory *inside* the temp dir, so one `rmSync` cleans
  // up database and repository together — and no run log can land in the real
  // working tree, which `runner.ts` would happily create for it.
  const projectRoot = join(dir, 'repo');
  mkdirSync(projectRoot, { recursive: true });
  // The bot polls Telegram as soon as a token exists; in a test nothing may go out —
  // a suite that really calls is slower than allowed and fails without network.
  const fetchMock = vi.fn().mockResolvedValue({
    ok: true,
    status: 200,
    json: async () => ({ ok: true, result: [] }),
  });
  vi.stubGlobal('fetch', fetchMock);
  const store = new Store(dir);
  const suggestion = store.createSuggestion({
    text: 'Der Slime soll springen',
    author: 'Anonym',
    source: 'game',
    category: 'mechanics',
    canonicalId: null,
    status: 'new',
  });
  previousBin = process.env.OPENCODE_BIN;
  if (options.runnerEnabled) {
    // A stub, not a real agent: the run is started by the route under test, and
    // what is asserted is the row it leaves behind.
    const stub = join(projectRoot, 'opencode-stub');
    writeFileSync(stub, '#!/bin/sh\nexit 0\n');
    chmodSync(stub, 0o755);
    process.env.OPENCODE_BIN = stub;
  }
  const app = createApp({
    dataDir: dir,
    contentDir: join(ROOT, 'content'),
    projectRoot,
    distDir: join(dir, 'dist'),
    // Without a runner no run may appear: these tests check the wiring, not the agent.
    runnerEnabled: options.runnerEnabled ?? false,
  });
  return { dir, store, suggestion, app, fetchMock };
}

/** A message the way Telegram delivers it. */
function update(text: string, chatId = 42, fromId: number | null = 7, id = 1) {
  return {
    update_id: id,
    message: {
      message_id: id,
      text,
      date: 1_700_000_000,
      chat: { id: chatId, type: 'private' },
      from: fromId === null ? undefined : { id: fromId, is_bot: false },
    },
  };
}

/** The reply texts the bot sent, ignoring the polling requests around them. */
function sentTexts(fetchMock: ReturnType<typeof vi.fn>): string[] {
  return fetchMock.mock.calls
    .filter(([url]) => String(url).includes('/sendMessage'))
    .map(([, init]) => JSON.parse(String((init as { body: string }).body)).text as string);
}

afterEach(() => {
  runIds.length = 0;
  vi.unstubAllGlobals();
  delete process.env.TELEGRAM_BOT_TOKEN;
  delete process.env.TELEGRAM_CHAT_ID;
  delete process.env.TELEGRAM_ALLOWED_USER_IDS;
  if (previousBin === undefined) delete process.env.OPENCODE_BIN;
  else process.env.OPENCODE_BIN = previousBin;
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
    //
    // This is the only case here that really runs the bot. The old version held
    // the bot in a variable, wrote `void bot;`, and then PATCHed the HTTP route —
    // the assertion had nothing to do with the title, and `Date.now() >=
    // Date.now()` could not fail.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const { dir, store, app, fetchMock } = harness();
    try {
      const bot = (app as unknown as { _singular80: { bot: { handle: (u: unknown) => Promise<void> } } })
        ._singular80.bot;
      const id = store.listSuggestions()[0].id;
      await bot.handle(update(`/approve ${id}`));
      // The side effect, read from the database …
      expect(store.getSuggestion(id)?.status).toBe('approved');
      // … and from the endpoint the dashboard actually calls.
      const listed = (await app.inject({ method: 'GET', url: '/api/suggestions' })).json();
      expect(listed.suggestions[0].status).toBe('approved');
      // The chat got an answer, so the command really went through the bot.
      expect(sentTexts(fetchMock)).toContain(`#${id} ist jetzt approved.`);
    } finally {
      await app.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('erzeugt aus einem Chat-Befehl denselben Lauf wie der Dashboard-Knopf', async () => {
    // The claim in the header of this file. Both paths call the same `startRun`,
    // so both must leave a run row for the suggestion — one written by `/run` in
    // the chat, one by the HTTP button, on two different suggestions so the
    // "a run is already going" guard cannot swallow the second.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const { dir, store, app, fetchMock } = harness({ runnerEnabled: true });
    try {
      const bot = (app as unknown as { _singular80: { bot: { handle: (u: unknown) => Promise<void> } } })
        ._singular80.bot;
      const first = store.listSuggestions()[0].id;
      const second = store.createSuggestion({
        text: 'Der Boss soll später kommen',
        author: 'Anonym',
        source: 'dashboard',
        category: 'mechanics',
        canonicalId: null,
        status: 'approved',
      }).id;

      await bot.handle(update(`/run ${first}`));
      const viaButton = await app.inject({
        method: 'POST',
        url: `/api/suggestions/${second}/implement`,
        payload: {},
      });
      expect(viaButton.statusCode).toBe(200);
      expect(sentTexts(fetchMock)).toContain(`Aufruf ${first} gestartet`);

      const chatRuns = (await app.inject({ method: 'GET', url: `/api/suggestions/${first}` })).json().runs;
      const buttonRuns = (await app.inject({ method: 'GET', url: `/api/suggestions/${second}` })).json().runs;
      expect(chatRuns).toHaveLength(1);
      expect(buttonRuns).toHaveLength(1);
      // Same shape, and both logs land in the temp repository rather than in the
      // working tree this suite shares with the real runner.
      for (const [runs, id] of [[chatRuns, first], [buttonRuns, second]] as const) {
        expect(runs[0].suggestionId).toBe(id);
        expect(runs[0].id).toMatch(/^run_/);
        expect(runs[0].logPath.startsWith(dir)).toBe(true);
      }
    } finally {
      await app.close();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30_000);
});
