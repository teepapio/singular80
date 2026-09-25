import { describe, expect, it } from 'vitest';
import { mapOpencodeEvent } from '../server/runner';

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
