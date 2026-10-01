import type { EventEmitter } from 'node:events';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import type { RunRecord, SuggestionStatus, SuggestionView } from '../src/shared/types';
import * as telegram from './telegram';
import type { Store } from './db';
import type { Runner } from './runner';

/**
 * The operator steers the queue from the Telegram chat.
 *
 * The bot is deliberately **not** a second server: it is handed the store and the
 * runner and uses the same objects as the HTTP routes. A chat with its own queue
 * would be the polite way to build two truths — and then the chat shows
 * something the dashboard does not know.
 *
 * A run starts an opencode session in the working tree. So `isAuthorized()` is
 * the door: without an allowed id the bot does nothing, not even a reply.
 *
 * ## A player suggestion arrives looking like the bot itself
 *
 * The game posts with **this bot's token** (`telegram_relay.gd`), so a player
 * suggestion comes back through `getUpdates` indistinguishable from one of our
 * own messages: `from.is_bot = true`. The old rule `is_bot ⇒ stranger ⇒ drop`
 * therefore discarded every player suggestion — the chat showed them, the
 * dashboard never did, and nothing anywhere said so.
 *
 * So bot-authored is no longer a verdict. It is split by **whether this server
 * sent it**, which `telegram.isOwnMessage()` answers from the ids the send path
 * recorded. Ours stays silent; anything else in the configured chat is a player
 * suggestion and gets imported.
 */

export interface TelegramBotDeps {
  /** Repository root; the polling state lives in `data/` next to the database. */
  projectRoot: string;
  /**
   * The configured chat, for the suggestion `clientKey`. A Telegram message id is
   * unique per chat only, so the key needs it.
   */
  chatId: string;
  store: Store;
  runner: Runner | null;
  bus: EventEmitter;
  dashboardUrl: string;
  /** Exactly the view the dashboard shows, so the two agree. */
  viewOf: (id: number) => SuggestionView | null;
  /** Starts a run. Shared with the `/implement` route. */
  startRun: (id: number) => { ok: boolean; error?: string; runId?: string };
  /**
   * Creates a free order and queues it immediately. `POST /api/tasks` uses the
   * same function, so an order from the chat and one from the dashboard take the
   * same path.
   */
  createTask: (
    text: string,
  ) => Promise<{ ok: boolean; error?: string; runId?: string; suggestionId?: number }>;
  /** Sets the status and reports the change the way the dashboard does. */
  setStatus: (id: number, status: SuggestionStatus) => { ok: boolean; error?: string };
  onError?: (err: Error) => void;
}

const POLL_MS = 2_000;
const ERROR_BACKOFF_MS = 10_000;

/**
 * Telegram's `getUpdates` is a single-consumer queue: while one request is open,
 * a second gets HTTP 409 `terminated by other getUpdates request`, and Telegram
 * kills the *first* one too. So any second poller — a second server on the same
 * token, or a restart whose predecessor has not let go yet — makes the long poll
 * fail.
 *
 * This is why the offset is written to disk before the next poll rather than
 * after it: an offset that lives only in memory is 0 again after every restart,
 * and Telegram then replays every command the bot has not seen confirmed. A
 * `/run 12` would execute a second time. Restarting the server is routine here
 * (`tsx watch` does it on every save), so that was a real way to start a second
 * opencode run for the same suggestion.
 */
const STATE_FILE = 'telegram-bot.json';

interface PersistedState {
  offset: number;
  /** update_ids already answered, so a replay is recognised. */
  seen: number[];
}

export class TelegramBot {
  private offset = 0;
  private seen = new Set<number>();
  private stopped = false;
  private timer: NodeJS.Timeout | null = null;
  private running = false;
  private lastError = '';
  /** Set when `/task` arrived without text, waiting for the next message. */
  private awaitingTaskText = false;

  constructor(private readonly deps: TelegramBotDeps) {
    this.load();
  }

  start(): void {
    if (!telegram.isConfigured() || this.running) return;
    this.running = true;
    void this.loop();
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.running = false;
  }

