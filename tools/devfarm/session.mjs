#!/usr/bin/env node
/**
 * Eine Testsession auf einer gemieteten Instanz.
 *
 *   node tools/devfarm/session.mjs --game tetris --audit
 *   node tools/devfarm/session.mjs --game siedler --goto siedler --soak 30
 *   node tools/devfarm/session.mjs --sweep            # alle Spiele nacheinander
 *   node tools/devfarm/session.mjs --list-games
 *
 * Das ist die einzige Datei, die ein Debugging-Agent kennen muss. Sie macht
 * alles von Hand für ihn: Instanz mieten, APK installieren, App starten,
 * Logcat mitschreiben, Bildschirmfotos ziehen, Befehle über die Bridge
 * schicken, Fundorte und Messwerte sammeln, Bericht schreiben, Instanz
 * freigeben.
 *
 * Der Bericht liegt unter `log/devfarm/<lauf>/<spiel>/` und ist bewusst
 * maschinenlesbar: `report.json` für die Zahlen, `logcat.txt` für die
 * Rohdaten, `shot-*.png` für die Augen. Ein Agent, der nur eine Frage hat,
 * braucht kein Bild ansehen — er liest `report.json`.
 */
import { spawn } from 'node:child_process';
import { createWriteStream, existsSync, mkdirSync, readFileSync, writeFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import {
  Lease, ROOT, adb, adbTry, ensureDir, hash, listDevices, loadConfig, readJson, run, tryRun, writeJson,
} from './lib/core.mjs';
import { serialFor } from './lib/emulator.mjs';

const cfg = loadConfig();

function parseFlags(argv) {
  const flags = {};
  for (let i = 0; i < argv.length; i += 1) {
    if (!argv[i].startsWith('--')) continue;
    const key = argv[i].slice(2);
    const next = argv[i + 1];
    if (next !== undefined && !next.startsWith('--')) {
      flags[key] = next;
      i += 1;
    } else {
      flags[key] = true;
    }
  }
  return flags;
}

/** Die Screens, die es zu prüfen gibt — aus dem Router, damit nichts driftet. */
export function screensOfProject() {
  const router = readFileSync(join(ROOT, 'godot/src/core/autoload/router.gd'), 'utf8');
  const out = [];
  for (const match of router.matchAll(/"([\w0-9]+)":\s*"res:\/\/src\/game\/([^"]+)"/g)) {
    out.push({ id: match[1], path: match[2] });
  }
  return out;
}

/** Baut das Farm-APK, wenn es fehlt oder älter als der Baum ist. */
function ensureApk({ force = false } = {}) {
  if (!force && existsSync(cfg.apkPath)) {
    const age = Date.now() - statSync(cfg.apkPath).mtimeMs;
    if (age < 10 * 60_000) return cfg.apkPath;
  }
  ensureDir('log/devfarm');
  console.log('[session] baue das Farm-APK …');
  const result = tryRun('godot', [
    '--headless', '--path', 'godot', '--export-debug', cfg.apkPreset, cfg.apkPath,
  ], { cwd: process.cwd() });
  if (!result.ok) {
    const tail = result.out.split('\n').filter((l) => /error|error/i.test(l)).slice(-5);
    throw new Error(`Farm-Export fehlgeschlagen:\n${tail.join('\n') || result.out.slice(-500)}`);
  }
  return cfg.apkPath;
}

/** Meldet sich bei der Bridge an und wartet, bis genau eine App bereit ist. */
async function waitForApp(timeoutMs = 90_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const res = await fetch(`http://127.0.0.1:${cfg.bridgePort}/health`).then((r) => r.json()).catch(() => null);
    if (res?.apps?.length) return res.apps[res.apps.length - 1];
    await sleep(1000);
  }
  throw new Error('keine App hat sich bei der Bridge gemeldet');
}

async function sendCommand(appId, op, args = {}) {
  const res = await fetch(`http://127.0.0.1:${cfg.bridgePort}/command`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ id: appId, op, args }),
  }).then((r) => r.json()).catch((e) => ({ error: e.message }));
  if (res.error) throw new Error(`Befehl ${op}: ${res.error}`);
  return res;
}

