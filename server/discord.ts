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

function webhookUrl(webhook: string, wait = true): string {
  const url = new URL(webhook);
  if (wait) url.searchParams.set('wait', 'true');
  return url.toString();
}

function baseWebhook(webhook: string): string {
  const url = new URL(webhook);
  url.searchParams.delete('wait');
  return url.toString().replace(/\/$/, '');
}

export async function postWebhook(
  webhook: string,
  payload: unknown,
): Promise<{ ok: boolean; messageId?: string; error?: string }> {
  if (!webhook || !webhook.startsWith('http')) return { ok: false, error: 'Kein Discord-Webhook konfiguriert' };
  try {
    const res = await fetch(webhookUrl(webhook), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      const text = await res.text().catch(() => '');
      return { ok: false, error: `Discord ${res.status}: ${text.slice(0, 200)}` };
    }
    const data = (await res.json().catch(() => null)) as { id?: string } | null;
    return { ok: true, messageId: data?.id };
  } catch (err) {
    return { ok: false, error: (err as Error).message };
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
    { name: 'Score', value: `${suggestion.score}`, inline: true },
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
  const url = `${baseWebhook(webhook)}/messages/${suggestion.discordMessageId}`;
  try {
    const res = await fetch(url, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ embeds: [buildSuggestionEmbed(suggestion, dashboardUrl)] }),
    });
    if (!res.ok) {
      const text = await res.text().catch(() => '');
      return { ok: false, error: `Discord ${res.status}: ${text.slice(0, 200)}` };
    }
    return { ok: true };
  } catch (err) {
    return { ok: false, error: (err as Error).message };
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
