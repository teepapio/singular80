import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  buildSuggestionEmbed,
  CATEGORY_LABELS,
  checkWebhook,
  notifyNewSuggestion,
  notifyRunResult,
  postWebhook,
  sendTest,
  updateSuggestionMessage,
} from '../server/discord';
import type { RunRecord, Suggestion, SuggestionView } from '../src/shared/types';

/**
 * Discord is an optional second channel, and every caller in `app.ts` fires it
 * with `void`. That is the whole reason this file exists: a function that
 * *rejects* is not a lost message, it is an unhandled rejection, and under Node's
 * default `--unhandled-rejections=throw` that takes the server down while a player
 * is submitting a suggestion. So the crash class gets its own cases, and not only
 * the happy path.
 *
 * Nothing here touches the network: `fetch` is replaced, and the assertion is on
 * what the function *returns* and on whether it rejects at all.
 */

const URL_TEXT = 'https://singular80.example/dashboard';
const GOOD = 'https://discord.com/api/webhooks/1/token';

/** A view as the dashboard would send it. */
function view(overrides: Partial<SuggestionView> = {}): SuggestionView {
  return {
    id: 7,
    text: 'Ein Slime, der in zwei kleinere zerfällt',
    author: 'Anonym',
    source: 'game',
    category: 'mechanics',
    status: 'new',
    votes: 3,
    score: 5,
    canonicalId: null,
    clusterSize: 1,
    createdAt: 1_700_000_000_000,
    updatedAt: 1_700_000_000_000,
    clientKey: null,
    parentId: null,
    discordMessageId: null,
    runId: null,
    run: null,
    ...overrides,
  } as unknown as SuggestionView;
}

function run(overrides: Partial<RunRecord> = {}): RunRecord {
  return {
    id: 'run_1',
    suggestionId: 7,
    status: 'succeeded',
    sessionId: null,
    lane: 1,
    prompt: '',
    exitCode: 0,
    cost: 0.1234,
    tokensInput: 1,
    tokensOutput: 2,
    commitHash: 'abc1234',
    resultSummary: '',
    createdAt: 0,
    startedAt: 0,
    finishedAt: 1,
    logPath: '/tmp/x.jsonl',
    attempt: 1,
    maxAttempts: 1,
    retryOf: null,
    notBefore: null,
    timeoutMs: 0,
    scopes: ['tetris'],
    scope: 'tetris',
    note: null,
    scopeIssues: null,
    ...overrides,
  } as RunRecord;
}

const suggestion = { id: 7, text: 'Ein Slime, der in zwei kleinere zerfällt' } as Suggestion;

/** `fetch` replaced; the returned mock records what went out. */
function stubFetch(response: unknown = { id: 'msg-1' }) {
  const fetchMock = vi.fn().mockResolvedValue({
    ok: true,
    status: 200,
    json: async () => response,
    text: async () => JSON.stringify(response),
  });
  vi.stubGlobal('fetch', fetchMock);
  return fetchMock;
}

