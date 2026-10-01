import { describe, expect, it, vi, afterEach } from 'vitest';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { SuggestionView } from '../src/shared/types';
import {
  buildSuggestionText,
  editMessageText,
  escapeHtml,
  getUpdates,
  HELP_TEXT,
  isAuthorized,
  isConfigured,
  notifyNewSuggestion,
  runResultText,
  parseCommand,
  sendMessage,
  sendTest,
  suggestionIdArg,
} from '../server/telegram';
import { TelegramBot } from '../server/telegramBot';

// A broken channel costs a suggestion silently, so the text, the length limit and
// the delivery path are pinned here.

const VIEW = {
  id: 7,
  text: 'Ein Slime, der in zwei kleinere zerfällt',
  author: 'Anonym',
  source: 'game',
  category: 'content',
  status: 'new',
  votes: 0,
  canonicalId: null,
  clusterSize: 1,
  createdAt: 1_700_000_000_000,
  discordMessageId: null,
  run: null,
} as unknown as SuggestionView;

const URL_TEXT = 'https://singular80.example/dashboard';
/** These are the ranges Telegram renders as emoji; the request was none. */
const EMOJI = /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{20E3}\u{2705}\u{274C}\u{2B50}\u{1F44D}\u{1F44E}]/u;

afterEach(() => {
  vi.unstubAllGlobals();
  delete process.env.TELEGRAM_BOT_TOKEN;
  delete process.env.TELEGRAM_CHAT_ID;
  delete process.env.TELEGRAM_ALLOWED_USER_IDS;
});

describe('Telegram-Text', () => {
  it('maskiert Markup aus Spielereingabe', () => {
    expect(escapeHtml('a & b <b>c</b>')).toBe('a &amp; b &lt;b&gt;c&lt;/b&gt;');
  });

  it('lässt einen Vorschlag mit spitzen Klammern unversehrt ankommen', () => {
    const evil = { ...VIEW, text: 'Mach <b>fett</b> & <script> — 5 < 6' } as unknown as SuggestionView;
    const text = buildSuggestionText(evil, URL_TEXT);
    // None of it may pass as real markup: a player could break the message and
    // Telegram answers 400.
    expect(text).not.toContain('<b>fett</b>');
    expect(text).not.toContain('<script>');
    expect(text).toContain('&lt;script&gt;');
    expect(text).toContain('&amp;');
    expect(text).toContain('5 &lt; 6');
  });

  it('schickt nur Nummer und Text — nichts, was auf dem Telefon stört', () => {
    const text = buildSuggestionText(VIEW, URL_TEXT);
    expect(text).toBe('#7\nEin Slime, der in zwei kleinere zerfällt');
  });

  it('lässt Kategorie, Punkte, Autor, Zeit und Adresse weg', () => {
    // Deliberate: the owner reads this on a phone, and the dashboard URL is
    // unreachable from there anyway.
    const text = buildSuggestionText(VIEW, 'https://localhost:5173/dashboard.html');
    expect(text).not.toContain('Content');
    expect(text).not.toContain('localhost');
    expect(text).not.toContain('Anonym');
  });

  it('schickt in keiner Nachricht ein Emoji', async () => {
    // The test message is checked as it goes out, not as a copy of it. A local
    // duplicate of `sendTest`'s text was what this used: the product could grow an
    // emoji and the assertion would have kept passing on the old wording.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({}) });
    vi.stubGlobal('fetch', fetchMock);
    await sendTest(URL_TEXT);
    const sentTestText = JSON.parse(fetchMock.mock.calls[0][1].body as string).text as string;
    expect(EMOJI.test(buildSuggestionText(VIEW, URL_TEXT))).toBe(false);
    expect(EMOJI.test(HELP_TEXT)).toBe(false);
    expect(EMOJI.test(sentTestText)).toBe(false);
    // The product sentence itself, so a rewrite of the wording is a visible change.
    expect(sentTestText).toBe('Singular 80: Telegram ist verbunden.');
  });

  it('bleibt unter der Telegram-Grenze von 4096 Zeichen', () => {
    const long = { ...VIEW, text: 'x'.repeat(9000) } as unknown as SuggestionView;
    expect(buildSuggestionText(long, URL_TEXT).length).toBeLessThanOrEqual(4096);
  });
});

