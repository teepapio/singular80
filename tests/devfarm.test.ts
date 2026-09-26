import { describe, expect, it, beforeAll, afterAll } from 'vitest';
import { spawn, type ChildProcess } from 'node:child_process';
import { setTimeout as sleep } from 'node:timers/promises';
import { join } from 'node:path';
import { existsSync, readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';

/**
 * Die Farm-Werkzeuge sind Werkzeug, kein Spielcode — aber ein Werkzeug, das
 * still nichts tut, ist schlimmer als keines: ein Debugging-Agent hält die
 * leere Liste für „alles in Ordnung" und sucht den Fehler im Spiel statt im
 * Aufbau.
 *
 * Geprüft wird deshalb der Weg, den ein Agent geht: App meldet sich an,
 * bekommt einen Befehl, meldet ein Ereignis, und der Bericht entsteht. Der
 * Emulator ist dafür nicht nötig — simuliert wird nur die App-Seite.
 */

const ROOT = join(import.meta.dirname, '..');
const BRIDGE = join(ROOT, 'tools/devfarm/bridge.mjs');
const PORT = 8799;
const BASE = `http://127.0.0.1:${PORT}`;

let bridge: ChildProcess | null = null;
let appId = null;

beforeAll(async () => {
  bridge = spawn(process.execPath, [BRIDGE], {
    env: { ...process.env, DEVFARM_BRIDGE: String(PORT) },
    stdio: 'ignore',
  });
  // Der Server muss lauschen, bevor der erste Test fragt. Eine feste Wartezeit
  // wäre wieder eine Race, nur eine andere.
  for (let i = 0; i < 40; i += 1) {
    const up = await fetch(`${BASE}/health`).then((r) => r.ok).catch(() => false);
    if (up) return;
    await sleep(150);
  }
  throw new Error('Bridge kam nicht hoch');
});

afterAll(() => {
  bridge?.kill('SIGTERM');
});

async function register(device = 'emulator-5554') {
  const res = await fetch(`${BASE}/register`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ device, model: 'pixel_5', godot: '4.5.1' }),
  }).then((r) => r.json());
  appId = res.id;
  return appId;
}

describe('Farm-Brücke', () => {
  it('vergibt bei jeder Anmeldung eine eigene Kennung', async () => {
    const first = await register('emulator-5554');
    const second = await register('emulator-5556');
    expect(first).toBeTruthy();
    expect(second).toBeTruthy();
    expect(first).not.toBe(second);
  });

  it('meldet angemeldete Apps über /health', async () => {
    await register('emulator-5554');
    const health = (await fetch(`${BASE}/health`).then((r) => r.json())) as {
      ok: boolean;
      apps: { id: string; device: string }[];
    };
    expect(health.ok).toBe(true);
    expect(health.apps.length).toBeGreaterThanOrEqual(1);
    expect(health.apps.some((a) => a.device === 'emulator-5554')).toBe(true);
  });

  it('liefert einen wartenden Abruf nicht sofort leer, sondern später den Befehl', async () => {
    const id = await register('emulator-5554');
    // Der Abruf läuft *vor* dem Zustellen des Befehls: genau das ist der Fall,
    // den ein Agent trifft, wenn die App gerade beschäftigt ist.
    const pending = fetch(`${BASE}/next?id=${id}`).then((r) => r.json());
    await sleep(200);
    await fetch(`${BASE}/command`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ id, op: 'goto', args: { screen: 'tetris' } }),
    });
    const command = await pending;
    expect(command.op).toBe('goto');
    expect(command.args.screen).toBe('tetris');
  });

  it('speichert Ereignisse, damit ein Agent sie nachlesen kann', async () => {
    const id = await register('emulator-5554');
    await fetch(`${BASE}/event`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        id,
        type: 'audit',
        data: { screen: 'tetris', findings: [{ kind: 'no-response', severity: 'fail' }] },
      }),
    });
    const events = (await fetch(`${BASE}/events?id=${id}&type=audit`).then((r) => r.json())) as {
      events: { type: string; data: { findings: { kind: string }[] } }[];
    };
    expect(events.events).toHaveLength(1);
    expect(events.events[0].data.findings[0].kind).toBe('no-response');
  });

  it('filtert Ereignisse nach Zeit, damit nichts doppelt gezählt wird', async () => {
    const id = await register('emulator-5554');
    const before = Date.now();
    await sleep(10);
    await fetch(`${BASE}/event`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ id, type: 'metrics', data: { fps: 60 } }),
    });
    const fresh = (await fetch(`${BASE}/events?id=${id}&since=${before}`)
      .then((r) => r.json())) as { events: { type: string }[] };
    expect(fresh.events.map((e: { type: string }) => e.type)).toContain('metrics');
  });

  it('weist einen Befehl ohne passende App ab, statt ihn zu verwerfen', async () => {
    const res = await fetch(`${BASE}/command`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ id: 'gibt-es-nicht', op: 'audit' }),
    });
    expect(res.status).toBe(404);
  });

  it('antwortet auf /next einer unbekannten App mit 404', async () => {
    const res = await fetch(`${BASE}/next?id=gibt-es-nicht`);
    expect(res.status).toBe(404);
  });
});

