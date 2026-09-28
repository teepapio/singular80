/**
 * The desktop launcher: what a double-click on the symbol is allowed to do. Cheap
 * assertions about a shell script, each guarding a mistake that is invisible until
 * somebody sits in front of the machine: a terminal that never closes, a second
 * browser tab nobody asked for.
 */
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const start = readFileSync(join(ROOT, 'start.sh'), 'utf8');
const desktop = readFileSync(join(ROOT, 'packaging/singular80.desktop'), 'utf8');
const index = readFileSync(join(ROOT, 'index.html'), 'utf8');
const redirect = readFileSync(join(ROOT, 'dashboard.html'), 'utf8');

describe('start.sh', () => {
  it('ist syntaktisch gültig', () => {
    expect(() => execFileSync('bash', ['-n', join(ROOT, 'start.sh')])).not.toThrow();
  });

  it('lässt kein Terminal offen, indem es den Server in eine eigene Sitzung hängt', () => {
    // Without `setsid` the dev server dies with the terminal the starter ran in, and
    // a terminal that does not die stays visible.
    expect(start).toContain('setsid nohup npm run dev');
    // Output goes to a file, not to the screen.
    expect(start).toMatch(/> "\$LOG_FILE" 2>&1 < \/dev\/null &/);
  });

  it('druckt keine Startvorschrift', () => {
    // The old "SINGULAR 80 startet …" block was the intro screen.
    expect(start).not.toContain('startet …');
    expect(start).not.toContain('Dashboard:  http');
  });

  it('öffnet die Hauptseite und genau ein Fenster', () => {
    expect(start).toContain('DASHBOARD_URL="http://localhost:5173/"');
    // Exactly one `xdg-open`: two tabs (game + dashboard) made the start feel like a
    // screen with an intro.
    expect(start.match(/xdg-open/g) ?? []).toHaveLength(1);
  });

  it('wartet auf die Seite, statt blind zu schlafen', () => {
    // The old flow was `( sleep 4; xdg-open … )`: on a slow machine the browser beat
    // the server and showed an error page forever. Hence the poll.
    expect(start).not.toMatch(/\(\s*\n?\s*sleep \d+;\s*xdg-open/);
    expect(start).toContain('while [ "$waited" -lt 60 ]');
    expect(start).toContain('curl -fsS -o /dev/null "$DASHBOARD_URL"');
  });

  it('kann den Server wieder beenden, weil es kein Terminal zum Strg+C gibt', () => {
    expect(start).toContain('stop)');
    // The process group, not just `npm`, or the Vite server stays behind on 5173.
    expect(start).toContain('ps -o pgid=');
  });

  it('startet keinen zweiten Server, wenn schon einer läuft', () => {
    expect(start).toContain('if running; then');
  });
});

describe('Desktop-Verknüpfung', () => {
  it('öffnet kein Terminal', () => {
    expect(desktop).toMatch(/^Terminal=false$/m);
  });

  it('ruft den Starter auf, nicht npm direkt', () => {
    expect(desktop).toContain('start.sh');
    expect(desktop).not.toContain('npm run dev');
  });

  it('ist als ausführbar installierbar', () => {
    expect(start).toContain('install -m 0755 "$source"');
  });
});

describe('Hauptseite', () => {
  it('ist das Dashboard selbst, ohne Vorspann', () => {
    // The old landing page was a game list with a button to the dashboard. Asserted
    // on its markup, not on words that might appear in a comment about it.
    expect(index).toContain('OpenCode Runs');
    expect(index).toContain('id="task-form"');
    expect(index).not.toContain('<h1>SINGULAR 80</h1>');
    expect(index).not.toContain('class="tagline"');
    expect(index).not.toContain('class="button"');
  });

  it('trägt die Zustandsanzeige des Servers', () => {
    // Without this bar an outage shows up as a red dot only, and the page reports the
    // same error every eight seconds.
    expect(index).toContain('id="api-state"');
  });

  it('leitet alte /dashboard.html-Links weiter, statt 404 zu geben', () => {
    expect(redirect).toContain("location.replace('/')");
    // No `<link rel="canonical" href="/">`: Vite resolves that URL as an asset at
    // build time and `/` is a directory, so the build breaks.
    expect(redirect).not.toContain('rel="canonical"');
  });
});
