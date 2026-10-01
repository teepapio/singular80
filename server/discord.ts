import type { RunRecord, Suggestion, SuggestionCategory, SuggestionView } from '../src/shared/types';

export const CATEGORY_LABELS: Record<SuggestionCategory, string> = {
  mechanics: 'Mechanik',
  content: 'Content',
  balance: 'Balance',
  bug: 'Bug',
  ui: 'UI',
  audio: 'Audio',
  other: 'Sonstiges',
};

const CATEGORY_COLORS: Record<SuggestionCategory, number> = {
  mechanics: 0x8b5cf6,
  content: 0x22c55e,
  balance: 0xf59e0b,
  bug: 0xef4444,
  ui: 0x3b82f6,
  audio: 0xec4899,
  other: 0x64748b,
};

/**
 * The hosts a Discord webhook may live on. Everything else is refused.
 *
 * The webhook is operator input that reaches this process as a plain string —
 * from the settings, from the dashboard's test button, from `POST /api/suggestions`
 * — and a `startsWith('http')` check accepts `http://192.168.1.1/…` as readily as
 * a real webhook. Whoever can reach the API could then make the server post
 * anywhere on the network, and read the first bytes of the answer back out of the
 * error message. The list is Discord's own domains; a webhook URL has no reason
 * to be anywhere else.
 */
const ALLOWED_WEBHOOK_HOSTS = new Set([
  'discord.com',
  'discordapp.com',
  'ptb.discord.com',
  'canary.discord.com',
]);

/** Every outbound call gets a deadline; without one a hung socket keeps the
 * request that awaits it — a player's suggestion — waiting for ever. */
const OUTBOUND_TIMEOUT_MS = 8000;

export type WebhookCheck = { ok: true; url: URL } | { ok: false; error: string };

/**
 * The one gate for every Discord URL. Nothing else in this file parses a webhook
 * string, so a new call site cannot forget the host check.
 */
export function checkWebhook(raw: string): WebhookCheck {
  const value = (raw ?? '').trim();
  if (!value) return { ok: false, error: 'Kein Discord-Webhook konfiguriert' };
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return { ok: false, error: 'Webhook-Adresse ist keine gültige URL' };
  }
  if (url.protocol !== 'https:') {
    return { ok: false, error: 'Webhook-Adresse muss https sein' };
  }
  const host = url.hostname.toLowerCase();
  if (!ALLOWED_WEBHOOK_HOSTS.has(host)) {
    return {
      ok: false,
      error: `Webhook-Host „${host}" ist nicht erlaubt — erlaubt sind ${[...ALLOWED_WEBHOOK_HOSTS].join(', ')}.`,
    };
  }
  return { ok: true, url };
}

/** Same gate, returned as a string ready for `fetch` — `wait=true` asks Discord
 * for the created message, which is how the id for a later edit is learned. */
function webhookUrl(webhook: string, wait = true): { ok: true; url: string } | { ok: false; error: string } {
  const check = checkWebhook(webhook);
  if (!check.ok) return check;
  const url = new URL(check.url.toString());
  if (wait) url.searchParams.set('wait', 'true');
  return { ok: true, url: url.toString() };
}

/** The webhook without `?wait`, which is the base of a message edit. */
function baseWebhook(webhook: string): { ok: true; url: string } | { ok: false; error: string } {
  const check = checkWebhook(webhook);
  if (!check.ok) return check;
  const url = new URL(check.url.toString());
  url.searchParams.delete('wait');
  return { ok: true, url: url.toString().replace(/\/$/, '') };
}

/** `fetch` failure as a German line the dashboard can show. */
function fetchError(err: unknown): string {
  const error = err as { name?: string; message?: string };
  if (error?.name === 'TimeoutError') {
    return `Discord antwortet nicht (Zeitüberschreitung nach ${OUTBOUND_TIMEOUT_MS / 1000}s)`;
  }
  if (error?.name === 'AbortError') return 'Verbindung zu Discord abgebrochen';
  return error?.message ?? 'unbekannter Fehler';
}

export async function postWebhook(
  webhook: string,
  payload: unknown,
): Promise<{ ok: boolean; messageId?: string; error?: string }> {
  // Validated before the `try` on purpose: the check never throws, so there is
  // no path that leaves this function by rejecting — the caller fires it with
  // `void` and an unhandled rejection would take the process down with it.
  const target = webhookUrl(webhook);
  if (!target.ok) return { ok: false, error: target.error };
  try {
    const res = await fetch(target.url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(OUTBOUND_TIMEOUT_MS),
    });
    if (!res.ok) {
      const text = await res.text().catch(() => '');
      // Only ever Discord's own answer: the host is restricted above.
      return { ok: false, error: `Discord ${res.status}: ${text.slice(0, 200)}` };
    }
    const data = (await res.json().catch(() => null)) as { id?: string } | null;
    return { ok: true, messageId: data?.id };
  } catch (err) {
    return { ok: false, error: fetchError(err) };
  }
}

