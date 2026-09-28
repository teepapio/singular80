/**
 * The desktop launcher: what a double-click on the symbol is allowed to do.
 *
 * These are cheap assertions about a shell script, and each one guards a
 * mistake that is invisible until somebody sits in front of the machine: a
 * terminal that never closes, a landing page in front of the dashboard, a
 * second browser tab nobody asked for.
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
    // Ohne `setsid` stirbt der Dev-Server mit dem Terminal, in dem der Starter
    // lief — und mit einem Terminal, das nicht stirbt, bleibt eines sichtbar.
    expect(start).toContain('setsid nohup npm run dev');
    // Die Ausgabe landet in einer Datei, nicht auf dem Bildschirm.
    expect(start).toMatch(/> "\$LOG_FILE" 2>&1 < \/dev\/null &/);
  });

  it('druckt keine Startvorschrift', () => {
    // Der alte Block mit "SINGULAR 80 startet …" war der Vorspann.
    expect(start).not.toContain('startet …');
    expect(start).not.toContain('Dashboard:  http');
  });

  it('öffnet die Hauptseite und genau ein Fenster', () => {
    expect(start).toContain('DASHBOARD_URL="http://localhost:5173/"');
    // Genau ein `xdg-open`: zwei Tabs (Spiel + Dashboard) waren der Grund, dass
    // sich der Start wie ein Bildschirm mit einem Vorspann anfühlt.
    expect(start.match(/xdg-open/g) ?? []).toHaveLength(1);
  });

  it('wartet auf die Seite, statt blind zu schlafen', () => {
    // Der alte Ablauf war `( sleep 4; xdg-open … )`. Auf einem langsamen Rechner
    // öffnete sich der Browser vor dem Server und zeigte dann für immer eine
    // Fehlerseite — also wird die Seite abgefragt, bis sie antwortet.
    expect(start).not.toMatch(/\(\s*\n?\s*sleep \d+;\s*xdg-open/);
    expect(start).toContain('while [ "$waited" -lt 60 ]');
    expect(start).toContain('curl -fsS -o /dev/null "$DASHBOARD_URL"');
  });

  it('kann den Server wieder beenden, weil es kein Terminal zum Strg+C gibt', () => {
    expect(start).toContain('stop)');
    // Die Prozessgruppe, nicht nur `npm`: sonst bleibt der Vite-Server als
    // Waiszeug auf Port 5173 liegen.
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
    // Die alte Landingpage war eine Spieleliste mit einem Knopf zum Dashboard.
    // Geprüft wird an *ihrer* Markup-Struktur, nicht an Worten, die in einem
    // Kommentar über sie stehen.
    expect(index).toContain('OpenCode Runs');
    expect(index).toContain('id="task-form"');
    expect(index).not.toContain('<h1>SINGULAR 80</h1>');
    expect(index).not.toContain('class="tagline"');
    expect(index).not.toContain('class="button"');
  });

  it('trägt die Zustandsanzeige des Servers', () => {
    // Ohne diese Leiste bleibt ein Serverausfall nur an einem roten Punkt
    // erkennbar, und die Seite meldet sich alle acht Sekunden mit demselben
    // Fehler.
    expect(index).toContain('id="api-state"');
  });

  it('leitet alte /dashboard.html-Links weiter, statt 404 zu geben', () => {
    expect(redirect).toContain("location.replace('/')");
    // Kein `<link rel="canonical" href="/">`: Vite löst die URL beim Bau als
    // Asset auf, und `/` ist ein Verzeichnis — der Build bricht dann ab.
    expect(redirect).not.toContain('rel="canonical"');
  });
});