  private async loop(): Promise<void> {
    while (!this.stopped) {
      let wait = POLL_MS;
      try {
        const page = await telegram.getUpdates(this.offset);
        if (!page.ok) {
          this.report(page.error ?? 'unbekannter Fehler');
          wait = ERROR_BACKOFF_MS;
        } else if (page.result?.length) {
          // `handle()` records the update itself, so the loop only has to feed
          // it. Two places marking the same thing is one place too many.
          for (const update of page.result) {
            await this.handle(update);
          }
        } else {
          this.lastError = '';
        }
      } catch (err) {
        this.report((err as Error).message);
        wait = ERROR_BACKOFF_MS;
      }
      if (this.stopped) return;
      await new Promise((resolve) => {
        this.timer = setTimeout(resolve, wait);
      });
    }
  }

  /**
   * Logs a failure, but only when it differs from the one before. A polling
   * error repeats every few seconds for as long as it lasts; the same line ten
   * times tells the owner no more than the first, and buries the line that does
   * say something new.
   */
  private report(error: string): void {
    if (this.lastError === error) return;
    this.lastError = error;
    this.deps.onError?.(new Error(`Telegram-Abfrage: ${error}`));
  }

  /** Keeps the replay guard bounded; 200 ids is far more than any backlog. */
  private trimSeen(): void {
    if (this.seen.size <= 200) return;
    const keep = [...this.seen].slice(-200);
    this.seen = new Set(keep);
  }

  private get statePath(): string {
    return join(this.deps.projectRoot, 'data', STATE_FILE);
  }

  private load(): void {
    try {
      const raw = JSON.parse(readFileSync(this.statePath, 'utf8')) as PersistedState;
      this.offset = Number(raw.offset) || 0;
      this.seen = new Set(Array.isArray(raw.seen) ? raw.seen.map(Number) : []);
    } catch {
      // No state yet, or unreadable: start from 0. Telegram still holds every
      // unconfirmed message, so nothing is lost — they are simply offered again.
    }
  }

  private save(): void {
    try {
      mkdirSync(dirname(this.statePath), { recursive: true });
      writeFileSync(this.statePath, JSON.stringify({ offset: this.offset, seen: [...this.seen] }));
    } catch {
      // A missing state file only costs a replay guard, never a command.
    }
  }

  /**
   * Handles one update. Marking the update as seen happens here, not in the
   * polling loop, so the replay guard holds for every caller.
   *
   * The order is deliberate: mark, persist, then act. A crash in between loses
   * one command rather than repeating it — a lost `/run` is recoverable, a
   * repeated one starts a second opencode session for the same suggestion.
   */
  async handle(update: telegram.TelegramUpdate): Promise<void> {
    if (this.seen.has(update.update_id)) return;
    const message = update.message;
    const text = message?.text;
    if (!text || !message) {
      this.markSeen(update.update_id);
      return;
    }
    if (message.from?.is_bot) {
      // Our own message coming back. Telegram does deliver these to the chat but
      // not through `getUpdates`, so in practice this is rare — and nothing here
      // may act on it either way. A player suggestion cannot arrive this way at
      // all: the game posts with this same token, and bots never see messages
      // from bots. `TelegramInbox` reads those, as a user, not as this bot.
      this.markSeen(update.update_id);
      return;
    }
    if (!telegram.isAuthorized(update)) {
      // No reply: an acknowledgement tells a stranger the bot exists and
      // invites them to try. The update is still marked, so Telegram stops
      // offering it.
      this.markSeen(update.update_id);
      return;
    }
    const command = telegram.parseCommand(text);
    if (!command) {
      // A message that is not a command is only interesting when `/task` asked
      // for the text to follow separately. Everything else is chatter, and the
      // bot stays quiet.
      if (this.awaitingTaskText) {
        this.awaitingTaskText = false;
        this.markSeen(update.update_id);
        await telegram.sendMessage(await this.answer({ name: 'task', args: [text.trim()], raw: text }));
        return;
      }
      this.markSeen(update.update_id);
      return;
    }
    this.markSeen(update.update_id);
    // `/task` with no text opens a second step instead of failing outright: a
    // multi-line order pasted from a phone arrives across several messages, and
    // a command that rejects what it received teaches the owner nothing about
    // what to send instead.
    if (command.name === 'task' && command.args.length === 0) {
      this.awaitingTaskText = true;
      await telegram.sendMessage('Schick den Auftrag als nächste Nachricht.');
      return;
    }
    // Any other command cancels the pending text. Without this, `/task` followed
    // by `/help` and then an ordinary sentence would silently start an agent run
    // on that sentence.
    this.awaitingTaskText = false;
    await telegram.sendMessage(await this.answer(command));
  }