describe('Telegram-Zustellung', () => {
  it('gilt ohne beide Variablen als nicht konfiguriert', () => {
    process.env.TELEGRAM_BOT_TOKEN = 'irgendwas';
    expect(isConfigured()).toBe(false);
    process.env.TELEGRAM_CHAT_ID = '1';
    delete process.env.TELEGRAM_BOT_TOKEN;
    expect(isConfigured()).toBe(false);
  });

  it('schickt ohne Konfiguration nichts und sagt warum', async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    const result = await sendMessage('hallo');
    expect(result.ok).toBe(false);
    expect(result.error).toMatch(/TELEGRAM_BOT_TOKEN/);
    // A missing channel must not fire an HTTP call into the void.
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('fragt 401 als ungültigen Token ab, nicht als Telegram-Rauschen', async () => {
    process.env.TELEGRAM_BOT_TOKEN = 'kaputt';
    process.env.TELEGRAM_CHAT_ID = '1';
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({ ok: false, status: 401, text: async () => '{"description":"Unauthorized"}' }),
    );
    const result = await notifyNewSuggestion(VIEW, URL_TEXT);
    expect(result.ok).toBe(false);
    expect(result.error).toContain('401');
    expect(result.error).toContain('Token ungültig');
  });

  it('nennt bei 403 ausdrücklich den Grund, den man beheben kann', async () => {
    // The most common failure: the bot may not write to the chat until you
    // have written there first.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '1';
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: false,
        status: 403,
        text: async () => '{"description":"bot can\'t initiate conversation"}',
      }),
    );
    const result = await notifyNewSuggestion(VIEW, URL_TEXT);
    expect(result.ok).toBe(false);
    expect(result.error).toMatch(/schreiben/);
  });

  it('schickt eine Nachricht nach einem abgerissenen Socket erneut', async () => {
    // Without the retry, the reply to `/task` is lost exactly when the task
    // itself has been accepted — the owner sees nothing and cannot tell whether
    // the order arrived.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const fetchMock = vi
      .fn()
      .mockRejectedValueOnce(new TypeError('fetch failed'))
      .mockResolvedValueOnce({ ok: true, status: 200, json: async () => ({}) });
    vi.stubGlobal('fetch', fetchMock);
    const result = await sendMessage('Auftrag #7 gestartet');
    expect(result.ok).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('wiederholt eine abgelehnte Nachricht nicht', async () => {
    // 400 means the message itself is wrong; the next try is identical. Only a
    // torn connection or a 5xx is worth sending again.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const fetchMock = vi
      .fn()
      .mockResolvedValue({ ok: false, status: 400, text: async () => '{"description":"chat not found"}' });
    vi.stubGlobal('fetch', fetchMock);
    const result = await sendMessage('x');
    expect(result.ok).toBe(false);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('meldet einen Erfolg, ohne Discord nachzuahmen', async () => {
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({}) });
    vi.stubGlobal('fetch', fetchMock);
    const result = await sendMessage(runResultText(7, true));
    expect(result.ok).toBe(true);
    const body = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    // `chat_id` comes from the environment; no preview, the text is player text.
    expect(body.chat_id).toBe('42');
    expect(body.disable_web_page_preview).toBe(true);
  });
});

/** A message the way Telegram sends it. `id` must differ per message. */
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

