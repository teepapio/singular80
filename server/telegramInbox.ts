import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import type { EventEmitter } from 'node:events';
import { TelegramClient } from 'telegram';
import type { EntityLike } from 'telegram/define';
import { StringSession } from 'telegram/sessions';
import type { SuggestionView } from '../src/shared/types';
import { classify } from '../src/shared/sorting';
import type { Store } from './db';
import { getBotIdentity } from './telegram';

/**
 * Pulls player suggestions out of the owner's Telegram chat.
 *
 * ## Why a user session and not the bot
 *
 * The obvious way to feed the dashboard from the chat is the bot's own
 * `getUpdates`, and it cannot work — not because of a bug here, but because of a
 * deliberate Telegram rule. From the official FAQ:
 *
 * > **Why doesn't my bot see messages from other bots?** … we decided that bots
 * > will not be able to see messages from other bots regardless of mode.
 *
 * A bot's own message is a message from a bot. The game posts a suggestion with
 * the bot token (`godot/src/core/autoload/telegram_relay.gd`), so `getUpdates`
 * never returns it, and the Bot API has no method that reads a chat's history.
 * Measured on this machine: a message sent with the token exactly as the game
 * sends it stayed invisible to the poller, offset unmoved.
 *
 * A **user** client sees everything in its own chats, bots included. So the
 * inbox logs in as the owner and reads the chat the way his phone does.
 *
 * ## What counts as a suggestion
 *
 * The relay always signs its messages — `telegram_relay.gd` appends a blank
 * line and `— <author>`. That signature is the contract, and it is what separates
 * a player's idea from the server's own chatter in the same chat (`Aufruf 12
 * beendet`, `#7\n…`, the help text): those never carry it, so they are not
 * imported. A second guard is `isOwnMessage()` for anything this server sent
 * itself.
 *
 * ## Safety
 *
 * Inert unless `TELEGRAM_API_ID`/`TELEGRAM_API_HASH` are set **and** a session
 * file exists — so a server without a login never reaches for the account. The
 * session file lives in `data/` (git-ignored) and is the only credential.
 */

export interface TelegramInboxDeps {
  /** Directory holding the session and the poll watermark. */
  dataDir: string;
  store: Store;
  bus: EventEmitter;
  /** Exactly the view the dashboard shows, so the two agree. */
  viewOf: (id: number) => SuggestionView | null;
  onError?: (err: Error) => void;
}

/** How often the chat is read. A user session is a polite guest, not a bot. */
const POLL_MS = 10_000;
const ERROR_BACKOFF_MS = 60_000;

/** The relay's signature: the text, a blank line, then `— author`. */
const SIGNATURE = /^(.*)\n\n—\s*(.+)$/s;

/** Telegram's own ceiling; a longer idea is clipped rather than rejected. */
const MAX_TEXT = 4000;

export function inboxSessionPath(dataDir: string): string {
  return join(dataDir, 'telegram-user.session');
}

function inboxStatePath(dataDir: string): string {
  return join(dataDir, 'telegram-inbox.json');
}

/**
 * Whether the inbox may run at all.
 *
 * Both halves are required on purpose: credentials without a session would try to
 * log in from a background process, and a session without credentials cannot
 * connect. Absent either, the inbox stays off and says so in one line.
 */
export function inboxConfigured(dataDir: string): { ok: boolean; reason: string } {
  const id = (process.env.TELEGRAM_API_ID ?? '').trim();
  const hash = (process.env.TELEGRAM_API_HASH ?? '').trim();
  if (!id || !hash) return { ok: false, reason: 'TELEGRAM_API_ID/TELEGRAM_API_HASH fehlen' };
  try {
    readFileSync(inboxSessionPath(dataDir));
  } catch {
    return { ok: false, reason: 'keine Telegram-Sitzung — einmal `npm run telegram:login`' };
  }
  return { ok: true, reason: '' };
}

/** Splits a relayed message into idea and author. `null` when it carries no signature. */
export function parseRelayed(text: string): { text: string; author: string } | null {
  const match = SIGNATURE.exec(text.trim());
  if (!match) return null;
  const body = match[1].trim();
  const author = match[2].trim();
  if (!body || !author) return null;
  return { text: body.slice(0, MAX_TEXT), author: author.slice(0, 120) };
}

interface InboxState {
  /** Highest message id already looked at. A watermark, not a filter. */
  lastId: number;
}

export class TelegramInbox {
  private client: TelegramClient | null = null;
  private timer: NodeJS.Timeout | null = null;
  private stopped = false;
  private running = false;
  private lastError = '';
  private state: InboxState = { lastId: 0 };

  constructor(private readonly deps: TelegramInboxDeps) {
    this.loadState();
  }

  get configured(): boolean {
    return inboxConfigured(this.deps.dataDir).ok;
  }

  /** Starts reading the chat. Safe to call when nothing is configured. */
  start(): void {
    if (this.stopped || this.running) return;
    const check = inboxConfigured(this.deps.dataDir);
    if (!check.ok) {
      console.log(`[telegram-inbox] aus: ${check.reason}`);
      return;
    }
    this.running = true;
    void this.loop();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.running = false;
    try {
      await this.client?.disconnect();
    } catch {
      // A client that will not disconnect is not worth failing a shutdown over.
    }
  }

