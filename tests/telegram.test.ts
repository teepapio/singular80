import { describe, expect, it, vi, afterEach } from 'vitest';
import type { SuggestionView } from '../src/shared/types';
import {
  buildSuggestionText,
  escapeHtml,
  getUpdates,
  HELP_TEXT,
  isAuthorized,
  isConfigured,
  notifyNewSuggestion,
  notifyRunResult,
  parseCommand,
  sendMessage,
  suggestionIdArg,
} from '../server/telegram';
import { TelegramBot } from '../server/telegramBot';

/**
 * Telegram ist der Kanal, über den der Besitzer erfährt, dass ein Spieler
 * etwas eingereicht hat. Geprüft wird deshalb vor allem das, was hier schon
 * schiefgehen kann, ohne dass es auffällt: Spielertext, der als HTML
 * fehlinterpretiert wird, eine zu lange Nachricht, und ein defekter Kanal, der
 * einen Vorschlag kosten dürfte.
 */

const VIEW = {
  id: 7,
  text: 'Ein Slime, der in zwei kleinere zerfällt',
  author: 'Anonym',
  source: 'game',
  category: 'content',
  status: 'new',
  votes: 0,
  score: 3,
  canonicalId: null,
  clusterSize: 1,
  createdAt: 1_700_000_000_000,
  discordMessageId: null,
  run: null,
} as unknown as SuggestionView;

const URL_TEXT = 'https://singular80.example/dashboard';
/** `sendTest` schickt, das ist hier nur sein Text — ohne Netz. */
const sendTestText = 'Singular 80: Telegram ist verbunden.';

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
    // Nichts davon darf als echtes Markup durchgehen: sonst bricht ein
    // Spieler die Nachricht und Telegram antwortet mit 400.
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
    // Absicht, nicht Versehen: der Besitzer liest das im Telegram auf dem
    // Telefon. Jede Zusatzzeile ist eine, die er überlesen muss, und die
    // Adresse des Dashboards ist von dort ohnehin nicht erreichbar.
    const text = buildSuggestionText(VIEW, 'https://localhost:5173/dashboard.html');
    expect(text).not.toContain('Content');
    expect(text).not.toContain('localhost');
    expect(text).not.toContain('Anonym');
  });

  it('schickt in keiner Nachricht ein Emoji', () => {
    // `Emoji|Regional_Indicator` deckt die Symbole ab, die Telegram als Emoji
    // rendert. Der Wunsch war ausdrücklich: keine.
    const emoji = /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{20E3}\u{2705}\u{274C}\u{2B50}\u{1F44D}\u{1F44E}]/u;
    expect(emoji.test(buildSuggestionText(VIEW, URL_TEXT))).toBe(false);
    expect(emoji.test(HELP_TEXT)).toBe(false);
    expect(emoji.test(sendTestText)).toBe(false);
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
    // Der entscheidende Punkt: ein fehlender Kanal darf keinen HTTP-Aufruf
    // auslösen, der ins Leere läuft.
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
    // Der häufigste Fehler überhaupt: Der Bot darf dem Chat noch nicht
    // schreiben, weil dort noch keine Nachricht von dir kam.
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

  it('meldet einen Erfolg, ohne Discord nachzuahmen', async () => {
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({}) });
    vi.stubGlobal('fetch', fetchMock);
    const result = await notifyRunResult(
      { id: 7, text: 'Idee' } as never,
      { id: 'run_1', status: 'succeeded', cost: 0.5, commitHash: 'abc1234' } as never,
      URL_TEXT,
    );
    expect(result.ok).toBe(true);
    const body = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    // `chat_id` kommt aus der Umgebung; eine Vorschau muss aus bleiben, weil
    // der Text von Spielern stammt.
    expect(body.chat_id).toBe('42');
    expect(body.disable_web_page_preview).toBe(true);
  });
});

/** Eine Nachricht so bauen, wie Telegram sie schickt. */
function update(text: string, chatId = 42, fromId: number | null = 7) {
  return {
    update_id: 1,
    message: {
      message_id: 1,
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
    // Sonst antwortet der Bot auf jedes Wort mit der Hilfeliste.
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
    // `/start` ist der Telegram-Befehl für den ersten Kontakt. Bedeutet er
    // hier "starte den Runner", startet ein Versehen einen Agenten.
    expect(HELP_TEXT).toContain('/run');
    expect(HELP_TEXT).not.toMatch(/\/start\s+\d/);
  });
});

describe('Wer den Bot steuern darf', () => {
  it('lässt ohne konfigurierte Id niemanden an', () => {
    // Ohne Allowlist wäre jeder, der den Bot findet, Operator.
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
    // Keine Antwort: eine Rückmeldung bestätigt nur, dass der Bot lebt.
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
    expect(body.text).toContain('run_9');
  });

  it('sagt, wenn die Warteschlange pausiert, statt zu starten', async () => {
    // Der wichtigste Fehler, den man nicht machen darf: ein Befehl, der die
    // Pause umgeht, erzeugt Arbeit, die niemand bestellt hat.
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
  it('meldet Nummer, Ausgang und Commit — sonst nichts', async () => {
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({}) });
    vi.stubGlobal('fetch', fetchMock);
    await notifyRunResult(
      { id: 7, text: 'Idee' } as never,
      { id: 'run_1', status: 'succeeded', cost: 0.5, commitHash: 'abc1234' } as never,
      URL_TEXT,
    );
    const body = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    expect(body.text).toBe('#7 umgesetzt abc1234');
    expect(body.text).not.toContain('0.5000');
  });

  it('nennt beim Fehlschlag den Status des Laufs', async () => {
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    process.env.TELEGRAM_CHAT_ID = '42';
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({}) });
    vi.stubGlobal('fetch', fetchMock);
    await notifyRunResult(
      { id: 7, text: 'Idee' } as never,
      { id: 'run_2', status: 'failed' } as never,
      URL_TEXT,
    );
    const body = JSON.parse(fetchMock.mock.calls[0][1].body as string);
    expect(body.text).toBe('#7 fehlgeschlagen (failed)');
  });
});

describe('getUpdates', () => {
  it('fragt nicht ab, solange kein Token gesetzt ist', async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    const result = await getUpdates(0);
    expect(result.ok).toBe(false);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('gibt das Wasserzeichen als Offset weiter', async () => {
    // Ohne Offset bekäme Telegram dieselben Nachrichten endlos wieder.
    process.env.TELEGRAM_BOT_TOKEN = 'gut';
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200, json: async () => ({ ok: true, result: [] }) });
    vi.stubGlobal('fetch', fetchMock);
    await getUpdates(4711);
    expect(String(fetchMock.mock.calls[0][0])).toContain('offset=4711');
  });
});

/** Minimale Attrappe: der Bot braucht nur diese fünf Dinge. */
type StartRun = (id: number) => { ok: boolean; runId?: string; error?: string };

function makeBot(overrides: { startRun?: StartRun; paused?: boolean } = {}) {
  const runner = {
    isPaused: () => overrides.paused ?? false,
    queueState: () => ({ queue: [], activeRuns: [] }),
    capacity: () => 3,
  };
  return new TelegramBot({
    store: { listSuggestions: () => [], listRuns: () => [] } as never,
    runner: runner as never,
    bus: { on: () => {}, emit: () => false } as never,
    dashboardUrl: 'https://example.invalid/dashboard.html',
    viewOf: () => null,
    startRun: overrides.startRun ?? (() => ({ ok: true, runId: 'run_1' })),
    setStatus: () => ({ ok: true }),
    onError: () => {},
  });
}
