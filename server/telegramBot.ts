import type { EventEmitter } from 'node:events';
import type { RunRecord, SuggestionStatus, SuggestionView } from '../src/shared/types';
import * as telegram from './telegram';
import type { Store } from './db';
import type { Runner } from './runner';

/**
 * Der Betreiber steuert die Warteschlange aus dem Telegram-Chat.
 *
 * Der Bot ist bewusst **kein** zweiter Server: er bekommt Store und Runner
 * übergeben und benutzt dieselben Objekte wie die HTTP-Routen. Ein Chat,
 * der eine eigene Warteschlange hätte, wäre die höfliche Art, zwei
 * Wahrheiten zu bauen — der Chat zeigt dann etwas an, das das Dashboard nicht
 * kennt.
 *
 * Ein Run startet eine OpenCode-Sitzung im Arbeitsbaum. Deshalb ist
 * `isAuthorized()` die Tür: ohne erlaubte Id tut der Bot nichts, auch nicht
 * antworten.
 */

export interface TelegramBotDeps {
  store: Store;
  runner: Runner | null;
  bus: EventEmitter;
  dashboardUrl: string;
  /** Genau die Sicht, die das Dashboard zeigt — damit beide übereinstimmen. */
  viewOf: (id: number) => SuggestionView | null;
  /** Startet einen Lauf. Wird von der Route `/implement` mit benutzt. */
  startRun: (id: number) => { ok: boolean; error?: string; runId?: string };
  /** Setzt den Status und meldet die Änderung wie das Dashboard. */
  setStatus: (id: number, status: SuggestionStatus) => { ok: boolean; error?: string };
  onError?: (err: Error) => void;
}

const POLL_MS = 2_000;
const ERROR_BACKOFF_MS = 10_000;

export class TelegramBot {
  private offset = 0;
  private stopped = false;
  private timer: NodeJS.Timeout | null = null;
  private running = false;

  constructor(private readonly deps: TelegramBotDeps) {}

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
          this.deps.onError?.(new Error(`Telegram-Abfrage: ${page.error}`));
          wait = ERROR_BACKOFF_MS;
        } else if (page.result?.length) {
          for (const update of page.result) {
            // Das Wasserzeichen erst **nach** der Abarbeitung setzen: stürzt
            // die Verarbeitung ab, wiederholt Telegram die Nachricht, statt sie
            // ungeschen zu verschlucken.
            await this.handle(update);
            this.offset = update.update_id + 1;
          }
        }
      } catch (err) {
        this.deps.onError?.(err as Error);
        wait = ERROR_BACKOFF_MS;
      }
      if (this.stopped) return;
      await new Promise((resolve) => {
        this.timer = setTimeout(resolve, wait);
      });
    }
  }

  /** Verarbeitet eine Aktualisierung. Öffentlich für die Tests. */
  async handle(update: telegram.TelegramUpdate): Promise<void> {
    const text = update.message?.text;
    if (!text) return;
    if (!telegram.isAuthorized(update)) {
      // Keine Antwort: eine Rückmeldung an Fremde bestätigt nur, dass der Bot
      // existiert, und lädt zum Durchprobieren ein.
      return;
    }
    const command = telegram.parseCommand(text);
    if (!command) return;
    await telegram.sendMessage(await this.answer(command));
  }

  private async answer(command: telegram.Command): Promise<string> {
    const { store, runner, viewOf, dashboardUrl } = this.deps;
    switch (command.name) {
      case 'help':
      case 'start':
      case 'h': {
        // `/start` ist der Befehl, den Telegram selbst erwartet: er darf nicht
        // die Run-Steuerung bedeuten, sonst startet ein versehentliches /start
        // einen Agenten.
        return telegram.HELP_TEXT;
      }
      case 'list': {
        const open = store
          .listSuggestions()
          .filter((s) => s.status === 'new' || s.status === 'approved')
          .slice(0, 15);
        if (!open.length) return '📭 Keine offenen Vorschläge.';
        const lines = open.map((s) => {
          const mark = s.status === 'approved' ? '👍' : '🆕';
          return `${mark} <b>#${s.id}</b> ${telegram.escapeHtml(s.text.slice(0, 70))}`;
        });
        return [`<b>Offene Vorschläge</b>`, '', ...lines, '', `<code>/run 12</code> startet einen Lauf.`].join('\n');
      }
      case 'status': {
        const id = telegram.suggestionIdArg(command.args);
        if (!id) return 'Welcher Vorschlag? <code>/status 12</code>';
        const view = viewOf(id);
        if (!view) return `❌ Vorschlag #${id} gibt es nicht.`;
        const runs = (runner?.listSuggestionRuns(id) ?? store.listRuns(200).filter((r) => r.suggestionId === id)).slice(0, 3);
        const lines = [
          `<b>#${view.id}</b> — ${telegram.escapeHtml(view.status)}`,
          '',
          telegram.escapeHtml(view.text.slice(0, 900)),
          '',
          `👤 ${telegram.escapeHtml(view.author)} · ⭐ ${view.score} · 👍 ${view.votes}`,
        ];
        for (const run of runs) {
          lines.push(`→ ${telegram.escapeHtml(run.status)}${run.commitHash ? ` <code>${telegram.escapeHtml(run.commitHash)}</code>` : ''}`);
        }
        lines.push(`${dashboardUrl}#suggestion-${view.id}`);
        return lines.join('\n');
      }
      case 'run': {
        const id = telegram.suggestionIdArg(command.args);
        if (!id) return 'Welcher Vorschlag? <code>/run 12</code>';
        if (!runner) return '⚠️ Der Runner ist abgeschaltet.';
        if (runner.isPaused()) return '⏸️ Die Warteschlange ist pausiert. Läuft nach dem Fortsetzen.';
        const result = this.deps.startRun(id);
        if (!result.ok) return `❌ ${telegram.escapeHtml(result.error ?? 'unbekannter Fehler')}`;
        return `🚀 <b>Run für #${id} gestartet</b>\n<code>${telegram.escapeHtml(result.runId ?? '')}</code>`;
      }
      case 'approve':
      case 'reject': {
        const id = telegram.suggestionIdArg(command.args);
        if (!id) return `Welcher Vorschlag? <code>/${command.name} 12</code>`;
        const status: SuggestionStatus = command.name === 'approve' ? 'approved' : 'rejected';
        const result = this.deps.setStatus(id, status);
        if (!result.ok) return `❌ ${telegram.escapeHtml(result.error ?? 'unbekannter Fehler')}`;
        return `${status === 'approved' ? '👍' : '❌'} #${id} ist jetzt <b>${status}</b>.`;
      }
      case 'queue': {
        if (!runner) return '⚠️ Der Runner ist abgeschaltet.';
        const state = runner.queueState();
        const lines = [`<b>Warteschlange</b>`, `Spuren: ${state.activeRuns.length}/${runner.capacity()}`];
        if (runner.isPaused()) lines.push('⏸️ pausiert');
        for (const run of state.queue.slice(0, 10)) {
          lines.push(`→ #${run.suggestionId} ${telegram.escapeHtml(run.status)}`);
        }
        if (!state.queue.length) lines.push('(leer)');
        return lines.join('\n');
      }
      default:
        return `Unbekannt: <code>/${telegram.escapeHtml(command.name)}</code>\n\n${telegram.HELP_TEXT}`;
    }
  }
}

export type { RunRecord };
