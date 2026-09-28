import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * The "done" tab is a place to look back. A card there that offers to implement
 * a finished task contradicts itself, and the owner asked for the
 * implementation details to go entirely.
 *
 * Source-level assertions, and that has a price worth naming: the dashboard has
 * no DOM in the test suite (no `jsdom` dependency, and `package.json` is not
 * ours), so these read `main.ts` as text. They fail on a reformat that changes no
 * behaviour, and they cannot see a guard that was inverted — only a guard whose
 * *string* disappeared. What the helpers below buy is that a renamed or deleted
 * function reports "marker missing" instead of quietly slicing the wrong region
 * and passing on whatever is there. The pure part of the panel is tested for real
 * in `queueControls.test.ts`, which is why that module exists.
 */

const MAIN = readFileSync(join(import.meta.dirname, '..', 'src/dashboard/main.ts'), 'utf8');

/**
 * The source between two markers, with both ends checked.
 *
 * `slice(start, end)` with a missing marker is the quiet failure this guards
 * against: `indexOf` returns -1, and `slice(-1, x)` returns a region that has
 * nothing to do with the function the test is about — so the assertions below pass
 * or fail for an unrelated reason.
 */
function between(start: string, end: string): string {
  const from = MAIN.indexOf(start);
  expect(from, `Startmarker "${start}" nicht gefunden — die Funktion wurde umbenannt?`).toBeGreaterThan(-1);
  const to = MAIN.indexOf(end, from + start.length);
  expect(to, `Endmarker "${end}" nicht gefunden`).toBeGreaterThan(from);
  return MAIN.slice(from, to);
}

function renderCardSource(): string {
  return between('function renderCard', 'function renderList');
}

describe('Der erledigte Tab', () => {
  it('kennt erledigte Vorschlaege ueber eine eigene Funktion', () => {
    expect(MAIN).toContain('function isSettled');
    expect(MAIN).toMatch(/status === 'implemented'.*failed.*rejected/);
  });

  it('gilt nur im erledigten Tab', () => {
    // A failed run is current information while the task is still being worked
    // on; hiding the details there would hide the reason it failed.
    expect(MAIN).toContain("const settled = state.tab === 'done' && isSettled(s);");
  });

  it('bietet "In OpenCode umsetzen" nicht mehr an', () => {
    const card = renderCardSource();
    // The button stays in the template, behind the guard. Asserted as an order
    // rather than as a pattern: the guard must open the expression and the button
    // must sit inside it.
    const guard = card.indexOf("!settled && s.status !== 'implementing' && !hasChildren");
    const button = card.indexOf('data-action="implement"');
    expect(guard, 'Umsetzen-Wächter nicht gefunden').toBeGreaterThan(-1);
    expect(button, 'Umsetzen-Knopf nicht gefunden').toBeGreaterThan(guard);
    // Between guard and button there is nothing but the rest of the condition —
    // an `|| settled` in between would invert the whole thing silently.
    expect(card.slice(guard, button)).not.toMatch(/\|\|\s*settled|settled\s*\|\|/);
  });

  it('bietet auch "Aufteilen" nicht mehr an', () => {
    // The same shape, spelled out instead of as a character window. The old
    // `[\s\S]{0,80}` matched any layout within 80 characters and nothing beyond,
    // so a reformat broke it and an inverted guard inside that window passed it.
    const card = renderCardSource();
    const guard = card.indexOf("!settled && s.status !== 'implemented'");
    const button = card.indexOf('data-action="split"');
    expect(guard, 'Aufteilen-Wächter nicht gefunden').toBeGreaterThan(-1);
    expect(button, 'Aufteilen-Knopf nicht gefunden').toBeGreaterThan(guard);
    const between = card.slice(guard, button);
    expect(between).toContain('&& !hasChildren');
    expect(between.match(/!settled/g)).toHaveLength(1);
    expect(between).not.toMatch(/\|\|\s*settled|settled\s*\|\|/);
  });

  it('entfernt Umsetzung, Run-Status, Commit und Scope', () => {
    const card = renderCardSource();
    expect(card).toContain("run?.resultSummary && !settled");
    expect(card).toContain("run.status !== 'running' && !settled");
    expect(card).toContain("run?.scope && !settled");
  });

  it('nennt den Knopf "Schließen" statt "Löschen"', () => {
    const card = renderCardSource();
    expect(card).toContain('data-action="dismiss"');
    expect(card).toMatch(/>✕ Schließen<\/button>/);
    // "Löschen" stays, but only for work that is not settled.
    expect(card).toContain('>Löschen</button>');
  });

  it('behaelt Nummer, Status, Autor und Alter', () => {
    const card = renderCardSource();
    expect(card).toContain('<span>#${s.id}</span>');
    // The badge is built from the status; the class is assembled with a helper in
    // between, so this asks for the shape and not for one spelling of it.
    expect(card).toMatch(/class="badge status-\$\{[^}]*s\.status[^}]*\}"/);
    expect(card).toContain('escapeHtml(s.author)');
    expect(card).toContain('timeAgo(s.createdAt)');
  });
});

describe('Schließen loescht nichts', () => {
  it('sendet keine Anfrage an den Server', () => {
    const branch = between("action === 'dismiss'", "action === 'delete'");
    expect(branch).not.toContain('api(');
    expect(branch).not.toContain('confirm(');
    expect(branch).toContain('state.dismissed.add(id)');
  });

  it('filtert nur im erledigten Tab', () => {
    // A closed entry stays in the other tabs; "out of sight" is not "gone".
    // The block is the `case` arm up to the next one, not a 400-character window:
    // a window that reaches into the following arm would pass on a filter that was
    // moved out of this one.
    const branch = between("case 'done':", 'default:');
    expect(branch).toContain('state.dismissed.has(s.id)');
  });
});
