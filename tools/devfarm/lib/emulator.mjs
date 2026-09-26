/**
 * Emulator-Backend: N Instanzen aus **einem** AVD.
 *
 * Der entscheidende Schalter ist `-read-only`. Ohne ihn teilen sich die
 * Instanzen ein Benutzerdaten-Image und die erste schreibt darauf, während die
 * zweite noch bootet — das ergibt genau die Art Absturz, die man einem
 * Testwerkzeug nicht anlasten will. Mit `-read-only` bekommt jede Instanz
 * Schreibzugriff auf eine eigene Kopie im Arbeitsspeicher, mehrere dürfen
 * gleichzeitig aus demselben AVD laufen, und es kostet nur RAM statt
 * Festplatte.
 *
 * Warum nicht Waydroid: Waydroid braucht `binder_ls` und `ashmem` im Kernel.
 * Der Ubuntu-Mainline-Kernel hat sie nicht, und das Paket steht nicht einmal in
 * den Quellen — auf dieser Maschine also keine Option, unabhängig davon, wie
 * sauber man es einrichtet. `waydroid.mjs` spricht dieselbe Schnittstelle an,
 * falls der Kernel eines Tages doch passt.
 */
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { adbTry, ensureDir, hash, listDevices, run, tryRun } from './core.mjs';

/** Legt das AVD an, falls es noch nicht existiert. */
export function ensureAvd(cfg) {
  const home = join(cfg.sdk, '.android', 'avd');
  if (existsSync(join(home, `${cfg.avd}.avd`)) || existsSync(join(home, `${cfg.avd}.ini`))) {
    return false;
  }
  ensureDir(home);
  const result = tryRun(cfg.avdmanager, [
    'create', 'avd',
    '-n', cfg.avd,
    '-k', cfg.systemImage,
    '-d', cfg.deviceProfile,
    '--force',
  ], { env: { ...process.env, ANDROID_AVD_HOME: home } });
  if (!result.ok) {
    throw new Error(`avdmanager: ${result.out.trim().split('\n').slice(-5).join('\n')}`);
  }
  // Ohne diese Zeile startet der erste Emulator mit einem Wizard-Dialog und
  // wartet ewig auf eine Eingabe, die es headless nicht gibt.
  const ini = join(home, `${cfg.avd}.ini`);
  if (existsSync(ini)) {
    const text = readFileSync(ini, 'utf8');
    if (!text.includes('hw.gpu.enabled')) {
      writeFileSync(ini, `${text}hw.gpu.enabled=yes\nhw.gpu.mode=auto\n`, 'utf8');
    }
  }
  return true;
}

/** Die adb-Serial, die zu einem Port gehört: `emulator-5554`. */
export function serialFor(port) {
  return `emulator-${port}`;
}

/**
 * Startet eine Instanz und wartet, bis sie wirklich gebootet hat.
 *
 * `adb wait-for-device` ist zu früh: es kehrt zurück, sobald adb das Gerät
 * sieht, und das ist lange vor `sys.boot_completed`. Wer daraufhin die App
 * startet, misst den Splash-Screen und wundert sich über „keine Fehler".
 */
export async function startInstance(cfg, index, { onLog = () => {} } = {}) {
  const port = cfg.basePort + index * 2;
  const serial = serialFor(port);
  const logFile = join(ensureDir(cfg.stateDir), `emulator-${port}.log`);

  const already = listDevices(cfg).find((d) => d.serial === serial);
  if (already?.state === 'device') {
    return { port, serial, reused: true };
  }

  const args = [
    '-avd', cfg.avd,
    '-port', String(port),
    '-read-only',
    '-no-window',
    '-no-audio',
    '-no-boot-anim',
    '-no-snapshot-load',
    '-no-metrics',
    '-gpu', cfg.gpu,
    '-camera-back', 'none',
    '-camera-front', 'none',
  ];

  const child = spawn(cfg.emulator, args, {
    stdio: ['ignore', 'pipe', 'pipe'],
    detached: true,
  });
  child.unref();

  const out = [];
  const collect = (chunk) => {
    const text = chunk.toString();
    out.push(text);
    writeFileSync(logFile, out.join(''), 'utf8');
    onLog(text);
  };
  child.stdout.on('data', collect);
  child.stderr.on('data', collect);
  writeFileSync(`${logFile}.pid`, String(child.pid ?? ''), 'utf8');

  await waitForBoot(cfg, serial, cfg.bootTimeoutSeconds);
  return { port, serial, reused: false, pid: child.pid };
}

/** Wartet auf `sys.boot_completed=1` — der Punkt, an dem die App lauffähig ist. */
export async function waitForBoot(cfg, serial, timeoutSeconds = 240) {
  const deadline = Date.now() + timeoutSeconds * 1000;
  adbTry(cfg, serial, ['wait-for-device']);
  while (Date.now() < deadline) {
    const res = adbTry(cfg, serial, ['shell', 'getprop', 'sys.boot_completed']);
    if (res.ok && res.out.trim() === '1') {
      // Das Paketmanagement ist danach manchmal noch nicht bereit; ein
      // `pm`-Aufruf wäre dann der erste Fehler im Log und würde wie ein
      // App-Problem aussehen.
      const pm = adbTry(cfg, serial, ['shell', 'pm', 'path', 'android']);
      if (pm.ok) return true;
    }
    await sleep(1500);
  }
  throw new Error(`${serial} wurde in ${timeoutSeconds}s nicht bootfertig`);
}

/** Beendet eine Instanz. */
export function stopInstance(cfg, index) {
  const port = cfg.basePort + index * 2;
  const serial = serialFor(port);
  adbTry(cfg, serial, ['emu', 'kill']);
  const pidFile = join(cfg.stateDir, `emulator-${port}.log.pid`);
  if (existsSync(pidFile)) {
    const pid = readFileSync(pidFile, 'utf8').trim();
    if (pid) {
      try {
        process.kill(Number(pid), 'SIGKILL');
      } catch {
        /* schon beendet */
      }
    }
  }
  return serial;
}

/** Löscht das AVD samt-userdata (nur für einen Neuaufbau gedacht). */
export function destroyAvd(cfg) {
  const home = join(cfg.sdk, '.android', 'avd');
  for (const name of [`${cfg.avd}.avd`, `${cfg.avd}.ini`]) {
    rmSync(join(home, name), { recursive: true, force: true });
  }
}
