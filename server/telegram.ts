import type { RunRecord, Suggestion, SuggestionView } from '../src/shared/types';
import { CATEGORY_LABELS } from './discord';

/**
 * Telegram-Zustellung für Vorschläge und Runner-Ergebnisse.
 *
 * Warum Telegram und nicht Discord: der Bot braucht keinen Kanal und kein
 * Webhook-Setup im Server, und die Konfiguration steht vollständig in der
 * Umgebung. Zwei Telegram-Eigenheiten, die den Aufbau bestimmen:
 *
 *  1. **Ein Bot darf niemandem zuerst schreiben.** Telegram antwortet mit 403
 *     und dem Text `bot can't initiate conversation`, bis der Bot eine Nachricht
 *     vom Empfänger bekommen hat. Deshalb steht der Hinweis auf jeden Fehler,
 *     statt ihn nur ins Log zu schreiben — wer den Bot in Telegram nicht
 *     angeschrieben hat, sieht sonst nur ein stummes Nein.
 *  2. **Der Token gehört nicht in die Datenbank.** Anders als ein
 *     Discord-Webhook, der nur in einen Kanal schreiben darf, ist ein Bot-Token
 *     der Schlüssel zum ganzen Bot. Deshalb `TELEGRAM_BOT_TOKEN` nur aus der
 *     Umgebung und niemals aus den Dashboard-Einstellungen; damit kann er auch
 *     nicht in `backup/dashboard.json` landen.
 */

const API = 'https://api.telegram.org';

/** Telegram nimmt 4096 Zeichen pro Nachricht; darüber antwortet es mit 400. */
const MAX_MESSAGE = 4096;

const STATUS_LABELS: Record<string, string> = {
  new: '🆕 Neu',
  approved: '👍 Genehmigt',
  rejected: '❌ Abgelehnt',
  implementing: '🔧 In Umsetzung',
  implemented: '✅ Umgesetzt',
  failed: '⚠️ Fehlgeschlagen',
};

function token(): string {
  return (process.env.TELEGRAM_BOT_TOKEN ?? '').trim();
}

function chatId(): string {
  return (process.env.TELEGRAM_CHAT_ID ?? '').trim();
}

/** True, wenn beide Werte gesetzt sind — die einzige Voraussetzung fürs Senden. */
export function isConfigured(): boolean {
  return token() !== '' && chatId() !== '';
}

/**
 * Telegram parst die Nachricht als HTML, wenn `parse_mode` gesetzt ist. Der
 * Vorschlagstext kommt von Spielern und darf deshalb nicht als Markup
 * durchgehen: ein `&` oder ein `<b>` im Text würde die Nachricht zerlegen.
 */
