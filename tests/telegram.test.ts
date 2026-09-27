import { describe, expect, it, vi, afterEach } from 'vitest';
import type { SuggestionView } from '../src/shared/types';
import {
  buildSuggestionText,
  escapeHtml,
  isConfigured,
  notifyNewSuggestion,
  notifyRunResult,
  sendMessage,
} from '../server/telegram';

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

afterEach(() => {
  vi.unstubAllGlobals();
  delete process.env.TELEGRAM_BOT_TOKEN;
  delete process.env.TELEGRAM_CHAT_ID;
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

  it('nennt Nummer, Kategorie und Sprungmarke', () => {
    const text = buildSuggestionText(VIEW, URL_TEXT);
    expect(text).toContain('#7');
    expect(text).toContain('Content');
    expect(text).toContain(`${URL_TEXT}#suggestion-7`);
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