/** Wartet, bis ein bestimmtes Ereignistyp nach `since` auftaucht. */
async function waitForEvent(appId, type, since, timeoutMs = 45_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const res = await fetch(`http://127.0.0.1:${cfg.bridgePort}/events?id=${appId}&since=${since}&type=${type}`)
      .then((r) => r.json()).catch(() => null);
    if (res?.events?.length) return res.events[0];
    await sleep(700);
  }
  return null;
}

function nowMs(appId) {
  return Date.now();
}

/** Logcat mitlesen, bis der Prozess beendet wird. */
function startLogcat(serial, file) {
  const out = createWriteStream(file, { flags: 'w' });
  const child = spawn(cfg.adb, ['-s', serial, 'logcat', '-v', 'threadtime'], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.pipe(out);
  child.stderr.pipe(out);
  return {
    stop() {
      try {
        child.kill('SIGTERM');
      } catch {
        /* schon weg */
      }
      out.end();
    },
  };
}

/** Zieht ein Bild vom Gerät. */
function pullShot(serial, remote, local) {
  adbTry(cfg, serial, ['pull', remote, local]);
  tryRun('adb', ['-s', serial, 'shell', 'rm', '-f', remote]);
  return existsSync(local);
}

/**
 * Eine ganze Session: mieten, installieren, starten, prüfen, melden, freigeben.
 *
 * Der `finally` ist hier der eigentliche Inhalt: eine Instanz, die wegen eines
 * Fehlers hängen bleibt, blockiert den nächsten Agenten, und vier blockierte
 * Instanzen machen die Farm unbrauchbar. Deshalb wird die Lease unter allen
 * Umständen freigegeben — auch wenn der Export scheitert oder der Timeout
 * greift.
 */
export async function runSession({
  game, screen, audit = true, soakSeconds = 0, shots = 0, label = '',
}) {
  const registry = readJson(join(cfg.stateDir, 'instances.json'), { instances: [] });
  const ready = registry.instances.filter((i) => i.state === 'ready' || i.index !== undefined);
  if (ready.length === 0) throw new Error('keine Instanzen bekannt — erst farmd start');

  const instance = ready[0];
  const lease = new Lease(instance.lease, { timeoutMs: 120_000 });
  const serial = instance.serial;
  const runId = `${new Date().toISOString().replace(/[:.]/g, '-')}${label ? `-${label}` : ''}`;
  const outDir = ensureDir(join(cfg.outDir, runId, game ?? 'all'));
  const report = {
    runId,
    game: game ?? null,
    screen: screen ?? null,
    serial,
    startedAt: Date.now(),
    findings: [],
    audits: [],
    metrics: [],
    shots: [],
    errors: [],
    logcat: join(outDir, 'logcat.txt'),
    ok: false,
    notes: [],
  };

  let logcat = null;
  try {
    lease.acquire(`session:${runId}`);
    const apk = ensureApk({});

    // Die App muss vor der Bridge-Anmeldung schon mit dem Schalter laufen.
    logcat = startLogcat(serial, report.logcat);
    await sleep(500);
    adbTry(cfg, serial, ['shell', 'am', 'force-stop', cfg.package]);
    const installed = adbTry(cfg, serial, ['install', '-r', '-g', apk]);
    if (!installed.ok) throw new Error(`APK-Installation fehlgeschlagen:\n${installed.out.slice(-400)}`);
    adbTry(cfg, serial, ['logcat', '-c']);

    adb(cfg, serial, [
      'shell', 'am', 'start', '-n', cfg.activity,
      '--es', 'devfarm', '1',
    ]);
    // Der Schalter kommt als Benutzer-Argument hinter `--`; ohne das wäre er
    // ein Intent-Extra, das Godot nicht liest.
    log(`[session] ${game ?? 'alle'} auf ${serial} gestartet`);

    const app = await waitForApp();
    report.app = app.id;
    if (screen) {
      const mark = nowMs(app.id);
      await sendCommand(app.id, 'goto', { screen });
      const evt = await waitForEvent(app.id, 'screen', mark - 1);
      report.notes.push(`goto ${screen}: ${evt ? 'bestätigt' : 'keine Antwort'}`);
      await sleep(1200);
    }

    if (audit) {
      const mark = Date.now() - 1;
      await sendCommand(app.id, 'audit', {});
      const evt = await waitForEvent(app.id, 'audit', mark, 60_000);
      if (evt) {
        report.audits.push(evt.data);
        for (const finding of evt.data.findings ?? []) {
          report.findings.push({ screen: evt.data.screen, ...finding });
        }
      } else {
        report.notes.push('Audit: keine Antwort');
      }
    }

    for (let i = 0; i < Number(shots); i += 1) {
      const mark = Date.now() - 1;
      await sendCommand(app.id, 'shot', {});
      const evt = await waitForEvent(app.id, 'shot', mark, 20_000);
      if (evt?.data?.path) {
        const local = join(outDir, `shot-${String(i + 1).padStart(2, '0')}.png`);
        if (pullShot(serial, evt.data.path, local)) report.shots.push(local);
      }
    }

    if (Number(soakSeconds) > 0) {
      const mark = Date.now() - 1;
      await sendCommand(app.id, 'soak', { seconds: Number(soakSeconds) });
      const evt = await waitForEvent(app.id, 'soak', mark, Number(soakSeconds) * 1000 + 30_000);
      report.notes.push(`soak: ${evt ? JSON.stringify(evt.data) : 'keine Antwort'}`);
      const mMark = Date.now() - 1;
      await sendCommand(app.id, 'metrics', {});
      const metrics = await waitForEvent(app.id, 'metrics', mMark, 20_000);
      if (metrics) report.metrics.push(metrics.data);
    }

    // Fehler aus dem Log holen. Der Filter ist bewusst eng: `E/` ist Godots
    // Fehlerkanal, `F/` der für Fatals. Alles andere zu filtern macht die
    // Ausgabe so groß, dass niemand sie liest.
    const text = existsSync(report.logcat) ? readFileSync(report.logcat, 'utf8') : '';
    for (const line of text.split('\n')) {
      if (!/\s[EF]\//.test(line)) continue;
      if (/DevFarmAudit|devfarm/.test(line)) continue;
      report.errors.push(line.trim().slice(0, 400));
    }
    report.errors = report.errors.slice(0, 200);
    report.ok = report.findings.length === 0 && report.errors.length === 0;
  } finally {
    logcat?.stop();
    writeJson(join(outDir, 'report.json'), report);
    adbTry(cfg, serial, ['shell', 'am', 'force-stop', cfg.package]);
    lease.release();
  }

  return { report, outDir };
}

const flags = parseFlags(process.argv.slice(2));
const command = process.argv[2] ?? 'help';

if (flags['list-games']) {
  for (const entry of screensOfProject()) console.log(`${entry.id}\t${entry.path}`);
} else if (flags.sweep) {
  const screens = screensOfProject();
  const only = flags.game ? String(flags.game).split(',') : null;
  const targets = screens.filter((s) => (only ? only.includes(s.id) : !s.id.includes('_')));
  const all = [];
  for (const target of targets) {
    process.stdout.write(`[sweep] ${target.id} … `);
    try {
      const { report, outDir } = await runSession({
        game: target.id,
        screen: target.id,
        audit: flags.audit !== 'false',
        soakSeconds: Number(flags.soak ?? 0),
        shots: Number(flags.shots ?? 1),
        label: 'sweep',
      });
      all.push(report);
      console.log(`${report.findings.length} Funde, ${report.errors.length} Fehlerzeilen → ${outDir}`);
    } catch (err) {
      console.log(`FEHLER: ${err.message}`);
      all.push({ game: target.id, error: err.message });
    }
  }
  const summary = ensureDir(join(cfg.outDir, 'sweep'));
  writeJson(join(summary, 'summary.json'), { at: Date.now(), results: all });
  console.log(`\nZusammenfassung: ${join(summary, 'summary.json')}`);
} else if (command === 'help' || (!flags.game && !flags.sweep)) {
  console.log(`Aufruf:
  session.mjs --game <id> [--screen <id>] [--audit] [--soak N] [--shots N]
  session.mjs --sweep [--game a,b] [--audit=false] [--soak N] [--shots N]
  session.mjs --list-games`);
} else {
  const { report, outDir } = await runSession({
    game: String(flags.game),
    screen: flags.screen ? String(flags.screen) : String(flags.game),
    audit: flags.audit !== 'false',
    soakSeconds: Number(flags.soak ?? 0),
    shots: Number(flags.shots ?? 0),
    label: String(flags.label ?? 'one'),
  });
  console.log(JSON.stringify({ outDir, findings: report.findings.length, errors: report.errors.length }, null, 2));
}
