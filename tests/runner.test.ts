import { describe, expect, it } from 'vitest';
import { buildPrompt, formatBudget, mapOpencodeEvent } from '../server/runner';
import { DEFAULT_SETTINGS } from '../server/db';
import type { Suggestion } from '../src/shared/types';

describe('formatBudget', () => {
  it('schreibt Minuten und Sekunden lesbar', () => {
    expect(formatBudget(2_700_000)).toBe('45 min');
    expect(formatBudget(30_000)).toBe('30 s');
    expect(formatBudget(1.5 * 60_000)).toBe('1.5 min');
  });

  it('sagt es, wenn es kein Zeitlimit gibt', () => {
    expect(formatBudget(0)).toBe('unbegrenzt');
  });
});

describe('buildPrompt', () => {
  const suggestion: Suggestion = {
    id: 42,
    text: 'Mehr Bälle',
    author: 'Spielerin',
    source: 'game',
    category: 'mechanics',
    status: 'approved',
    votes: 3,
    canonicalId: null,
    createdAt: 0,
    updatedAt: 0,
    discordMessageId: null,
    runId: null,
  };

  it('nennt den Scope, damit der Agent seinen Besitz kennt', () => {
    const prompt = buildPrompt(suggestion, [suggestion], DEFAULT_SETTINGS, '/repo', ['tetris']);
    expect(prompt).toContain('SCOPE: tetris');
    expect(prompt).toContain('scripts/scopes.mjs');
    expect(prompt).toContain('Vorschlag #42');
  });

  it('verbietet `git add -A` und nennt den eigenen Index', () => {
    const prompt = buildPrompt(suggestion, [suggestion], DEFAULT_SETTINGS, '/repo', ['tetris']);
    expect(prompt).toContain('"git add -A" ist verboten');
    expect(prompt).toContain('GIT_INDEX_FILE');
    expect(prompt).toContain('feat(suggestion-42)');
  });

  it('weist auf den zweiten Versuch hin', () => {
    expect(buildPrompt(suggestion, [suggestion], DEFAULT_SETTINGS, '/repo', ['tetris'], 2)).toContain(
      'WIEDERHOLUNGSVERSUCH 2',
    );
    expect(buildPrompt(suggestion, [suggestion], DEFAULT_SETTINGS, '/repo', ['tetris'], 1)).not.toContain(
      'WIEDERHOLUNGSVERSUCH',
    );
  });

  it('nennt Geschwister desselben Clusters', () => {
    const sibling = { ...suggestion, id: 43, text: 'Noch mehr Bälle' };
    expect(buildPrompt(suggestion, [suggestion, sibling], DEFAULT_SETTINGS, '/repo')).toContain('#43: Noch mehr Bälle');
  });
});

describe('mapOpencodeEvent', () => {
  it('übersetzt Text-Events', () => {
    const events = mapOpencodeEvent({
      type: 'text',
      timestamp: 123,
      part: { type: 'text', text: 'Ich habe den Gegner hinzugefügt.' },
    });
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ kind: 'text', text: 'Ich habe den Gegner hinzugefügt.' });
  });

  it('übersetzt Tool-Events mit Status und Output', () => {
    const events = mapOpencodeEvent({
      type: 'tool',
      part: {
        tool: 'edit',
        state: { status: 'completed', title: 'content/enemies.json', output: 'ok' },
      },
    });
    expect(events[0]).toMatchObject({ kind: 'tool', tool: 'edit' });
    expect(events[0].text).toContain('content/enemies.json');
    expect(events.some((e) => e.kind === 'info' && e.text === 'ok')).toBe(true);
  });

  it('übersetzt tool_use-Events (opencode 1.18)', () => {
    const events = mapOpencodeEvent({
      type: 'tool_use',
      part: {
        tool: 'bash',
        state: { status: 'completed', input: { command: 'npm run typecheck' }, output: 'ok' },
      },
    });
    expect(events[0]).toMatchObject({ kind: 'tool', tool: 'bash' });
    expect(events[0].text).toContain('npm run typecheck');
  });

  it('übersetzt Fehler-Events', () => {
    const events = mapOpencodeEvent({
      type: 'error',
      part: { error: { data: { message: 'Rate limit' } } },
    });
    expect(events[0]).toMatchObject({ kind: 'error', text: 'Rate limit' });
  });

  it('ignoriert unbekannte Events', () => {
    expect(mapOpencodeEvent({ type: 'step_start', part: {} })).toEqual([]);
  });
});