describe('Befehle aus dem Chat', () => {
  it('erkennt den Befehl trotz @Bot-Namen und Argumenten', () => {
    const command = parseCommand('/run@Singular80Bot 12 jetzt');
    expect(command).not.toBeNull();
    expect(command!.name).toBe('run');
    expect(command!.args).toEqual(['12', 'jetzt']);
  });

  it('ignoriert normale Chatnachrichten', () => {
    // Otherwise the bot answers every plain word with the help list.
    expect(parseCommand('guten Morgen')).toBeNull();
    expect(parseCommand('')).toBeNull();
  });

  it('liest nur eine echte Nummer als Vorschlagsnummer', () => {
    expect(suggestionIdArg(['12'])).toBe(12);
    expect(suggestionIdArg(['0', 'x'])).toBeNull();
    expect(suggestionIdArg(['-3'])).toBeNull();
    expect(suggestionIdArg(['zwölf'])).toBeNull();
    expect(suggestionIdArg([])).toBeNull();
  });

  it('zeigt die Hilfeliste, ohne einen Lauf zu starten', () => {
    // `/start` is Telegram's first-contact command. Read as "start the runner"
    // it launches an agent by accident.
    expect(HELP_TEXT).toContain('/run');
    expect(HELP_TEXT).not.toMatch(/\/start\s+\d/);
  });
});

describe('Wer den Bot steuern darf', () => {
  it('lässt ohne konfigurierte Id niemanden an', () => {
    // Without an allowlist everyone who finds the bot is the operator.
    expect(isAuthorized(update('/run 1', 99, 99))).toBe(false);
  });

  it('akzeptiert den Besitzer über Chat-Id und über Benutzer-Id', () => {
    process.env.TELEGRAM_CHAT_ID = '42';
    expect(isAuthorized(update('/run 1', 42, 7))).toBe(true);
    process.env.TELEGRAM_CHAT_ID = '111';
    process.env.TELEGRAM_ALLOWED_USER_IDS = '7, 8';
    expect(isAuthorized(update('/run 1', 999, 7))).toBe(true);
    expect(isAuthorized(update('/run 1', 999, 8))).toBe(true);
  });

  it('weist Fremde ab, ohne ihnen zu antworten', async () => {
    process.env.TELEGRAM_CHAT_ID = '42';
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({}) });
    vi.stubGlobal('fetch', fetchMock);
    const bot = makeBot();
    await bot.handle(update('/run 1', 999, 999));
    // No reply: an answer only confirms the bot is alive.
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('weist andere Bots ab', () => {
    process.env.TELEGRAM_CHAT_ID = '42';
    const other = update('/run 1');
    other.message!.from = { id: 7, is_bot: true };
    expect(isAuthorized(other)).toBe(false);
  });
});

describe('Der Bot führt Befehle aus', () => {
  it('startet einen Lauf und nennt die Run-Id', async () => {
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({}) });
    vi.stubGlobal('fetch', fetchMock);
    const started: number[] = [];
    const bot = makeBot({ startRun: (id) => (started.push(id), { ok: true, runId: 'run_9' }) });
    await bot.handle(update('/run 12'));
    expect(started).toEqual([12]);
    const body = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    // The run id is deliberately gone: the chat stays at the minimum.
    expect(body.text).toBe('Aufruf 12 gestartet');
    expect(body.text).not.toContain('run_9');
  });

  it('sagt, wenn die Warteschlange pausiert, statt zu starten', async () => {
    // A command that slips past the pause creates work nobody ordered.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({}) });
    vi.stubGlobal('fetch', fetchMock);
    const started: number[] = [];
    const bot = makeBot({
      paused: true,
      startRun: (id) => (started.push(id), { ok: true, runId: 'run_9' }),
    });
    await bot.handle(update('/run 12'));
    expect(started).toEqual([]);
    const body = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    expect(body.text).toContain('pausiert');
  });

  it('meldet einen unbekannten Vorschlag, ohne zu raten', async () => {
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({}) });
    vi.stubGlobal('fetch', fetchMock);
    const bot = makeBot({ startRun: () => ({ ok: false, error: 'Vorschlag #99 gibt es nicht.' }) });
    await bot.handle(update('/run 99'));
    const body = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    expect(body.text).toContain('gibt es nicht');
  });

  it('antwortet auf /help mit der Liste und ohne Seiteneffekt', async () => {
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({}) });
    vi.stubGlobal('fetch', fetchMock);
    const bot = makeBot();
    await bot.handle(update('/help'));
    const body = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    expect(body.text).toContain('/list');
    expect(body.text).toContain('/status');
  });
});