  private markSeen(updateId: number): void {
    this.seen.add(updateId);
    this.trimSeen();
    this.offset = updateId + 1;
    this.save();
  }

  private async answer(command: telegram.Command): Promise<string> {
    const { store, runner, viewOf, dashboardUrl } = this.deps;
    switch (command.name) {
      case 'help':
      case 'start':
      case 'h': {
        // `/start` is the command Telegram itself expects, so it must not mean
        // run control — otherwise a stray /start launches an agent.
        return telegram.HELP_TEXT;
      }
      case 'list': {
        const open = store
          .listSuggestions()
          .filter((s) => s.status === 'new' || s.status === 'approved')
          .slice(0, 15);
        if (!open.length) return 'Keine offenen Vorschläge.';
        const lines = open.map((s) => `#${s.id} ${telegram.escapeHtml(s.text.slice(0, 70))}`);
        return ['Offene Vorschläge', '', ...lines, '', '/run 12 startet einen Lauf.'].join('\n');
      }
      case 'status': {
        const id = telegram.suggestionIdArg(command.args);
        if (!id) return 'Welcher Vorschlag? /status 12';
        const view = viewOf(id);
        if (!view) return `Vorschlag #${id} gibt es nicht.`;
        const runs = (runner?.listSuggestionRuns(id) ?? store.listRuns(200).filter((r) => r.suggestionId === id)).slice(0, 3);
        const lines = [`#${view.id} ${view.status}`, '', telegram.escapeHtml(view.text.slice(0, 900))];
        for (const run of runs) {
          lines.push(`${run.status}${run.commitHash ? ` ${run.commitHash}` : ''}`);
        }
        return lines.join('\n');
      }
      case 'run': {
        const id = telegram.suggestionIdArg(command.args);
        if (!id) return 'Welcher Vorschlag? /run 12';
        if (!runner) return 'Der Runner ist abgeschaltet.';
        if (runner.isPaused()) return 'Die Warteschlange ist pausiert. Läuft nach dem Fortsetzen.';
        const result = this.deps.startRun(id);
        if (!result.ok) return telegram.escapeHtml(result.error ?? 'unbekannter Fehler');
        // No run id: it is in the dashboard and on GitHub, and the chat is
        // kept to the minimum.
        return `Aufruf ${id} gestartet`;
      }
      case 'task': {
        // A free-form order: not a suggestion from a player, but a direct
        // instruction. It is stored as one anyway, so scope prediction,
        // retries, commit protection and the history keep working unchanged.
        if (!runner) return 'Der Runner ist abgeschaltet.';
        if (runner.isPaused()) return 'Die Warteschlange ist pausiert. Läuft nach dem Fortsetzen.';
        const text = command.args.join(' ').trim();
        const result = await this.deps.createTask(text);
        if (!result.ok) return telegram.escapeHtml(result.error ?? 'unbekannter Fehler');
        return `Aufruf ${result.suggestionId} gestartet`;
      }
      case 'approve':
      case 'reject': {
        const id = telegram.suggestionIdArg(command.args);
        if (!id) return `Welcher Vorschlag? /${command.name} 12`;
        const status: SuggestionStatus = command.name === 'approve' ? 'approved' : 'rejected';
        const result = this.deps.setStatus(id, status);
        if (!result.ok) return telegram.escapeHtml(result.error ?? 'unbekannter Fehler');
        return `#${id} ist jetzt ${status}.`;
      }
      case 'queue': {
        if (!runner) return 'Der Runner ist abgeschaltet.';
        const state = runner.queueState();
        const lines = ['Warteschlange', `Spuren: ${state.activeRuns.length}/${runner.capacity()}`];
        if (runner.isPaused()) lines.push('pausiert');
        for (const run of state.queue.slice(0, 10)) {
          lines.push(`#${run.suggestionId} ${run.status}`);
        }
        if (!state.queue.length) lines.push('(leer)');
        return lines.join('\n');
      }
      default:
        return `Unbekannt: /${telegram.escapeHtml(command.name)}\n\n${telegram.HELP_TEXT}`;
    }
  }
}

export type { RunRecord };