  private async loop(): Promise<void> {
    while (!this.stopped) {
      let wait = POLL_MS;
      try {
        const client = await this.connect();
        await this.drain(client);
        this.lastError = '';
      } catch (err) {
        // Polling repeats every few seconds; the same line ten times says no more
        // than the first and buries the line that does say something new.
        const message = (err as Error).message;
        if (message !== this.lastError) {
          this.lastError = message;
          console.warn(`[telegram-inbox] ${message}`);
        }
        wait = ERROR_BACKOFF_MS;
      }
      if (this.stopped) return;
      await new Promise((resolve) => {
        this.timer = setTimeout(resolve, wait);
      });
    }
  }

  private async connect(): Promise<TelegramClient> {
    if (this.client) return this.client;
    const session = new StringSession(readFileSync(inboxSessionPath(this.deps.dataDir), 'utf8'));
    const client = new TelegramClient(session, Number(process.env.TELEGRAM_API_ID), process.env.TELEGRAM_API_HASH ?? '', {
      connectionRetries: 2,
    });
    await client.connect();
    if (!(await client.isUserAuthorized())) {
      throw new Error('Sitzung nicht angemeldet — bitte `npm run telegram:login` wiederholen');
    }
    this.client = client;
    console.log('[telegram-inbox] Chat wird gelesen.');
    return client;
  }

  /**
   * Reads everything newer than the watermark and imports what carries a
   * signature.
   *
   * The watermark is advanced even for messages that are not imported: the chat
   * is full of the server's own answers, and re-reading them on every start would
   * be pointless work.
   */
  private async drain(client: TelegramClient): Promise<void> {
    const chatId = (process.env.TELEGRAM_CHAT_ID ?? '').trim();
    if (!chatId) return;
    const entity = await this.resolveChat(client);
    const limit = this.state.lastId > 0 ? { minId: this.state.lastId, limit: 100 } : { limit: 100 };
    let newest = this.state.lastId;
    let imported = 0;
    for await (const message of client.iterMessages(entity, limit)) {
      const id = Number(message.id);
      if (id > newest) newest = id;
      if (this.importOne(chatId, id, message.text ?? '')) imported += 1;
    }
    if (newest > this.state.lastId) {
      this.state.lastId = newest;
      this.saveState();
    }
    if (imported) console.log(`[telegram-inbox] ${imported} Vorschlag/Vorschläge übernommen.`);
  }

  /**
   * The chat to read, as an address a user client understands.
   *
   * `TELEGRAM_CHAT_ID` cannot be used directly and using it was a silent bug:
   * Telegram hands a bot the **user's** id as the chat id, so a user session
   * asked for that number resolves to `InputPeerSelf` — the owner's own Saved
   * Messages. The inbox connected, reported nothing wrong, and read the wrong
   * chat. The bot's own username is the address that resolves to the bot's chat.
   *
   * The dialog list is the fallback: the bot's id appears there as the peer of the
   * chat, and matching on it survives a rename of the bot's *display* name.
   */
  private async resolveChat(client: TelegramClient): Promise<EntityLike> {
    const bot = await getBotIdentity();
    try {
      return await client.getInputEntity(bot.username);
    } catch {
      // The username is not in the entity cache — usually a chat the account has
      // since left, or a rename. The dialog list still knows the peer by id.
      for await (const dialog of client.iterDialogs({})) {
        if (String(dialog.id) === String(bot.id) && dialog.entity) return dialog.entity;
      }
      throw new Error('Chat nicht gefunden — Bot-Name im Dashboard prüfen');
    }
  }

  /**
   * One message, one suggestion. `false` for everything that is not one.
   *
   * `clientKey` carries chat and message id, so a second read of the same message
   * finds the row it already made — which is what keeps a restart from
   * duplicating the last fifty messages of the chat.
   */
  private importOne(chatId: string, messageId: number, text: string): boolean {
    const parsed = parseRelayed(text);
    if (!parsed) return false;
    const { store, bus, viewOf } = this.deps;
    const result = store.createSuggestionOnce({
      text: parsed.text,
      author: parsed.author,
      source: 'telegram',
      category: classify(parsed.text),
      canonicalId: null,
      // `new`, and no run: the owner decides whether an idea is taken. Importing
      // that also queued it would start an agent per player message.
      status: 'new',
      // A Telegram message id is unique only within its chat, so the chat is part
      // of the key.
      clientKey: `tginbox:${chatId}:${messageId}`,
    });
    if (!result.created) return false;
    const view = viewOf(result.suggestion.id);
    if (view) bus.emit('event', { type: 'suggestion:new', suggestion: view });
    console.log(`[telegram-inbox] #${result.suggestion.id} aus dem Chat übernommen.`);
    return true;
  }

  private loadState(): void {
    try {
      const raw = JSON.parse(readFileSync(inboxStatePath(this.deps.dataDir), 'utf8')) as InboxState;
      this.state = { lastId: Number(raw.lastId) || 0 };
    } catch {
      this.state = { lastId: 0 };
    }
  }

  private saveState(): void {
    try {
      const path = inboxStatePath(this.deps.dataDir);
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, JSON.stringify(this.state));
    } catch {
      // Losing the watermark costs a re-read; the client key keeps it a no-op.
    }
  }
}