describe('Das Ergebnis eines Laufs', () => {
  // Three words. The task text is one scroll up, the commit is in the changelog
  // and on GitHub. A line that has to be read twice is not read at all.
  it('ist genau eine Zeile bei Erfolg', () => {
    expect(runResultText(7, true)).toBe('Aufruf 7 beendet');
  });

  it('sagt Fehlschlag, wenn es einer war', () => {
    expect(runResultText(7, false)).toBe('Aufruf 7 fehlgeschlagen');
  });

  it('nennt weder Commit noch Kosten noch Status', () => {
    expect(runResultText(7, true)).not.toMatch(/[0-9a-f]{7}/);
    expect(runResultText(7, true).length).toBeLessThan(20);
  });
});

describe('Der Chat bleibt kurz', () => {
  it('das Ergebnis ersetzt die Auftragsnachricht, statt eine neue zu senden', async () => {
    // One message per task, rewritten when it is done. Without the message id
    // every outcome would be an extra line, and the channel would grow with every
    // status change — which is what the owner asked to be rid of.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({}) });
    vi.stubGlobal('fetch', fetchMock);
    await editMessageText('4711', runResultText(7, true));
    const [url, init] = fetchMock.mock.calls[0];
    expect(String(url)).toContain('editMessageText');
    expect(JSON.parse(init.body as string).message_id).toBe(4711);
    expect(JSON.parse(init.body as string).text).toBe('Aufruf 7 beendet');
  });

  it('meldet eine nicht auffindbare Nachricht, statt zu schweigen', async () => {
    // A message the owner deleted cannot be edited; the error names it.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({ ok: false, status: 400, text: async () => '{"description":"message to edit not found"}' }),
    );
    const result = await editMessageText('1', 'Aufruf 7 beendet');
    expect(result.ok).toBe(false);
    expect(result.error).toMatch(/400/);
  });
});

describe('Freier Auftrag aus dem Chat', () => {
  it('legt einen Auftrag an und nennt Nummer und Run', async () => {
    // The owner asked for this: a task typed in Telegram, picked up by the runner
    // through the same `createTask` the dashboard's "Direkter Auftrag" button uses.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({}) });
    vi.stubGlobal('fetch', fetchMock);
    const texts: string[] = [];
    const bot = makeBot({ createTask: async (t) => (texts.push(t), { ok: true, runId: 'run_77', suggestionId: 55 }) });
    await bot.handle(update('/task Mach den Slime schneller'));
    expect(texts).toEqual(['Mach den Slime schneller']);
    const body = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    expect(body.text).toBe('Aufruf 55 gestartet');
  });

  it('nimmt den Text auch als nächste Nachricht', async () => {
    // A multi-line order pasted from a phone arrives as several messages; the
    // next one is the text. Rejecting it teaches the owner nothing.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({}) });
    vi.stubGlobal('fetch', fetchMock);
    const texts: string[] = [];
    const bot = makeBot({ createTask: async (t) => (texts.push(t), { ok: true, runId: 'run_1', suggestionId: 3 }) });
    // Two distinct update ids: the replay guard would otherwise treat the second
    // message as one already handled.
    await bot.handle(update('/task', 42, 7, 1));
    expect(texts).toEqual([]);
    await bot.handle(update('mach den Slime schneller', 42, 7, 2));
    expect(texts).toEqual(['mach den Slime schneller']);
  });

  it('vergisst den wartenden Text nach einer Nachricht', async () => {
    // Otherwise every later chat message would start an agent run.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({}) }));
    const texts: string[] = [];
    const bot = makeBot({ createTask: async (t) => (texts.push(t), { ok: true, runId: 'r', suggestionId: 1 }) });
    await bot.handle(update('/task', 42, 7, 1));
    await bot.handle(update('/help', 42, 7, 2));
    // No plain text follows, so the pending text is dropped and this is a
    // command again.
    await bot.handle(update('guten Morgen', 42, 7, 3));
    expect(texts).toEqual([]);
  });

  it('startet keinen Auftrag, während die Warteschlange pausiert ist', async () => {
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({}) });
    vi.stubGlobal('fetch', fetchMock);
    const texts: string[] = [];
    const bot = makeBot({
      paused: true,
      createTask: async (t) => (texts.push(t), { ok: true, runId: 'r', suggestionId: 1 }),
    });
    await bot.handle(update('/task etwas'));
    expect(texts).toEqual([]);
    const body = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    expect(body.text).toContain('pausiert');
  });

  it('meldet einen Fehler, statt eine Nummer zu erfinden', async () => {
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({}) });
    vi.stubGlobal('fetch', fetchMock);
    const bot = makeBot({ createTask: async () => ({ ok: false, error: 'Der Auftrag braucht mindestens 3 Zeichen.' }) });
    await bot.handle(update('/task a'));
    const body = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    expect(body.text).toContain('mindestens 3 Zeichen');
  });
});

