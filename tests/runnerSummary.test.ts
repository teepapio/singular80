import { describe, expect, it } from 'vitest';
import { shortSummary } from '../server/runner';

/**
 * The changelog line for a finished run is built from this. The input is an
 * agent narrating what it did, in the order it did it — and the earlier version
 * took the *last* 600 characters of it. That produced entries like
 *
 *   …berührt. Jetzt die Prüfungen: Typecheck ist sauber. Jetzt die Test-Suite:
 *   5 Tests sind fehlgeschlagen…
 *
 * which opens mid-word and reports the agent's feelings about its own test run
 * instead of what changed. These tests pin the shape of the line.
 */

const S = (raw: string) => shortSummary(raw, 'FALLBACK');

describe('Kurzfassung der Agenten-Antwort', () => {
  it('nimmt den ersten Satz, nicht das Ende', () => {
    const narration =
      'Ich habe die Speed-Werte in enemies.json geändert. Jetzt die Prüfungen: Typecheck ist sauber. ' +
      'Jetzt die Test-Suite: 5 Tests sind fehlgeschlagen, ich sehe sie mir an.';
    expect(S(narration)).toBe('Ich habe die Speed-Werte in enemies.json geändert.');
  });

  it('beginnt nie mitten im Satz', () => {
    const out = S('x'.repeat(200) + ' Und jetzt noch etwas ganz anderes.');
    expect(out.startsWith('x')).toBe(true);
    expect(out).not.toMatch(/^…/);
  });

  it('schneidet an einer Wortgrenze und hängt ein Zeichen für den Schnitt', () => {
    // Longer than MAX_SUMMARY, and without any sentence end — the shape an agent
    // produces when it never got to a conclusion.
    const long = `Der Slime ist jetzt langsamer ${'und sehr viel laenger '.repeat(40)}`;
    expect(long.length).toBeGreaterThan(600);
    const out = S(long);
    expect(out.endsWith('…')).toBe(true);
    // Cut on a word boundary: the character before the ellipsis is the last
    // letter of a whole word, and the character before that is a space that is
    // not part of the result.
    expect(out.length).toBeLessThanOrEqual(601);
    expect(out.slice(0, -1)).toBe(long.slice(0, out.length - 1).trimEnd());
  });

  it('verliert eine Nummerierung nicht an eine Abkürzung', () => {
    // "1." is a sentence end by punctuation alone. Taking it would put the whole
    // summary in a list marker.
    expect(S('1. Slime langsamer. 2. Mini-Slime ebenfalls.')).toBe('Slime langsamer.');
  });

  it('behält den ersten Satz einer Aufzählung als Zusammenfassung', () => {
    expect(S('Der Slime wurde auf 32 gesetzt. Mini-Slime bleibt bei 82.')).toBe('Der Slime wurde auf 32 gesetzt.');
  });

  it('nimmt eine Überschrift, wenn der Agent keinen Satz schrieb', () => {
    expect(S('docs(changelog): Slime auf 32 gesetzt')).toBe('docs(changelog): Slime auf 32 gesetzt');
  });

  it('fällt auf den Ersatz zurück, wenn der Agent nichts schrieb', () => {
    expect(S('   ')).toBe('FALLBACK');
  });

  it('macht aus einem Absatz genau eine Zeile', () => {
    const out = S('Zeile eins\n\nZeile zwei\n\nZeile drei');
    expect(out).not.toMatch(/[\n\r]/);
  });
});
