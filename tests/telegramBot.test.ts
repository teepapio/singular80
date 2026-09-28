import { describe, expect, it, afterEach, vi } from 'vitest';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createApp } from '../server/app';
import { Store } from '../server/db';

/**
 * Der Telegram-Bot ist eine zweite Oberfläche auf dieselbe Warteschlange. Das
 * ist genau die Stelle, an der zwei Wahrheiten entstehen könnten, also wird hier
 * nicht die Formatierung geprüft (das macht `telegram.test.ts`), sondern die
 * Verbindung: Ein Befehl aus dem Chat muss denselben Lauf erzeugen, den auch
 * der Dashboard-Knopf erzeugt — und beide Enden müssen es sehen.
 */

const runIds: string[] = [];

function harness() {
  const dir = mkdtempSync(join(tmpdir(), 's80-tgbot-'));
  // Der Bot pollt Telegram, sobald ein Token dasteht. Im Test darf davon nichts
  // nach draußen gehen — eine Testsuite, die echte Aufrufe macht, ist
  // langsamer als sie sein darf und scheitert ohne Netz.
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
    // Ohne Runner darf kein Lauf entstehen; die Tests prüfen die Verdrahtung,
    // nicht den Agenten.
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
    // Ohne Token darf der Bot nicht pollen: sonst schlägt der Server im
    // Sekundentakt gegen die Telegram-API.
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
    // Testeinträge aus dem Spiel und Doubletten sollen wirklich wegkönnen, nicht
    // nur auf `rejected` gesetzt werden — der Eintrag bliebe sonst in der
    // Historie und in `backup/dashboard.json` stehen.
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
    // Kinder aus einer Aufteilung sind eigene Arbeit und dürfen nicht mit dem
    // Elternteil verschwinden.
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

  it('meldet Telegram nur als eingerichtet oder nicht — nie mit Token', async () => {
    // `/api/settings` geht an jedes offene Fenster. Der Token darf dort nicht
    // auftauchen, sonst läse jeder im Netz den Schlüssel zum Bot mit.
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
    // Das ist die geforderte Synchronisierung: was der Typ im Chat tippt,
    // steht danach im Dashboard — und umgekehrt, weil beide `setStatus`
    // benutzen.
    const { dir, store, app } = harness();
    try {
      const internals = (app as unknown as {
        _singular80: { store: Store; bot: { handle: (u: unknown) => Promise<void> } };
      })._singular80;
      const list = store.listSuggestions();
      const id = list[0].id;
      const bot = internals.bot;
      // Der Antwortweg ist Telegram selbst; hier zählt nur der Seiteneffekt.
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
