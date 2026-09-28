import type { RunRecord, Suggestion, SuggestionView } from '../src/shared/types';

/**
 * Telegram delivery for suggestions and run results.
 *
 * **What a message contains is intent, not decoration.** The owner reads the
 * chat on the phone, and a message of number plus suggestion text takes a second.
 * Emojis, category, score, author, timestamp and the dashboard address were all
 * noise — the address most of all: `DASHBOARD_URL` points at `localhost:5173`,
 * and from the phone localhost is the phone, so the link could never work.
 *
 * Telegram rather than Discord: the bot needs no channel and no webhook setup in
 * the server, and its configuration lives entirely in the environment. Two
 * Telegram quirks shape the code:
 *
 *  1. **A bot may not write first.** Telegram answers 403 with
 *     `bot can't initiate conversation` until the bot has received a message from
 *     the recipient. So the hint goes on every error instead of only into the
 *     log — without it, someone who never wrote to the bot just sees silence.
 *  2. **The token does not belong in the database.** A bot token is the key to
 *     the whole bot, unlike a Discord webhook that can only write to one channel.
 *     Hence `TELEGRAM_BOT_TOKEN` from the environment only, never from the
 *     dashboard settings — which also keeps it out of `backup/dashboard.json`.
 */

const API = 'https://api.telegram.org';

/** Telegram allows 4096 characters per message; above that it answers 400. */
const MAX_MESSAGE = 4096;

function token(): string {
  return (process.env.TELEGRAM_BOT_TOKEN ?? '').trim();
}

function chatId(): string {
  return (process.env.TELEGRAM_CHAT_ID ?? '').trim();
}

/** True when both values are set — the only precondition for sending. */
export function isConfigured(): boolean {
  return token() !== '' && chatId() !== '';
}

/**
 * Telegram parses the message as HTML when `parse_mode` is set. Suggestion text
 * comes from players, so an `&` or a `<b>` in it would tear the message apart.
 */
export function escapeHtml(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/** Clips to Telegram's limit and keeps the mark that something was cut. */
function clip(value: string, limit = MAX_MESSAGE): string {
  return value.length > limit ? `${value.slice(0, limit - 1)}…` : value;
}

/**
 * A message to the configured chat. A failure is never an exception: the callers
 * sit in the request path of a player submission, and a broken channel must not
 * lose a suggestion — it is stored anyway.
 */
/** How often a send is retried before the caller is told it failed. */
const SEND_ATTEMPTS = 3;

/**
 * Sends one message, retrying a few times.
 *
 * The retry is not politeness, it is the fix for a real symptom: `tsx watch`
 * restarts the server on every save, and the process that comes up first sends
 * into a connection Telegram has not finished tearing down. Node reports that as
 * a bare `fetch failed` — no status, no message, indistinguishable from a real
 * network outage. One retry resolves it; without one, the answer to `/task` is
 * lost while the task itself runs, and the owner cannot tell the two apart.
 */
export async function sendMessage(text: string): Promise<{ ok: boolean; error?: string }> {
  if (!isConfigured()) {
    return { ok: false, error: 'Kein Telegram konfiguriert (TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID)' };
  }
  let last = 'unbekannter Fehler';
  for (let attempt = 0; attempt < SEND_ATTEMPTS; attempt += 1) {
    try {
      const res = await fetch(`${API}/bot${token()}/sendMessage`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          chat_id: chatId(),
          text: clip(text),
          parse_mode: 'HTML',
          // The suggestion text is player input; a URL in it must not open a
          // preview on its own.
          disable_web_page_preview: true,
        }),
      });
      if (res.ok) return { ok: true };
      const raw = await res.text().catch(() => '');
      last = explain(res.status, raw);
      // A rejected message will be rejected identically on the next try — only a
      // torn connection or a 5xx is worth repeating.
      if (res.status < 500) return { ok: false, error: last };
    } catch (err) {
      last = (err as Error).message;
    }
    if (attempt < SEND_ATTEMPTS - 1) await new Promise((r) => setTimeout(r, 800 * (attempt + 1)));
  }
  return { ok: false, error: last };
}

/** Turns Telegram errors into something one can actually fix. */
function explain(status: number, raw: string): string {
  const detail = raw.slice(0, 200);
  if (status === 401) {
    return `Telegram 401: Token ungültig. ${detail}`;
  }
  if (status === 403) {
    // By far the most common error, and without the hint people come to think
    // it is the normal case.
    return `Telegram 403: Der Bot darf dem Chat nicht schreiben — hat er schon eine Nachricht von dir bekommen? ${detail}`;
  }
  if (status === 400) {
    return `Telegram 400: Anfrage abgelehnt, meist eine falsche chat_id. ${detail}`;
  }
  return `Telegram ${status}: ${detail}`;
}

/** Text of a new submission: number and suggestion only.
 *
 * Deliberately without emojis, category, score, author and time. The owner reads
 * this on the phone, and every line he does not need is one he has to skip past.
 * A timestamp sits above every Telegram message anyway, and the dashboard
 * address is unreachable from the phone.
 */
export function buildSuggestionText(suggestion: SuggestionView, _dashboardUrl: string): string {
  return clip(`#${suggestion.id}\n${escapeHtml(suggestion.text)}`);
}

export async function notifyNewSuggestion(
  suggestion: SuggestionView,
  dashboardUrl: string,
): Promise<{ ok: boolean; error?: string }> {
  return sendMessage(buildSuggestionText(suggestion, dashboardUrl));
}

/**
 * A run's result. Unlike Discord there is no `updateSuggestionMessage` here:
 * Telegram can edit a message afterwards, but the message id would have to live
 * in the database, and that column is called `discordMessageId`. A second column
 * is a schema change a second channel is not worth; the status change stays in
 * the chat from here on.
 */