export function escapeHtml(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/** Kürzt auf Telegrams Grenze und behält den Hinweis, dass etwas fehlt. */
function clip(value: string, limit = MAX_MESSAGE): string {
  return value.length > limit ? `${value.slice(0, limit - 1)}…` : value;
}

/**
 * Eine Nachricht an den konfigurierten Chat. Ein Fehler ist nie ein Exception:
 * die Aufrufer sitzen im Request-Pfad einer Spielerkommentierung, und ein
 * defekter Kanal darf einen Vorschlag nicht verlieren — er wird ohnehin
 * gespeichert.
 */
export async function sendMessage(text: string): Promise<{ ok: boolean; error?: string }> {
  if (!isConfigured()) {
    return { ok: false, error: 'Kein Telegram konfiguriert (TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID)' };
  }
  try {
    const res = await fetch(`${API}/bot${token()}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        chat_id: chatId(),
        text: clip(text),
        parse_mode: 'HTML',
        // Der Vorschlagstext ist Spielereingabe; eine URL darin soll nicht
        // eigenmächtig eine Vorschau auslösen.
        disable_web_page_preview: true,
      }),
    });
    if (!res.ok) {
      const raw = await res.text().catch(() => '');
      return { ok: false, error: explain(res.status, raw) };
    }
    return { ok: true };
  } catch (err) {
    return { ok: false, error: (err as Error).message };
  }
}

/** Übersetzt die Telegram-Fehler in etwas, das man tatsächlich beheben kann. */
function explain(status: number, raw: string): string {
  const detail = raw.slice(0, 200);
  if (status === 401) {
    return `Telegram 401: Token ungültig. ${detail}`;
  }
  if (status === 403) {
    // Der mit Abstand häufigste Fehler, und ohne ihn passiert zu denken,
    // dieser Fehler ist der normale Fall.
    return `Telegram 403: Der Bot darf dem Chat nicht schreiben — hat er schon eine Nachricht von dir bekommen? ${detail}`;
  }
  if (status === 400) {
    return `Telegram 400: Anfrage abgelehnt, meist eine falsche chat_id. ${detail}`;
  }
  return `Telegram ${status}: ${detail}`;
}

/** Der Text einer neuen Einreichung, mit denselben Angaben wie der Discord-Embed. */
export function buildSuggestionText(suggestion: SuggestionView, dashboardUrl: string): string {
  const lines = [
    `🎮 <b>Vorschlag #${suggestion.id}</b> — ${STATUS_LABELS[suggestion.status] ?? suggestion.status}`,
    '',
    escapeHtml(suggestion.text),
    '',
    `🏷 ${CATEGORY_LABELS[suggestion.category] ?? suggestion.category} · ⭐ ${suggestion.score} · 👍 ${suggestion.votes}`,
  ];
  if (suggestion.clusterSize > 1) {
    lines.push(`🔗 ${suggestion.clusterSize} ähnliche im Cluster #${suggestion.canonicalId ?? suggestion.id}`);
  }
  lines.push(
    `👤 ${escapeHtml(suggestion.author)} · 📱 ${suggestion.source} · 🕐 ${new Date(
      suggestion.createdAt,
    ).toLocaleString('de-DE')}`,
  );
  lines.push(`${dashboardUrl}#suggestion-${suggestion.id}`);
  return clip(lines.join('\n'));
}

export async function notifyNewSuggestion(
  suggestion: SuggestionView,
  dashboardUrl: string,
): Promise<{ ok: boolean; error?: string }> {
  return sendMessage(buildSuggestionText(suggestion, dashboardUrl));
}

/**
 * Das Ergebnis eines Laufs. Anders als bei Discord gibt es hier kein
 * `updateSuggestionMessage`: Telegram kann eine Nachricht zwar nachträglich
 * bearbeiten, die Nachrichten-Id müsste dafür aber in der Datenbank stehen —
 * und die Spalte heißt `discordMessageId`. Eine eigene Spalte wäre ein
 * Schemawechsel, den ein zusätzlicher Kanal nicht wert ist; der Statuswechsel
 * steht stattdessen ab hier im Chat.
 */
export async function notifyRunResult(
  suggestion: Suggestion,
  run: RunRecord,
  dashboardUrl: string,
): Promise<{ ok: boolean; error?: string }> {
  const ok = run.status === 'succeeded';
  const head = ok
    ? `✅ <b>Vorschlag #${suggestion.id} wurde umgesetzt</b>${run.commitHash ? ` (<code>${escapeHtml(run.commitHash)}</code>)` : ''}`
    : `⚠️ <b>Umsetzung von Vorschlag #${suggestion.id} fehlgeschlagen</b> (${escapeHtml(run.status)})`;
  const lines = [
    head,
    '',
    escapeHtml(suggestion.text.slice(0, 800)),
    '',
    `Run <code>${escapeHtml(run.id)}</code> · 💰 ${
      run.cost != null ? `$${run.cost.toFixed(4)}` : '—'
    }`,
    `${dashboardUrl}#suggestion-${suggestion.id}`,
  ];
  if (run.resultSummary) {
    lines.splice(2, 0, `<i>${escapeHtml(run.resultSummary.slice(0, 400))}</i>`, '');
  }
  return sendMessage(clip(lines.join('\n')));
}

/** Der Knopf „Test senden" im Dashboard — dieselbe Prüfung wie im echten Betrieb. */
export async function sendTest(dashboardUrl: string): Promise<{ ok: boolean; error?: string }> {
  return sendMessage(
    [
      '✅ <b>Singular 80</b> — Telegram ist verbunden.',
      `Neue Vorschläge aus dem Spiel landen hier. ${dashboardUrl}`,
    ].join('\n\n'),
  );
}

// --- Befehle aus dem Chat ----------------------------------------------------

/** Ein Telegram-Bot pollt `getUpdates`; es ist nur ein Poller erlaubt. */
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
  /** Ohne `/`, klein: `run`. Leer, wenn die Nachricht kein Befehl war. */
  name: string;
  args: string[];
  raw: string;
}

export const HELP_TEXT = [
  '<b>Singular 80</b> — du steuerst das Dashboard aus diesem Chat.',
  '',
  '<code>/list</code> — offene Vorschläge',
  '<code>/status 12</code> — ein Vorschlag mit seinen Läufen',
  '<code>/run 12</code> — OpenCode-Lauf zu Vorschlag 12 starten',
  '<code>/approve 12</code> · <code>/reject 12</code> — Status setzen',
  '<code>/queue</code> — Warteschlange und Spuren',
  '<code>/help</code> — diese Liste',
].join('\n');

/**
 * Zerlegt eine Nachricht in einen Befehl. Alles ohne führendes `/` ist keine
 * Befehlsnachricht — der Bot beantwortet normalen Chat nicht, sonst antwortet
 * er auf jedes Wort mit einer Liste.
 */
export function parseCommand(text: string): Command | null {
  const raw = text.trim();
  if (!raw.startsWith('/')) return null;
  // `/run@Singular80Bot 12` ist Telegram-Syntax; der Bot-Name ist optional.
  const [head, ...rest] = raw.slice(1).split(/\s+/);
  const name = (head ?? '').split('@')[0].toLowerCase();
  if (!name) return null;
  return { name, args: rest, raw };
}

/**
 * Wer Befehle ausführen darf. Ein Run startet eine OpenCode-Sitzung im
 * Arbeitsbaum, also ist „nur der Besitzer" keine Höflichkeit, sondern die
 * Bedingung: jeder, der dem Bot schreiben kann, könnte sonst Code schreiben
 * lassen. Die Liste ist die **Benutzer**-Id, nicht die Chat-Id — in Gruppen
 * wäre die Chat-Id sonst geteilt.
 */
export function allowedUserIds(): Set<string> {
  const raw = [chatId(), ...(process.env.TELEGRAM_ALLOWED_USER_IDS ?? '').split(',')]
    .map((v) => v.trim())
    .filter(Boolean);
  return new Set(raw);
}

/** Prüft die Herkunft einer Nachricht. Bots und Fremde werden abgewiesen. */
export function isAuthorized(update: TelegramUpdate): boolean {
  const message = update.message;
  if (!message) return false;
  if (message.from?.is_bot) return false;
  const allowed = allowedUserIds();
  if (allowed.size === 0) return false;
  // Die Chat-Id zählt ebenfalls: sie ist die einzige Angabe, die bei einem
  // Einzelchat garantiert vorhanden ist.
  if (allowed.has(String(message.chat.id))) return true;
  return message.from ? allowed.has(String(message.from.id)) : false;
}

/** Holt aus einer Befehlszeile eine Vorschlagsnummer, sonst `null`. */
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
 * Long-Polling. `timeout` veranlasst Telegram, die Anfrage bis zu 30 Sekunden
 * offen zu halten, sodass ein leerer Durchlauf kein Request-Sturm ist.
 * `offset` ist das Wasserzeichen: Telegram markiert damit Updates als gelesen.
 */
export async function getUpdates(offset: number, timeout = API_TIMEOUT): Promise<RawUpdate> {
  if (!token()) return { ok: false, error: 'Kein TELEGRAM_BOT_TOKEN' };
  try {
    const res = await fetch(`${API}/bot${token()}/getUpdates?offset=${offset}&timeout=${timeout}`, {
      method: 'GET',
      headers: { 'Content-Type': 'application/json' },
    });
    if (!res.ok) {
      const raw = await res.text().catch(() => '');
      return { ok: false, error: `getUpdates ${res.status}: ${raw.slice(0, 200)}` };
    }
    const data = (await res.json().catch(() => null)) as { ok?: boolean; result?: TelegramUpdate[] } | null;
    if (!data?.ok) return { ok: false, error: 'getUpdates: unerwartete Antwort' };
    return { ok: true, result: data.result ?? [] };
  } catch (err) {
    return { ok: false, error: (err as Error).message };
  }
}