export function buildSuggestionEmbed(
  suggestion: SuggestionView,
  dashboardUrl: string,
): Record<string, unknown> {
  const statusLabel: Record<string, string> = {
    new: '🆕 Neu',
    approved: '👍 Genehmigt',
    rejected: '❌ Abgelehnt',
    implementing: '🔧 In Umsetzung',
    implemented: '✅ Umgesetzt',
    failed: '⚠️ Fehlgeschlagen',
  };
  const fields: Record<string, unknown>[] = [
    { name: 'Kategorie', value: CATEGORY_LABELS[suggestion.category], inline: true },
    { name: 'Stimmen', value: `${suggestion.votes}`, inline: true },
  ];
  if (suggestion.clusterSize > 1) {
    fields.push({
      name: 'Ähnliche Vorschläge',
      value: `${suggestion.clusterSize} (Cluster #${suggestion.canonicalId ?? suggestion.id})`,
      inline: true,
    });
  }
  if (suggestion.run?.commitHash) {
    fields.push({ name: 'Commit', value: `\`${suggestion.run.commitHash}\``, inline: true });
  }
  return {
    title: `Vorschlag #${suggestion.id} — ${statusLabel[suggestion.status] ?? suggestion.status}`,
    description: suggestion.text.length > 3800 ? `${suggestion.text.slice(0, 3800)}…` : suggestion.text,
    color: CATEGORY_COLORS[suggestion.category],
    fields,
    footer: { text: `von ${suggestion.author} · ${new Date(suggestion.createdAt).toLocaleString('de-DE')}` },
    url: `${dashboardUrl}#suggestion-${suggestion.id}`,
    timestamp: new Date(suggestion.createdAt).toISOString(),
  };
}

export async function notifyNewSuggestion(
  suggestion: SuggestionView,
  webhook: string,
  dashboardUrl: string,
): Promise<{ ok: boolean; messageId?: string; error?: string }> {
  return postWebhook(webhook, {
    username: 'Singular 80',
    content: `🎮 **Neuer Vorschlag #${suggestion.id}**`,
    embeds: [buildSuggestionEmbed(suggestion, dashboardUrl)],
  });
}

export async function updateSuggestionMessage(
  suggestion: SuggestionView,
  webhook: string,
  dashboardUrl: string,
): Promise<{ ok: boolean; error?: string }> {
  if (!suggestion.discordMessageId) return { ok: false, error: 'Keine Discord-Nachricht verknüpft' };
  // Inside the function and before the fetch — `baseWebhook` used to be called
  // one line above the `try`, where an unparsable webhook rejected the promise.
  // The caller fires this with `void`, and a rejected promise is a crash of the
  // whole server under Node's default `--unhandled-rejections=throw`.
  const base = baseWebhook(webhook);
  if (!base.ok) return { ok: false, error: base.error };
  const url = `${base.url}/messages/${suggestion.discordMessageId}`;
  try {
    const res = await fetch(url, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ embeds: [buildSuggestionEmbed(suggestion, dashboardUrl)] }),
      signal: AbortSignal.timeout(OUTBOUND_TIMEOUT_MS),
    });
    if (!res.ok) {
      const text = await res.text().catch(() => '');
      return { ok: false, error: `Discord ${res.status}: ${text.slice(0, 200)}` };
    }
    return { ok: true };
  } catch (err) {
    return { ok: false, error: fetchError(err) };
  }
}

export async function notifyRunResult(
  suggestion: Suggestion,
  run: RunRecord,
  webhook: string,
  dashboardUrl: string,
): Promise<void> {
  const ok = run.status === 'succeeded';
  await postWebhook(webhook, {
    username: 'Singular 80',
    content: ok
      ? `✅ **Vorschlag #${suggestion.id} wurde umgesetzt**${run.commitHash ? ` (\`${run.commitHash}\`)` : ''}`
      : `⚠️ **Umsetzung von Vorschlag #${suggestion.id} fehlgeschlagen** (${run.status})`,
    embeds: [
      {
        description: suggestion.text.slice(0, 2000),
        color: ok ? 0x22c55e : 0xef4444,
        fields: [
          { name: 'Run', value: `\`${run.id}\``, inline: true },
          { name: 'Kosten', value: run.cost != null ? `$${run.cost.toFixed(4)}` : '—', inline: true },
        ],
        url: `${dashboardUrl}#suggestion-${suggestion.id}`,
      },
    ],
  });
}

export async function sendTest(webhook: string, dashboardUrl: string) {
  return postWebhook(webhook, {
    username: 'Singular 80',
    content: '🔔 Testnachricht — die Discord-Anbindung funktioniert.',
    embeds: [
      {
        title: 'Dashboard',
        url: dashboardUrl,
        color: 0x8b5cf6,
        description: 'Vorschläge werden ab jetzt hierher weitergeleitet.',
      },
    ],
  });
}
