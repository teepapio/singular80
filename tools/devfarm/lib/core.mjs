/**
 * Gemeinsame Bausteine der Android-Testfarm.
 *
 * Alles hier ist absichtlich dünn um `adb` herum gelegt. Das ist der eine
 * Werkzeug, das jeder Android-Backend zur Verfügung stellt — Emulator,
 * Waydroid, echtes Tablet per USB. Die Farm weiß deshalb nichts über
 * Emulatoren; sie weiß nur, wie man ein Gerät anredet, ihm eine App geben,
 * tippen, Bildschirmfotos ziehen und Logcat lesen.
 */
import { execFile, execFileSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync, rmSync, openSync, closeSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

export const HERE = dirname(fileURLToPath(import.meta.url));
/** lib → devfarm → tools → Repo-Wurzel. */
export const ROOT = resolve(HERE, '..', '..', '..');
/** Die Farm-Konfiguration liegt eine Ebene über `lib/`. */
export const DEFAULT_CONFIG = resolve(HERE, '..', 'config.json');

/** Liest die Farm-Konfiguration; `file` erlaubt einen anderen Pfad für Tests. */
export function loadConfig(file = DEFAULT_CONFIG) {
  const cfg = JSON.parse(readFileSync(file, 'utf8'));
  cfg.sdk = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT
    || join(process.env.HOME ?? '', 'Android', 'Sdk');
  cfg.adb = join(cfg.sdk, 'platform-tools', 'adb');
  cfg.emulator = join(cfg.sdk, 'emulator', 'emulator');
  cfg.avdmanager = join(cfg.sdk, 'cmdline-tools', 'latest', 'bin', 'avdmanager');
  cfg.outDir = resolve(ROOT, cfg.outDir);
  cfg.stateDir = resolve(ROOT, cfg.stateDir);
  cfg.apkPath = resolve(ROOT, cfg.apkPath);
  return cfg;
}

/** Führt etwas aus und gibt stdout zurück; wirft bei Fehler. */
export function run(file, args, opts = {}) {
  return execFileSync(file, args, {
    encoding: 'utf8',
    maxBuffer: 1 << 28,
    stdio: ['ignore', 'pipe', 'pipe'],
    ...opts,
  });
}

/** Wie `run`, aber wirft nicht — für Abfragen, die oft fehlschlagen dürfen. */
export function tryRun(file, args, opts = {}) {
  try {
    return { ok: true, out: run(file, args, opts), code: 0 };
  } catch (err) {
    return {
      ok: false,
      code: typeof err.status === 'number' ? err.status : 1,
      out: `${err.stdout ?? ''}${err.stderr ?? ''}`,
      error: err,
    };
  }
}

export function ensureDir(dir) {
  mkdirSync(dir, { recursive: true });
  return dir;
}

export function writeJson(file, value) {
  ensureDir(dirname(file));
  writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

export function readJson(file, fallback = null) {
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

/** Kurzer, stabiler Hash — für Artefakt- und Session-Identität. */
export function hash(text, length = 10) {
  return createHash('sha256').update(String(text)).digest('hex').slice(0, length);
}

// --- Geräteansprache ---------------------------------------------------------

/** `adb -s <serial> …` als Argumente, damit Aufrufe einheitlich bleiben. */
export function adbArgs(cfg, serial, args) {
  return ['-s', serial, ...args];
}

export function adb(cfg, serial, args, opts = {}) {
  return run(cfg.adb, adbArgs(cfg, serial, args), opts);
}

export function adbTry(cfg, serial, args, opts = {}) {
  return tryRun(cfg.adb, adbArgs(cfg, serial, args), opts);
}

/** Alle per adb sichtbaren Geräte, als `{ serial, state }`. */
export function listDevices(cfg) {
  const result = tryRun(cfg.adb, ['devices']);
  if (!result.ok) return [];
  const devices = [];
  for (const line of result.out.split('\n').slice(1)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const [serial, state] = trimmed.split(/\s+/);
    devices.push({ serial, state });
  }
  return devices;
}

/**
 * Ein exklusiver Mitschnitt auf einer Datei.
 *
 * `flock` ist der ganze Kern der Vermittlung: Zwei Agenten, die gleichzeitig
 * dieselbe Instanz anfordern, bekommen nicht beide sie. Der Kernel entscheidet,
 * nicht ein Lockfile-Check, der zwischen Lesen und Schreiben zerbricht. Und
 * stirbt ein Agent, gibt das OS den Anspruch automatisch frei — eine
 * Lease, die beim Tod hängen bliebe, würde die Farm dauerhaft verstopfen.
 */
export class Lease {
  constructor(file, { timeoutMs = 0, onWait = null } = {}) {
    ensureDir(dirname(file));
    this.file = file;
    this.timeoutMs = timeoutMs;
    this.onWait = onWait;
    this.handle = null;
  }

  /** Belegt die Lease oder wirft nach Ablauf. */
  acquire(owner) {
    const started = Date.now();
    ensureDir(dirname(this.file));
    const fd = openSync(this.file, 'a+');
    while (true) {
      try {
        // `flock` als externes Kommando: `fs` bietet kein flock, und Node
        // kennt keine Dateisperren im Kern.
        execFileSync('flock', ['-n', String(fd), 'true'], { stdio: 'ignore' });
        this.handle = fd;
        this.owner = owner;
        return this;
      } catch {
        if (this.timeoutMs > 0 && Date.now() - started > this.timeoutMs) {
          closeQuietly(fd);
          throw new Error(`Lease belegt: ${this.file} (${owner})`);
        }
        this.onWait?.(this.file);
        sleepSync(700);
      }
    }
  }

  release() {
    if (this.handle === null) return;
    closeQuietly(this.handle);
    this.handle = null;
  }
}

function closeQuietly(fd) {
  try {
    // Der Anspruch hängt an der offenen Datei, nicht am Inhalt.
    execFileSync('flock', ['-u', String(fd)], { stdio: 'ignore' });
  } catch {
    /* egal — der close gibt die Sperre ohnehin frei */
  }
  try {
    closeSync(fd);
  } catch {
    /* schon zu */
  }
}

/** Blockierend warten, ohne den Event-Loop zu brauchen. */
function sleepSync(ms) {
  const until = Date.now() + ms;
  while (Date.now() < until) {
    execFileSync('sleep', ['0.1']);
  }
}

/** Rechnet Bildschirmmaße in die midpoint-Position eines Elements. */
export function centreOf(rect) {
  return { x: Math.round(rect.x + rect.width / 2), y: Math.round(rect.y + rect.height / 2) };
}

/** `mm:ss` aus Sekunden — für Logzeilen und Berichte. */
export function stamp(seconds) {
  const total = Math.max(0, Math.round(seconds));
  return `${String(Math.floor(total / 60)).padStart(2, '0')}:${String(total % 60).padStart(2, '0')}`;
}
