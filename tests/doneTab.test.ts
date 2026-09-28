import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * The "done" tab is a place to look back. A card there that offers to implement
 * a finished task contradicts itself, and the owner asked for the
 * implementation details to go entirely.
 *
 * Source-level assertions: the dashboard has no DOM in the test suite, and the
 * failure this guards — someone re-adding a button while fixing something else
 * — is visible as a string in the template.
 */

const MAIN = readFileSync(join(import.meta.dirname, '..', 'src/dashboard/main.ts'), 'utf8');

function renderCardSource(): string {
  const from = MAIN.indexOf('function renderCard');
  return MAIN.slice(from, MAIN.indexOf('function renderList'));
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
    expect(card).toContain('!settled && s.status !==');
    // The button itself stays in the template, behind the guard.
    const guard = card.indexOf('!settled && s.status !== \'implementing\' && !hasChildren');
    const button = card.indexOf('data-action="implement"');
    expect(guard).toBeGreaterThan(-1);
    expect(button).toBeGreaterThan(guard);
  });

  it('bietet auch "Aufteilen" nicht mehr an', () => {
    expect(renderCardSource()).toMatch(/!settled && s\.status !== 'implemented'[\s\S]{0,80}data-action="split"/);
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
    expect(card).toContain('badge status-${s.status}');
    expect(card).toContain('escapeHtml(s.author)');
    expect(card).toContain('timeAgo(s.createdAt)');
  });
});

describe('Schließen loescht nichts', () => {
  it('sendet keine Anfrage an den Server', () => {
    const from = MAIN.indexOf("action === 'dismiss'");
    const branch = MAIN.slice(from, MAIN.indexOf("action === 'delete'"));
    expect(branch).not.toContain('api(');
    expect(branch).not.toContain('confirm(');
    expect(branch).toContain('state.dismissed.add(id)');
  });

  it('filtert nur im erledigten Tab', () => {
    // A closed entry stays in the other tabs; "out of sight" is not "gone".
    const from = MAIN.indexOf("case 'done':");
    expect(MAIN.slice(from, from + 400)).toContain('state.dismissed.has(s.id)');
  });
});