/** The body of the n-th outbound call. */
function bodyOf(fetchMock: ReturnType<typeof vi.fn>, index = 0): Record<string, unknown> {
  const init = fetchMock.mock.calls[index][1] as { body: string };
  return JSON.parse(init.body) as Record<string, unknown>;
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe('checkWebhook', () => {
  it('nimmt die vier Discord-Hosts und nichts sonst', () => {
    for (const host of ['discord.com', 'discordapp.com', 'ptb.discord.com', 'canary.discord.com']) {
      const result = checkWebhook(`https://${host}/api/webhooks/1/t`);
      expect(result.ok, host).toBe(true);
      expect(result.ok === true && result.url.toString()).toBe(`https://${host}/api/webhooks/1/t`);
    }
  });

  it('weist etwas ab, das keine URL ist, ohne zu werfen', () => {
    // `new URL` throws on most of what an operator can paste into the field.
    for (const bad of ['', '   ', 'nicht-url', 'discord.com/api/webhooks', '://x', 'ht tp://x']) {
      const result = checkWebhook(bad);
      expect(result.ok, `"${bad}" wurde akzeptiert`).toBe(false);
    }
  });

  it('verlangt https', () => {
    // The check exists so that whoever can reach the API cannot make the server
    // post anywhere on the network; plain http is the same hole with a different
    // protocol.
    const result = checkWebhook('http://discord.com/api/webhooks/1/t');
    expect(result.ok).toBe(false);
    expect(result.ok === false && result.error).toContain('https');
  });

  it('nennt den fremden Host, statt ihn stillschweigend zu verwerfen', () => {
    const result = checkWebhook('https://192.168.1.1/webhook');
    expect(result.ok).toBe(false);
    expect(result.ok === false && result.error).toContain('192.168.1.1');
    expect(result.ok === false && result.error).toContain('discord.com');
  });

  it('prüft den Host case-insensitiv', () => {
    expect(checkWebhook('https://DISCORD.COM/api/webhooks/1/t').ok).toBe(true);
  });
});

describe('postWebhook', () => {
  it('fragt mit wait=true, damit die Nachrichten-id für spätere Edits bekannt ist', async () => {
    const fetchMock = stubFetch({ id: 'msg-42' });
    const result = await postWebhook(GOOD, { content: 'hallo' });
    expect(result).toEqual({ ok: true, messageId: 'msg-42' });
    expect(String(fetchMock.mock.calls[0][0])).toContain('wait=true');
    expect(bodyOf(fetchMock)).toEqual({ content: 'hallo' });
  });

  it('schickt nichts in die Welt, wenn die Adresse kaputt ist', async () => {
    // Validation before the fetch, and before the `try`: a rejected URL must cost
    // a log line, not a request to somebody else's server.
    const fetchMock = stubFetch();
    const result = await postWebhook('https://evil.example/hook', { content: 'x' });
    expect(result.ok).toBe(false);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('meldet eine Ablehnung von Discord mit Status und Text', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: false,
        status: 404,
        json: async () => null,
        text: async () => '{"message":"Unknown Webhook"}',
      }),
    );
    const result = await postWebhook(GOOD, {});
    expect(result.ok).toBe(false);
    expect(result.error).toContain('Discord 404');
    expect(result.error).toContain('Unknown Webhook');
  });

  it('schluckt einen Body, den Discord nicht liefert', async () => {
    // `res.text()` throwing must not turn a 500 into an exception; the caller in
    // `app.ts` has no `try` around this.
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: false,
        status: 500,
        text: async () => {
          throw new Error('stream closed');
        },
        json: async () => null,
      }),
    );
    const result = await postWebhook(GOOD, {});
    expect(result.ok).toBe(false);
    expect(result.error).toContain('Discord 500');
  });

  it('meldet ein abgerissenes Socket als Fehler, nicht als Absturz', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new TypeError('fetch failed')));
    const result = await postWebhook(GOOD, {});
    expect(result.ok).toBe(false);
    expect(result.error).toBe('fetch failed');
  });

  it('unterscheidet eine Zeitüberschreitung von einem Abbruch', async () => {
    const timeout = Object.assign(new Error('The operation timed out'), { name: 'TimeoutError' });
    const aborted = Object.assign(new Error('aborted'), { name: 'AbortError' });
    vi.stubGlobal('fetch', vi.fn().mockRejectedValueOnce(timeout).mockRejectedValueOnce(aborted));
    expect((await postWebhook(GOOD, {})).error).toContain('Zeitüberschreitung');
    expect((await postWebhook(GOOD, {})).error).toContain('abgebrochen');
  });

  it('überlebt eine Antwort ohne JSON', async () => {
    // A proxy that answers 200 with HTML must not produce a thrown SyntaxError.
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => {
          throw new SyntaxError('Unexpected token <');
        },
        text: async () => '<html>',
      }),
    );
    const result = await postWebhook(GOOD, {});
    expect(result.ok).toBe(true);
    expect(result.messageId).toBeUndefined();
  });
});

describe('buildSuggestionEmbed', () => {
  it('nennt Nummer, Status, Kategorie und den Sprung zum Vorschlag', () => {
    const embed = buildSuggestionEmbed(view(), URL_TEXT) as Record<string, never>;
    expect(embed.title).toBe('Vorschlag #7 — 🆕 Neu');
    expect(embed.description).toBe('Ein Slime, der in zwei kleinere zerfällt');
    expect(embed.url).toBe(`${URL_TEXT}#suggestion-7`);
    expect(typeof embed.color).toBe('number');
    const names = (embed.fields as unknown as { name: string }[]).map((f) => f.name);
    expect(names).toEqual(['Kategorie', 'Score', 'Stimmen']);
    expect((embed.fields as unknown as { value: string }[])[0].value).toBe(CATEGORY_LABELS.mechanics);
  });

  it('schneidet einen Text ab, den Discord nicht annimmt', () => {
    // Discord's limit is 4096 for the whole message and 4096 for a description;
    // the 3800 leaves room for the footer.
    const embed = buildSuggestionEmbed(view({ text: 'x'.repeat(5000) }), URL_TEXT) as Record<string, never>;
    expect(String(embed.description)).toHaveLength(3801);
    expect(String(embed.description).endsWith('…')).toBe(true);
  });

  it('nennt Cluster und Commit nur, wenn es sie gibt', () => {
    const plain = buildSuggestionEmbed(view(), URL_TEXT) as Record<string, never>;
    const names = (plain.fields as unknown as { name: string }[]).map((f) => f.name);
    expect(names).not.toContain('Ähnliche Vorschläge');
    expect(names).not.toContain('Commit');

    const rich = buildSuggestionEmbed(
      view({ clusterSize: 4, canonicalId: 3, run: run() }),
      URL_TEXT,
    ) as Record<string, never>;
    const fields = rich.fields as unknown as { name: string; value: string }[];
    expect(fields.find((f) => f.name === 'Ähnliche Vorschläge')?.value).toBe('4 (Cluster #3)');
    expect(fields.find((f) => f.name === 'Commit')?.value).toBe('`abc1234`');
  });

  it('fällt auf den rohen Status zurück, statt undefined zu schreiben', () => {
    // A status the label table does not know must still produce a title; Discord
    // rejects a message without one.
    const embed = buildSuggestionEmbed(view({ status: 'neu' as never }), URL_TEXT) as Record<string, never>;
    expect(embed.title).toBe('Vorschlag #7 — neu');
  });
});