describe('Der Offset überlebt einen Neustart', () => {
  // `offset` used to be a plain field, so it was 0 again after every restart and
  // Telegram replayed unconfirmed commands. `tsx watch` restarts on every save, so
  // one `/run 12` became two OpenCode sessions.
  it('führt einen Befehl nach dem Neustart nicht erneut aus', async () => {
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const root = mkdtempSync(join(tmpdir(), 's80-tgbot-restart-'));
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({}) });
    vi.stubGlobal('fetch', fetchMock);

    const first = makeBot({ projectRoot: root, startRun: () => ({ ok: true, runId: 'run_1' }) });
    await first.handle(update('/run 12'));

    // Same folder, brand-new instance: what a server restart looks like.
    const started: number[] = [];
    const second = makeBot({
      projectRoot: root,
      startRun: () => (started.push(12), { ok: true, runId: 'run_2' }),
    });
    await second.handle(update('/run 12'));

    expect(started).toEqual([]);
  });

  it('merkt sich den offset auf der Platte, nicht nur im Speicher', async () => {
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const root = mkdtempSync(join(tmpdir(), 's80-tgbot-state-'));
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({}) }));
    makeBot({ projectRoot: root }).handle(update('/help'));
    const state = JSON.parse(readFileSync(join(root, 'data', 'telegram-bot.json'), 'utf8'));
    expect(state.offset).toBeGreaterThan(0);
    expect(state.seen.length).toBeGreaterThan(0);
  });

  it('schweigt bei einem Dauerfehler, statt ihn alle paar Sekunden zu wiederholen', async () => {
    // A polling error repeats as long as it lasts; ten identical lines tell the
    // owner no more than the first and hide the line that says something.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const root = mkdtempSync(join(tmpdir(), 's80-tgbot-noise-'));
    const errors: string[] = [];
    // Three answers: two the same, then a different one. Two identical failures are
    // the case the bot must collapse; the third proves it is not simply muting
    // itself after the first error.
    const poll = vi
      .fn()
      .mockResolvedValueOnce({ ok: false, status: 409, text: async () => '{"description":"Conflict"}' })
      .mockResolvedValueOnce({ ok: false, status: 409, text: async () => '{"description":"Conflict"}' })
      .mockResolvedValue({ ok: false, status: 500, text: async () => '{"description":"kaputt"}' });
    vi.stubGlobal('fetch', poll);
    const bot = makeBot({ projectRoot: root, onError: (e) => errors.push(e.message) });
    // Started through the public entry point, so nothing private is reached into:
    // the old version called `loop()` and `deps.onError` by name, and waited a
    // guessed 400 ms for a poll interval it did not know.
    bot.start();
    try {
      await waitUntil(() => poll.mock.calls.length >= 2, 15_000, 'zwei Abfragen');
      // The second one is the same failure and must not have produced a second line.
      expect(errors).toHaveLength(1);
      expect(errors[0]).toContain('409');
      await waitUntil(() => poll.mock.calls.length >= 3, 15_000, 'die dritte Abfrage');
      await waitUntil(() => errors.length >= 2, 5_000, 'die abweichende Fehlermeldung');
      // The claim is "identical failures collapse, a different one gets through",
      // not "the status code appears in the text": `getUpdates` retries three
      // times internally and reports one collapsed line, so by the third poll the
      // mock answers 500 forever and the code is `mehrfach fehlgeschlagen`.
      expect(errors).toHaveLength(2);
      expect(errors[1]).not.toBe(errors[0]);
      expect(errors[1]).toContain('fehlgeschlagen');
    } finally {
      await bot.stop();
    }
  }, 60_000);
});