describe('Farm-Werkzeuge', () => {
  it('liest die Konfiguration und ergänzt die SDK-Pfade', async () => {
    // Die Farm ist JavaScript, hat aber eine `core.d.mts` — sonst könnte
    // `tsc` unter `strict` nichts prüfen.
    const { loadConfig } = await import('../tools/devfarm/lib/core.mjs');
    const cfg = loadConfig();
    expect(cfg.sdk).toBeTruthy();
    expect(cfg.adb.endsWith('adb')).toBe(true);
    expect(cfg.emulator.endsWith('emulator')).toBe(true);
    expect(cfg.bridgePort).toBeGreaterThan(0);
  });

  it('zählt die Screens aus dem Router, damit nichts driftet', async () => {
    const { screensOfProject } = await import('../tools/devfarm/session.mjs');
    const screens = screensOfProject();
    expect(screens.length).toBeGreaterThan(10);
    expect(screens.some((s: { id: string }) => s.id === 'tetris')).toBe(true);
    expect(screens.some((s: { id: string }) => s.id === 'siedler')).toBe(true);
    // Die Absicht des Filters: Varianten teilen den Screen mit ihrem
    // Grundspiel und würden jeden Lauf doppelt abfragen.
    expect(new Set(screens.map((s: { path: string }) => s.path)).size).toBeLessThan(screens.length);
  });

  it('findet das Farm-Preset und prüft die Architektur', () => {
    const cfgText = readFileSync(join(ROOT, 'godot/export_presets.cfg'), 'utf8');
    const start = cfgText.indexOf('name="Android (Farm)"');
    expect(start, 'Farm-Preset fehlt in export_presets.cfg').toBeGreaterThan(-1);
    const from = cfgText.lastIndexOf('[preset.', start);
    // Die Grenze muss eine echte Überschrift sein: `[preset.N.options]`
    // beginnt auch mit `[preset.` und würde die Architektur-Zeilen abschneiden.
    const match = /\n\[preset\.\d+\]/.exec(cfgText.slice(start));
    const block = match
      ? cfgText.slice(from, start + match.index)
      : cfgText.slice(from);
    expect(block).toContain('architectures/x86_64=true');
    expect(block).toContain('architectures/arm64-v8a=true');
  });

  it('gibt der Farm einen eigenen Paketnamen, damit sie das echte Spiel nicht anfasst', () => {
    const cfgText = readFileSync(join(ROOT, 'godot/export_presets.cfg'), 'utf8');
    const start = cfgText.indexOf('name="Android (Farm)"');
    const from = cfgText.lastIndexOf('[preset.', start);
    const match = /\n\[preset\.\d+\]/.exec(cfgText.slice(start));
    const block = match
      ? cfgText.slice(from, start + match.index)
      : cfgText.slice(from);
    expect(block).toContain('de.singular80.farm');
    expect(block).not.toContain('package/unique_name="de.singular80.game"');
  });

  it('startet das DevFarm-Autoload nur mit dem Schalter', () => {
    const autoload = readFileSync(join(ROOT, 'godot/src/core/autoload/devfarm.gd'), 'utf8');
    expect(autoload).toContain('const FLAG := "--devfarm"');
    // Ohne den Schalter muss sich das Autoload sofort wieder abmelden: ein
    // Autoload, das im ausgelieferten Spiel einen offenen Socket hält, wäre
    // ein Fehler, den niemand suchen würde.
    expect(autoload).toMatch(/set_process\(false\)/);
  });

  it('prüft im Audit die Fläche, die Deckung UND die Reaktion', () => {
    const audit = readFileSync(join(ROOT, 'godot/src/core/logic/devfarm_audit.gd'), 'utf8');
    expect(audit).toContain('zero-size');
    expect(audit).toContain('covered');
    expect(audit).toContain('no-response');
    // Der entscheidende Punkt: ein echter Touch, kein nachgebauter Aufruf.
    expect(audit).toContain('InputEventScreenTouch');
    expect(audit).toContain('Input.parse_input_event');
  });
});
