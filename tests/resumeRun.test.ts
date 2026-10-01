import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * What the owner asked for after runs hit the time limit: a way to *continue*
 * them from the dashboard, and more attempts in general.
 *
 * Source-level assertions, like `queueTaskText.test.ts` and `runConsole.test.ts`:
 * the dashboard has no DOM in the suite, and every way this breaks is a missing
 * string in a template or a missing id. The one thing that is checked for real is
 * the rule that decides whether the button appears at all — a run without a
 * session has nothing to continue, and offering it anyway is a dead button.
 */
const MAIN = readFileSync(join(import.meta.dirname, '..', 'src/dashboard/main.ts'), 'utf8');
const HTML = readFileSync(join(import.meta.dirname, '..', 'index.html'), 'utf8');

describe('Fortsetzen im Panel', () => {
  const history = MAIN.slice(MAIN.indexOf('function renderRunHistory'), MAIN.indexOf('function renderScopes'));

  it('die Historie bietet Fortsetzen neben Wiederholen', () => {
    expect(history).toContain('data-action="resume-run"');
    expect(history).toContain('▶ Fortsetzen');
    // Beide, und in dieser Reihenfolge: wiederholen ist der billigere Klick,
    // fortsetzen der, der die Sitzung behält.
    expect(history.indexOf('retry-run')).toBeLessThan(history.indexOf('resume-run'));
  });

  it('nur wenn es eine Sitzung zum Fortsetzen gibt', () => {
    // Ohne `sessionId` gibt es nichts, was opencode fortsetzen könnte. Die Route
    // antwortet dann mit 409, und ein Knopf, der immer fehlschlägt, ist schlechter
    // als keiner.
    expect(history).toContain('run.sessionId');
  });

  it('der Klick geht an die neue Route und sagt, was passiert', () => {
    expect(MAIN).toContain("api<{ run: RunRecord }>(`/api/runs/${runId}/resume`");
    expect(MAIN).toContain('Setzt den Run für #${result.run.suggestionId} in seiner Sitzung fort');
    // Die Historie erkennt eine Fortsetzung am Label, sonst sieht sie aus wie ein
    // Wiederholung und niemand weiß, was gelaufen ist.
    expect(history).toContain('▶ fortgesetzt');
  });

  it('die Zeitüberschreitung ist ein Grund zum Fortsetzen, kein finished-Vermerk', () => {
    // `attemptLabel` bleibt unberührt; entscheidend ist, dass ein gescheiterter
    // Lauf die Fortsetzung angeboten bekommt — der häufigste Fall ist die
    // Zeitgrenze.
    expect(history).toContain("run.status === 'failed' || run.status === 'cancelled'");
  });
});

describe('Die Warteschlange sagt, worauf sie wartet', () => {
  const queue = MAIN.slice(MAIN.indexOf('function renderRuns'), MAIN.indexOf('function renderQueueState'));

  it('unterscheidet Wartezeit von freier Spur', () => {
    // Beide Wartezustände sahen vorher gleich aus ("wartet"), und der Besitzer
    // hat einen Auftrag gesehen, der nicht startet. Die Karte muss sagen, ob er auf
    // eine Spur wartet oder auf die Wartezeit eines Wiederholungsversuchs.
    expect(queue).toContain("'wartet auf die Wartezeit'");
    expect(queue).toContain("'wartet auf eine freie Spur'");
    expect(queue).toContain('run.notBefore != null && run.notBefore > Date.now()');
  });
});

describe('Mehr Wiederholungen', () => {
  it('das Formular lässt bis 20 Versuche zu', () => {
    expect(HTML).toContain('id="setting-retries" type="number" min="0" max="20"');
  });
});