describe('notifyNewSuggestion', () => {
  it('schickt den Vorschlag und reicht die Nachrichten-id durch', async () => {
    const fetchMock = stubFetch({ id: 'msg-9' });
    const result = await notifyNewSuggestion(view(), GOOD, URL_TEXT);
    expect(result).toEqual({ ok: true, messageId: 'msg-9' });
    const body = bodyOf(fetchMock);
    expect(body.username).toBe('Singular 80');
    expect(String(body.content)).toContain('#7');
    expect((body.embeds as unknown[])).toHaveLength(1);
  });
});

describe('updateSuggestionMessage', () => {
  it('schreibt in genau die Nachricht, die zu diesem Vorschlag gehört', async () => {
    const fetchMock = stubFetch({});
    const result = await updateSuggestionMessage(view({ discordMessageId: '4711' }), GOOD, URL_TEXT);
    expect(result.ok).toBe(true);
    const url = String(fetchMock.mock.calls[0][0]);
    expect(url).toContain('/messages/4711');
    // `wait` belongs to creating a message; on an edit it is meaningless.
    expect(url).not.toContain('wait=true');
    expect((fetchMock.mock.calls[0][1] as { method: string }).method).toBe('PATCH');
  });

  it('sagt es, wenn keine Nachricht verknüpft ist', async () => {
    const fetchMock = stubFetch();
    const result = await updateSuggestionMessage(view(), GOOD, URL_TEXT);
    expect(result.ok).toBe(false);
    expect(result.error).toContain('Keine Discord-Nachricht');
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('wirft bei einer kaputten Adresse nicht aus dem heraus — der Absturz, den es gab', async () => {
    // `app.ts` calls this with `void`. A rejected promise here is an unhandled
    // rejection, and the server dies with it — the webhook check used to sit one
    // line above the `try`.
    const fetchMock = stubFetch();
    for (const bad of ['', 'nicht-url', 'https://evil.example/hook', 'http://discord.com/x']) {
      const result = await updateSuggestionMessage(view({ discordMessageId: '1' }), bad, URL_TEXT);
      expect(result.ok, `"${bad}"`).toBe(false);
    }
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('meldet eine abgelehnte Änderung, statt sie zu verschweigen', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({ ok: false, status: 404, json: async () => null, text: async () => 'Unknown Message' }),
    );
    const result = await updateSuggestionMessage(view({ discordMessageId: '1' }), GOOD, URL_TEXT);
    expect(result.ok).toBe(false);
    expect(result.error).toContain('Discord 404');
  });
});

describe('notifyRunResult', () => {
  it('meldet Erfolg mit Commit und Kosten', async () => {
    const fetchMock = stubFetch({ id: 'msg-2' });
    await notifyRunResult(suggestion, run(), GOOD, URL_TEXT);
    const body = bodyOf(fetchMock);
    expect(String(body.content)).toContain('wurde umgesetzt');
    expect(String(body.content)).toContain('abc1234');
    const fields = (body.embeds as { fields: { name: string; value: string }[] }[])[0].fields;
    expect(fields.find((f) => f.name === 'Kosten')?.value).toBe('$0.1234');
  });

  it('meldet einen Fehlschlag mit seinem Status und ohne Commit', async () => {
    const fetchMock = stubFetch();
    await notifyRunResult(suggestion, run({ status: 'failed', commitHash: null, cost: null }), GOOD, URL_TEXT);
    const body = bodyOf(fetchMock);
    expect(String(body.content)).toContain('fehlgeschlagen');
    expect(String(body.content)).toContain('failed');
    expect(String(body.content)).not.toContain('abc1234');
    const fields = (body.embeds as { fields: { name: string; value: string }[] }[])[0].fields;
    // No cost recorded is "—", not `$NaN`.
    expect(fields.find((f) => f.name === 'Kosten')?.value).toBe('—');
  });

  it('schluckt eine kaputte Adresse, ohne zu werfen', async () => {
    // `app.ts` fires this from the run's completion callback, also with `void`.
    const fetchMock = stubFetch();
    await expect(notifyRunResult(suggestion, run(), 'nicht-url', URL_TEXT)).resolves.toBeUndefined();
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe('sendTest', () => {
  it('schickt genau die Testnachricht des Knopfes', async () => {
    const fetchMock = stubFetch({ id: 'msg-3' });
    const result = await sendTest(GOOD, URL_TEXT);
    expect(result.ok).toBe(true);
    const body = bodyOf(fetchMock);
    expect(String(body.content)).toContain('Testnachricht');
    expect((body.embeds as { url: string }[])[0].url).toBe(URL_TEXT);
  });

  it('meldet einen refused host, statt zu schweigen', async () => {
    stubFetch();
    const result = await sendTest('https://example.invalid/hook', URL_TEXT);
    expect(result.ok).toBe(false);
    expect(result.error).toContain('example.invalid');
  });
});
