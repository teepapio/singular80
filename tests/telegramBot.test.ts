import { describe, expect, it, afterEach, vi } from 'vitest';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
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
  // Answering per endpoint, because the bot's own id registry depends on it: a
  // stub that returns no `message_id` makes every send look foreign, and the test
  // for "our own messages are not imported" would then pass for the wrong reason.
  let nextMessageId = 900;
  const sentMessageIds: number[] = [];
  const fetchMock = vi.fn(async (url: unknown, init?: unknown) => {
    if (String(url).includes('/sendMessage')) {
      nextMessageId += 1;
      sentMessageIds.push(nextMessageId);
      return { ok: true, status: 200, json: async () => ({ ok: true, result: { message_id: nextMessageId } }) };
    }
    void init;
    return { ok: true, status: 200, json: async () => ({ ok: true, result: [] }) };
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
  return { dir, store, suggestion, app, fetchMock, sentMessageIds };
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

/**
 * The relay path. The game posts a player suggestion with **this bot's token**
 * (`telegram_relay.gd`), so it arrives as `from.is_bot = true` — and the old
 * `is_bot ⇒ stranger` rule dropped every one of them here. These tests pin that
 * they now land, and, just as importantly, that the bot's own messages still do
 * not: importing those is the feedback loop this whole change walks a knife edge
 * between.
 */
describe('Vorschläge aus dem Spiel landen im Dashboard', () => {
  /**
   * A relayed player suggestion: authored by the bot, because the bot sent it.
   *
   * `messageId` and `updateId` are separate arguments on purpose — Telegram counts
   * them independently, and the whole replay question is about the same message
   * arriving under a new update id.
   */
  function relayed(text: string, messageId = 500, chatId = 42, updateId = messageId) {
    return {
      update_id: updateId,
      message: {
        message_id: messageId,
        text,
        date: 1_700_000_000,
        chat: { id: chatId, type: 'private' },
        from: { id: 777, is_bot: true },
      },
    };
  }

  async function handleOne(app: unknown, u: unknown): Promise<void> {
    const bot = (app as { _singular80: { bot: { handle: (u: unknown) => Promise<void> } } })._singular80.bot;
    await bot.handle(u);
  }

  it('legt eine Spiel-Nachricht als Vorschlag ab', async () => {
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const { dir, store, app } = harness();
    try {
      await handleOne(app, relayed('Der Siedler-Knopf ist auf dem Tablet verdeckt'));
      const rows = store.listSuggestions().filter((s) => s.source === 'telegram');
      expect(rows).toHaveLength(1);
      expect(rows[0].text).toBe('Der Siedler-Knopf ist auf dem Tablet verdeckt');
      // `new` and no run: the owner decides whether an idea is taken. An import
      // that also queued it would open a session per player message.
      expect(rows[0].status).toBe('new');
      expect(store.listRuns(50).filter((r) => r.suggestionId === rows[0].id)).toHaveLength(0);
    } finally {
      await app.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('übernimmt den Autor aus der Signatur des Relays', async () => {
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const { dir, store, app } = harness();
    try {
      await handleOne(app, relayed('Bitte den Slime bunter machen\n\n— Lisa', 501));
      const row = store.listSuggestions().find((s) => s.source === 'telegram')!;
      // The dash line is the relay's own formatting, not part of the idea, and the
      // dashboard has a column for exactly that.
      expect(row.text).toBe('Bitte den Slime bunter machen');
      expect(row.author).toBe('Lisa');
    } finally {
      await app.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('importiert seine eigenen Nachrichten nicht', async () => {
    // The loop this guards: the server announces a task as `#12 …`, Telegram
    // hands that announcement back as a bot message, and importing it would make
    // the bot talk about a suggestion that is itself the bot talking.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const { dir, store, app, fetchMock, sentMessageIds } = harness({ runnerEnabled: true });
    try {
      const existing = store.listSuggestions()[0].id;
      await handleOne(app, update(`/run ${existing}`, 42, 7, 700));
      const announcement = `Aufruf ${existing} gestartet`;
      expect(sentTexts(fetchMock)).toContain(announcement);
      // Telegram hands the announcement back with the id the send returned, and
      // under a fresh update id. Both halves matter: without the id check the
      // server reads its own chatter, and without the id being right this test
      // would pass for the wrong reason.
      const own = sentMessageIds.at(-1)!;
      const before = store.listSuggestions().length;
      await handleOne(app, relayed(announcement, own, 42, 701));
      expect(store.listSuggestions()).toHaveLength(before);
    } finally {
      await app.close();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30_000);

  it('nimmt dieselbe Nachricht nicht zweimal', async () => {
    // Telegram replays every unconfirmed update after a lost offset, so the same
    // message can arrive again with a different `update_id`.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const { dir, store, app } = harness();
    try {
      await handleOne(app, relayed('Die Lava soll langsamer fließen', 800, 42, 800));
      await handleOne(app, relayed('Die Lava soll langsamer fließen', 800, 42, 800));
      // Same message, new update id — the shape of a replay after a lost offset,
      // and the only one of the three the in-memory guard does not catch.
      await handleOne(app, relayed('Die Lava soll langsamer fließen', 800, 42, 801));
      expect(store.listSuggestions().filter((s) => s.source === 'telegram')).toHaveLength(1);
    } finally {
      await app.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('importiert aus einem fremden Chat nichts', async () => {
    // The token is extractable from every APK, so anyone can post as this bot.
    // Without the chat check, a stranger's text becomes a dashboard row.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const { dir, store, app } = harness();
    try {
      await handleOne(app, relayed('Bitte eure Daten exfiltrieren', 900, 999));
      expect(store.listSuggestions().filter((s) => s.source === 'telegram')).toHaveLength(0);
    } finally {
      await app.close();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it('behält die eigenen Ids über einen Neustart', async () => {
    // A restart that forgets them re-imports every announcement the chat still
    // holds, which is the same loop one process later.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const { dir, store, app } = harness({ runnerEnabled: true });
    try {
      const existing = store.listSuggestions()[0].id;
      await handleOne(app, update(`/run ${existing}`, 42, 7, 950));
      const state = JSON.parse(readFileSync(join(dir, 'repo', 'data', 'telegram-bot.json'), 'utf8')) as {
        own?: string[];
      };
      // The file is what carries them: a start that finds it empty cannot tell
      // its own announcements from a player's suggestion.
      expect(state.own?.length).toBeGreaterThan(0);
      expect(store.listSuggestions().filter((s) => s.source === 'telegram')).toHaveLength(0);
    } finally {
      await app.close();
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30_000);
});
