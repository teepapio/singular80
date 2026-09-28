import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * The queue, the active run and the history used to identify a task by its run
 * id, its cost and its scope — none of which the owner recognises. The task's
 * own text was missing from all three, which is the one thing that says what is
 * about to happen.
 *
 * These are source-level assertions on purpose: the dashboard has no DOM in the
 * test suite, and the failure this guards (someone re-adding the run id while
 * fixing something else) shows up as a string in the template. What they cannot
 * do is survive a reformat silently — hence every marker below is checked before
 * it is sliced, so a renamed function reports itself instead of returning the
 * wrong region.
 */

const MAIN = readFileSync(join(import.meta.dirname, '..', 'src/dashboard/main.ts'), 'utf8');

/** The three blocks that list a run for a person to look at. */
const BLOCKS = [
  {
    name: 'Warteschlangen-Eintrag',
    start: 'html += queued',
    // The button that closes the entry. Deliberately not its full markup: the id
    // inside it is wrapped in a helper now, and a marker that spells the whole
    // attribute breaks on a rename that changes nothing an operator sees.
    end: 'data-action="cancel-run"',
  },
  { name: 'aktiver Run', start: 'function renderRunCard', end: 'data-run-activity' },
  { name: 'Historie', start: 'function renderRunHistory', end: 'data-action="retry-run"' },
];

function block({ start, end }: (typeof BLOCKS)[number]): string {
  const from = MAIN.indexOf(start);
  const to = MAIN.indexOf(end, from);
  expect(from, `Startmarker ${start} gefunden`).toBeGreaterThan(-1);
  expect(to, `Endmarker ${end} gefunden`).toBeGreaterThan(from);
  return MAIN.slice(from, to);
}

describe('Ein Run ist an seinem Text erkennbar', () => {
  it.each(BLOCKS)('$name zeigt den Vorschlagstext', (b) => {
    expect(block(b)).toContain('suggestionText(run.suggestionId)');
  });

  it.each(BLOCKS)('$name nennt die kryptische Run-Id nicht', (b) => {
    // The id is a `run_`-blob; the owner asked for it to go. It may still appear
    // in a `data-` attribute, which the eye never sees — and it may be wrapped in
    // a helper there, so the attribute is recognised by what it contains.
    const shown = block(b).replace(/data-[a-z-]+="[^"]*run\.id[^"]*"/g, '');
    expect(shown).not.toMatch(/\$\{run\.id\}/);
  });

  it.each(BLOCKS)('$name nennt die Kosten nicht', (b) => {
    expect(block(b)).not.toContain('run.cost');
  });

  it.each(BLOCKS)('$name nennt den Scope nicht', (b) => {
    expect(block(b)).not.toContain('scopeLabel');
  });

  it('die Historie meldet keine Dateien außerhalb des Scopes', (b) => {
    expect(block(BLOCKS[2])).not.toContain('run-warning');
  });
});

/** The helper itself, so the assertions read as one block. */
function suggestionTextSource(): string {
  const from = MAIN.indexOf('function suggestionText');
  // Guarded like `block()` above: `slice(from, -1)` would return the rest of the
  // file and every assertion below would quietly pass on unrelated code.
  expect(from, 'Startmarker "function suggestionText" gefunden').toBeGreaterThan(-1);
  const to = MAIN.indexOf('\n}', from);
  expect(to, 'Endmarker "}" gefunden').toBeGreaterThan(from);
  return MAIN.slice(from, to + 2);
}

describe('Der Vorschlagstext', () => {
  it('ist eine Zeile und wird gekürzt', () => {
    const fn = suggestionTextSource();
    expect(fn).toContain('140');
    expect(fn).toContain('…');
    // Collapsed to a single line so it cannot break the row layout.
    expect(fn).toMatch(/replace\(/);
  });

  it('sagt etwas, auch wenn der Vorschlag nicht geladen ist', () => {
    // A blank row is indistinguishable from a broken one.
    const fn = suggestionTextSource();
    expect(fn).toContain('(Vorschlag nicht geladen)');
  });

  it('wird als title mit dem vollen Text gesetzt', () => {
    for (const b of BLOCKS) {
      expect(block(b)).toContain('title="${escapeHtml(');
    }
  });
});