export async function notifyRunResult(
  suggestion: Suggestion,
  run: RunRecord,
  _dashboardUrl: string,
): Promise<{ ok: boolean; error?: string }> {
  // Number, outcome, commit. The commit is the one thing the owner truly needs
  // after a run: it is where to look at what the agent did.
  const line = run.status === 'succeeded' ? 'umgesetzt' : `fehlgeschlagen (${escapeHtml(run.status)})`;
  return sendMessage(
    `#${suggestion.id} ${line}${run.commitHash ? ` ${run.commitHash}` : ''}`,
  );
}

/** The dashboard's "Test senden" button — the same check as in real operation. */
export async function sendTest(_dashboardUrl: string): Promise<{ ok: boolean; error?: string }> {
  return sendMessage('Singular 80: Telegram ist verbunden.');
}

// --- Commands from the chat --------------------------------------------------

/** A Telegram bot polls `getUpdates`; only one poller is allowed. */
const API_TIMEOUT = 30;

export interface TelegramUpdate {
  update_id: number;
  message?: {
    message_id: number;
    text?: string;
    date: number;
    chat: { id: number; type: string };
    from?: { id: number; is_bot?: boolean };
  };
}

export interface Command {
  /** Without `/`, lowercase: `run`. Empty when the message was not a command. */
  name: string;
  args: string[];
  raw: string;
}

export const HELP_TEXT = [
  'Singular 80 — du steuerst das Dashboard aus diesem Chat.',
  '',
  '/task <Text> — freier Auftrag, läuft sofort (mehrzeilig: /task und dann den Text)',
  '/list — offene Vorschläge',
  '/status 12 — ein Vorschlag mit seinen Läufen',
  '/run 12 — OpenCode-Lauf zu Vorschlag 12 starten',
  '/approve 12, /reject 12 — Status setzen',
  '/queue — Warteschlange und Spuren',
  '/help — diese Liste',
].join('\n');

/**
 * Splits a message into a command. Anything without a leading `/` is not a
 * command — the bot does not answer normal chat, or it would reply to every
 * single word with this list.
 */
export function parseCommand(text: string): Command | null {
  const raw = text.trim();
  if (!raw.startsWith('/')) return null;
  // `/run@Singular80Bot 12` is Telegram syntax; the bot name is optional.
  const [head, ...rest] = raw.slice(1).split(/\s+/);
  const name = (head ?? '').split('@')[0].toLowerCase();
  if (!name) return null;
  return { name, args: rest, raw };
}

/**
 * Who may run commands. A run starts an opencode session in the working tree, so
 * "owner only" is a condition, not a courtesy: anyone who can write to the bot
 * could otherwise have code written for them. The list holds **user** ids, not
 * the chat id — in a group the chat id would be shared by everyone in it.
 */
export function allowedUserIds(): Set<string> {
  const raw = [chatId(), ...(process.env.TELEGRAM_ALLOWED_USER_IDS ?? '').split(',')]
    .map((v) => v.trim())
    .filter(Boolean);
  return new Set(raw);
}

/** Checks where a message came from. Bots and strangers are rejected. */
export function isAuthorized(update: TelegramUpdate): boolean {
  const message = update.message;
  if (!message) return false;
  if (message.from?.is_bot) return false;
  const allowed = allowedUserIds();
  if (allowed.size === 0) return false;
  // The chat id counts too: in a private chat it is the one value guaranteed
  // to be present.
  if (allowed.has(String(message.chat.id))) return true;
  return message.from ? allowed.has(String(message.from.id)) : false;
}

/** Pulls a suggestion number out of a command line, otherwise `null`. */
export function suggestionIdArg(args: string[]): number | null {
  const first = (args[0] ?? '').trim();
  if (!/^\d+$/.test(first)) return null;
  const id = Number(first);
  return id > 0 ? id : null;
}

export interface RawUpdate {
  ok: boolean;
  result?: TelegramUpdate[];
  error?: string;
}

/**
 * Long-polling. `timeout` makes Telegram hold the request open for up to 30
 * seconds, so an empty pass is not a request storm. `offset` is the watermark
 * that marks updates as read.
 */
export async function getUpdates(offset: number, timeout = API_TIMEOUT): Promise<RawUpdate> {
  if (!token()) return { ok: false, error: 'Kein TELEGRAM_BOT_TOKEN' };
  // Retried like `sendMessage`: the first poll after a restart is the one that
  // trips over a socket Telegram is still tearing down, and a poll loop that
  // gives up on the first failure then backs off for ten seconds and says
  // nothing more. A 409 is *not* retried here — that means a second poller
  // exists, and hammering would only extend the conflict.
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const res = await fetch(`${API}/bot${token()}/getUpdates?offset=${offset}&timeout=${timeout}`, {
        method: 'GET',
        headers: { 'Content-Type': 'application/json' },
      });
      if (!res.ok) {
        const raw = await res.text().catch(() => '');
        const error = `getUpdates ${res.status}: ${raw.slice(0, 200)}`;
        if (res.status < 500) return { ok: false, error };
        if (attempt === 0) await new Promise((r) => setTimeout(r, 1200));
        continue;
      }
      const data = (await res.json().catch(() => null)) as
        | { ok?: boolean; result?: TelegramUpdate[] }
        | null;
      if (!data?.ok) return { ok: false, error: 'getUpdates: unerwartete Antwort' };
      return { ok: true, result: data.result ?? [] };
    } catch (err) {
      if (attempt === 0) await new Promise((r) => setTimeout(r, 1200));
      else return { ok: false, error: (err as Error).message };
    }
  }
  return { ok: false, error: 'getUpdates: mehrfach fehlgeschlagen' };
}
