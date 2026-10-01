import { describe, expect, it } from 'vitest';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * The session's output belongs in the panel on the right, not in a terminal
 * window on the desktop.
 *
 * That is the way it was, then it was changed to a real terminal window so the
 * owner could type into the session, and it has been changed back. These are the
 * assertions that keep it there — on both sides, because the revert is two
 * halves: the runner must pipe the session again (otherwise there is nothing to
 * show), and the dashboard must draw the lines again (otherwise there is nowhere
 * to show them).
 *
 * Source-level on purpose, like `queueTaskText.test.ts`: the dashboard has no DOM
 * in the suite, and both failures are one missing string in a template.
 */

const ROOT = join(import.meta.dirname, '..');
const MAIN = readFileSync(join(ROOT, 'src/dashboard/main.ts'), 'utf8');
const RUNNER = readFileSync(join(ROOT, 'server/runner.ts'), 'utf8');
const APP = readFileSync(join(ROOT, 'server/app.ts'), 'utf8');

/** Slices the source between two markers, refusing to guess if one is missing. */
function block(start: string, end: string): string {
  const from = MAIN.indexOf(start);
  const to = MAIN.indexOf(end, from);
  expect(from, `Startmarker ${start} gefunden`).toBeGreaterThan(-1);
  expect(to, `Endmarker ${end} gefunden`).toBeGreaterThan(from);
  return MAIN.slice(from, to);
}

describe('Die Sitzung läuft wieder im Panel', () => {
  it('der Runner startet den gepipten Lauf mit JSON-Ausgabe', () => {
    // `opencode run --format json` is what the runner parses for the summary,
    // the cost and the session id, and what produces the lines below.
    expect(RUNNER).toContain("['run', '--format', 'json'");
    expect(RUNNER).toContain('startPiped');
  });

  it('der Runner öffnet kein Terminalfenster mehr', () => {
    expect(RUNNER).not.toContain('openTerminal');
    expect(RUNNER).not.toContain('findTerminal');
    expect(RUNNER).not.toContain('S80_TERMINAL');
    expect(APP).not.toContain('terminalRuns');
    expect(APP).not.toContain('terminalMode');
    // The helper that found an emulator and built the launch command is gone with
    // it: leaving the module would leave a second way to start a session in a
    // window, unused and untested.
    expect(existsSync(join(ROOT, 'server/terminal.ts'))).toBe(false);
  });

  it('die Run-Karte hat wieder eine Konsole', () => {
    const card = block('function renderRunCard', 'function suggestionAuthor');
    expect(card).toContain('data-run-console');
    // The last 400 lines, oldest first, in the order the runner wrote them.
    expect(card).toContain('eventsOf(run.id)');
    expect(card).toContain('.slice(-400)');
    expect(card).toContain('class="line ${event.kind}"');
  });

  it('die Konsole wird ans Ende gescrollt', () => {
    // Without this the newest line lands below the visible area and the panel
    // looks stuck on whatever was written a minute ago.
    expect(block('function renderRuns', 'function renderQueueState')).toContain(
      'consoleEl.scrollTop = consoleEl.scrollHeight',
    );
  });

  it('eine neue Zeile kommt live in die Konsole', () => {
    const handler = block("event.type === 'run:log'", "event.type === 'run:finished'");
    expect(handler).toContain('state.runEvents.set(event.runId, buffer)');
    expect(handler).toContain('consoleEl.appendChild(line)');
    // Bounded, or a long run keeps every line it ever wrote.
    expect(handler).toContain('buffer.length > 1500');
  });

  it('ein Neuladen holt die Zeilen vom Server nach', () => {
    // `RunView.events` is what fills the console after a reload or a missed
    // stream line; without it the panel starts empty on every page load.
    expect(MAIN).toContain('state.runEvents.set(view.id, view.events ?? [])');
    // A finished lane gives its buffer back, so it cannot reappear on the next
    // start event.
    expect(block('async function loadRuns', 'function pruneAudits')).toContain('state.runEvents.delete(id)');
  });
});
