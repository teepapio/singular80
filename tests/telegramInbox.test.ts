import { describe, expect, it, afterEach } from 'vitest';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { inboxConfigured, inboxSessionPath, parseRelayed, TelegramInbox } from '../server/telegramInbox';
import { Store } from '../server/db';
import { EventEmitter } from 'node:events';

/**
 * The chat pull.
 *
 * Two things are worth proving here, and the first one is the reason this file
 * exists at all. A player suggestion reaches the dashboard **as a user session**,
 * not through the bot: Telegram never hands a bot its own messages back (official
 * FAQ — bots "will not be able to see messages from other bots regardless of
 * mode"), and a message sent with the bot token was measured on this machine as
 * invisible to the poller. So the test that matters is the second one: given the
 * text of a chat message, does it become a suggestion, and does the server's own
 * chatter stay out?
 */

const previousId = process.env.TELEGRAM_API_ID;
const previousHash = process.env.TELEGRAM_API_HASH;

afterEach(() => {
  if (previousId === undefined) delete process.env.TELEGRAM_API_ID;
  else process.env.TELEGRAM_API_ID = previousId;
  if (previousHash === undefined) delete process.env.TELEGRAM_API_HASH;
  else process.env.TELEGRAM_API_HASH = previousHash;
});

function dir(): string {
  return mkdtempSync(join(tmpdir(), 's80-inbox-'));
}

describe('Vorschläge aus dem Chat lesen', () => {
  it('erkennt die Signatur, die das Spiel anhängt', () => {
    // `telegram_relay.gd` appends a blank line and `— author` to every message.
    const parsed = parseRelayed('Der Siedler-Knopf ist verdeckt\n\n— Lisa');
    expect(parsed).toEqual({ text: 'Der Siedler-Knopf ist verdeckt', author: 'Lisa' });
  });

  it('nimmt eine Nachricht ohne Signatur nicht', () => {
    // The server writes into the same chat. None of these carry a signature, and
    // importing them would be a loop: the bot announcing its own announcements.
    expect(parseRelayed('Auftrag 12 beendet')).toBeNull();
    expect(parseRelayed('#7\nDer Slime soll springen')).toBeNull();
    expect(parseRelayed('Singular 80: Telegram ist verbunden.')).toBeNull();
    expect(parseRelayed('Singular 80 — du steuerst das Dashboard aus diesem Chat.')).toBeNull();
    expect(parseRelayed('')).toBeNull();
    expect(parseRelayed('\n\n— nur ein Autor')).toBeNull();
  });

  it('bleibt aus, solange keine Anmeldung da ist', () => {
    // The server must never reach for a personal account that was not linked on
    // purpose — a checkout without credentials is the normal case.
    const dataDir = dir();
    const previousChat = process.env.TELEGRAM_CHAT_ID;
    delete process.env.TELEGRAM_API_ID;
    delete process.env.TELEGRAM_API_HASH;
    try {
      expect(inboxConfigured(dataDir).ok).toBe(false);
      // Credentials alone are not enough either: without a session there is
      // nothing to connect with, and logging in from a background poll would be
      // a surprise.
      process.env.TELEGRAM_API_ID = '123';
      process.env.TELEGRAM_API_HASH = 'hash';
      expect(inboxConfigured(dataDir).ok).toBe(false);
      writeFileSync(inboxSessionPath(dataDir), 'session');
      expect(inboxConfigured(dataDir).ok).toBe(true);
      void previousChat;
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it('legt eine Nachricht als Vorschlag an, ohne einen Lauf zu starten', () => {
    // The end-to-end claim, minus the network: what the inbox does with one
    // message once it has read it.
    const dataDir = dir();
    const store = new Store(dataDir);
    try {
      const emitted: string[] = [];
      const bus = new EventEmitter();
      bus.on('event', (e: { type: string }) => emitted.push(e.type));
      const inbox = new TelegramInbox({
        dataDir,
        store,
        bus,
        viewOf: (id) => {
          const row = store.getSuggestion(id);
          return row ? ({ ...row, clusterSize: 1 } as never) : null;
        },
      });
      const chatId = '42';
      // One relayed suggestion and one line of the server's own chatter.
      const imported = (inbox as unknown as {
        importOne: (chat: string, id: number, text: string) => boolean;
      }).importOne.bind(inbox);
      expect(imported(chatId, 501, 'Die Lava soll langsamer fließen\n\n— Lisa')).toBe(true);
      expect(imported(chatId, 502, 'Auftrag 9 beendet')).toBe(false);

      const rows = store.listSuggestions();
      expect(rows).toHaveLength(1);
      expect(rows[0].text).toBe('Die Lava soll langsamer fließen');
      expect(rows[0].author).toBe('Lisa');
      expect(rows[0].source).toBe('telegram');
      expect(rows[0].status).toBe('new');
      expect(store.listRuns(50)).toHaveLength(0);
      expect(emitted).toEqual(['suggestion:new']);
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it('legt dieselbe Nachricht nicht zweimal an', () => {
    // The watermark is a watermark, not a filter: a restart reads the tail of the
    // chat again, and without the key that would duplicate suggestions.
    const dataDir = dir();
    const store = new Store(dataDir);
    try {
      const inbox = new TelegramInbox({
        dataDir,
        store,
        bus: new EventEmitter(),
        viewOf: () => null,
      });
      const importOne = (inbox as unknown as {
        importOne: (chat: string, id: number, text: string) => boolean;
      }).importOne.bind(inbox);
      const text = 'Bitte den Slime bunter machen\n\n— Lisa';
      expect(importOne('42', 601, text)).toBe(true);
      expect(importOne('42', 601, text)).toBe(false);
      expect(store.listSuggestions()).toHaveLength(1);
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});