describe('getUpdates', () => {
  it('fragt nicht ab, solange kein Token gesetzt ist', async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    const result = await getUpdates(0);
    expect(result.ok).toBe(false);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('versucht es nach einem abgerissenen Socket erneut', async () => {
    // The symptom this fixes: `tsx watch` restarts the server, the first call
    // after that lands in a connection Telegram is still tearing down, Node says
    // only `fetch failed`, and the answer to `/task` is lost while the task
    // itself runs. One retry is the whole fix.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    const fetchMock = vi
      .fn()
      .mockRejectedValueOnce(new TypeError('fetch failed'))
      .mockResolvedValueOnce({ ok: true, status: 200, json: async () => ({ ok: true, result: [] }) });
    vi.stubGlobal('fetch', fetchMock);
    const result = await getUpdates(5);
    expect(result.ok).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('gibt bei 409 auf, statt den Konflikt zu verlängern', async () => {
    // 409 means a second poller exists. Retrying would only keep both alive.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    const fetchMock = vi
      .fn()
      .mockResolvedValue({ ok: false, status: 409, text: async () => '{"description":"Conflict"}' });
    vi.stubGlobal('fetch', fetchMock);
    const result = await getUpdates(5);
    expect(result.ok).toBe(false);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('gibt das Wasserzeichen als Offset weiter', async () => {
    // Without an offset Telegram replays the same messages forever.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({ ok: true, result: [] }) });
    vi.stubGlobal('fetch', fetchMock);
    await getUpdates(4711);
    expect(String(fetchMock.mock.calls[0][0])).toContain('offset=4711');
  });
});

/** Waits until `check` is true, or fails with a message that names what. */
async function waitUntil(check: () => boolean, timeout: number, what: string): Promise<void> {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (check()) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`Timeout beim Warten auf ${what}`);
}

/** Minimal stand-in: the bot needs only these two types. */
type StartRun = (id: number) => { ok: boolean; runId?: string; error?: string };
type CreateTask = (
  text: string,
) => Promise<{ ok: boolean; runId?: string; suggestionId?: number; error?: string }>;

function makeBot(
  overrides: {
    startRun?: StartRun;
    createTask?: CreateTask;
    paused?: boolean;
    projectRoot?: string;
    onError?: (err: Error) => void;
  } = {},
) {
  const runner = {
    isPaused: () => overrides.paused ?? false,
    queueState: () => ({ queue: [], activeRuns: [] }),
    capacity: () => 3,
  };
  return new TelegramBot({
    // A temp dir per bot: a leaked offset would make a command look "already handled".
    projectRoot: overrides.projectRoot ?? mkdtempSync(join(tmpdir(), 's80-tgbot-')),
    store: { listSuggestions: () => [], listRuns: () => [] } as never,
    runner: runner as never,
    bus: { on: () => {}, emit: () => false } as never,
    dashboardUrl: 'https://example.invalid/dashboard.html',
    viewOf: () => null,
    startRun: overrides.startRun ?? (() => ({ ok: true, runId: 'run_1' })),
    createTask: overrides.createTask ?? (async () => ({ ok: true, runId: 'run_1', suggestionId: 1 })),
    setStatus: () => ({ ok: true }),
    onError: overrides.onError ?? (() => {}),
  });
}
