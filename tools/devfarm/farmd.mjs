#!/usr/bin/env node
/**
 * Die Farm läuft **außerhalb** von opencode.
 *
 *   node tools/devfarm/farmd.mjs start [--instances 4]
 *   node tools/devfarm/farmd.mjs status
 *   node tools/devfarm/farmd.mjs stop
 *
 * Warum ein eigener Prozess: Ein Agent-Subthread lebt wenige Minuten. Eine
 * Emulator-Instanz braucht ~90 s bis zum Boot und danach eine gesunde
 * Grundlast, die man nicht pro Subthread neu bezahlen will. Der Daemon hält die
 * Instanzen warm, und die Subthreads mieten sie nur für die Dauer ihres
 * Laufs. Das ist der Unterschied zwischen „jeder Agent startet sein eigenes
 * Gerät" ( 分钟langes Warten pro Agent, Ressourcenexplosion) und „die Farm
 * ist da, der Agent hat in zwei Sekunden eine freie Maschine".
 *
 * Der Anspruch auf eine Instanz läuft über `flock` (siehe `lib/core.mjs`), nicht
 * über ein Flag in einer JSON-Datei: die Sperre gehört dem Kernel, übersteht
 * keinen halben Schreibvorgang und wird beim Tod des Prozesses von selbst
 * freigegeben. Ein Flag bräuchte eine Aufräumroutine, die genau dann fehlt,
 * wenn ein Agent abstürzt.
 */
import { setTimeout as sleep } from 'node:timers/promises';
import { existsSync, writeFileSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import {
  Lease, ensureDir, hash, listDevices, loadConfig, readJson, stamp, writeJson,
} from './lib/core.mjs';
import { ensureAvd, serialFor, startInstance, stopInstance } from './lib/emulator.mjs';

const cfg = loadConfig();
const registryFile = join(cfg.stateDir, 'instances.json');
const pidFile = join(cfg.stateDir, 'farmd.pid');

const log = (text) => console.log(`[farmd ${stamp((Date.now() - startedAt) / 1000)}] ${text}`);
let startedAt = Date.now();

function parseFlags(argv) {
  const flags = {};
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i].startsWith('--')) {
      const key = argv[i].slice(2);
      const next = argv[i + 1];
      if (next && !next.startsWith('--')) {
        flags[key] = next;
        i += 1;
      } else {
        flags[key] = true;
      }
    }
  }
  return flags;
}

/** Der Zustand jeder Instanz, aus dem Sicht der Farm. */
function buildRegistry(count) {
  const devices = new Map(listDevices(cfg).map((d) => [d.serial, d.state]));
  const instances = [];
  for (let i = 0; i < count; i += 1) {
    const port = cfg.basePort + i * 2;
    const serial = serialFor(port);
    instances.push({
      index: i,
      port,
      serial,
      state: devices.get(serial) === 'device' ? 'ready' : 'down',
      lease: join(cfg.stateDir, `lease-${port}.lock`),
    });
  }
  return { instances, updatedAt: Date.now() };
}

function publish() {
  const registry = readJson(registryFile, { instances: [] });
  writeJson(registryFile, { ...registry, updatedAt: Date.now(), pid: process.pid });
}

/**
 * Belegt die erste freie Instanz und übergibt ihren `flock`-Pfad.
 *
 * Der Aufrufer hält den `Lease` offen, solange er die Maschine benutzt. Weil
 * `flock` an einem offenen Dateideskriptor hängt, überlebt die Sperre sogar
 * einen `exec` durch einen Kindprozess hindurch.
 */
export function claimInstance(index = null, { owner = 'agent', timeoutMs = 0 } = {}) {
  ensureDir(cfg.stateDir);
  const registry = readJson(registryFile, { instances: [] });
  const candidates = index === null
    ? registry.instances
    : registry.instances.filter((i) => i.index === index);
  for (const instance of candidates) {
    if (instance.state !== 'ready') continue;
    const lease = new Lease(instance.lease, {
      timeoutMs,
      onWait: () => log(`warte auf Instanz ${instance.index} (${instance.serial})`),
    });
    try {
      lease.acquire(`${owner}@${process.pid}`);
      return { ...instance, lease };
    } catch {
      /* belegt, weiter */
    }
  }
  throw new Error(`keine freie Instanz (${candidates.length} bekannt, alle belegt oder aus)`);
}

async function start(count) {
  ensureDir(cfg.stateDir);
  ensureDir(cfg.outDir);

  if (!existsSync(cfg.adb)) throw new Error(`adb fehlt: ${cfg.adb}`);
  if (!existsSync(cfg.emulator)) throw new Error(`Emulator fehlt: ${cfg.emulator} — sdkmanager "emulator"`);
  if (!existsSync(cfg.avdmanager)) throw new Error(`avdmanager fehlt: ${cfg.avdmanager}`);

  const created = ensureAvd(cfg);
  log(created ? `AVD ${cfg.avd} angelegt` : `AVD ${cfg.avd} vorhanden`);

  writeJson(registryFile, { instances: buildRegistry(count), createdAt: Date.now() });
  writeFileSync(pidFile, String(process.pid), 'utf8');

  // Seriell statt parallel: zwei Emulator, die gleichzeitig denselben AVD
  // aufziehen, konkurrieren um dieselben qcow-Images. Der Start ist der
  // einzige wirklich gefährliche Moment.
  for (let i = 0; i < count; i += 1) {
    const port = cfg.basePort + i * 2;
    process.stdout.write(`  Instanz ${i} (${serialFor(port)}) … `);
    const started = await startInstance(cfg, i);
    log(started.reused ? 'war schon da' : 'bootfertig');
  }

  writeJson(registryFile, { instances: buildRegistry(count), createdAt: Date.now() });
  publish();
  log(`${count} Instanzen bereit. Auf `);
  supervise(count);
}

/**
 * Hält die Instanzen am Leben.
 *
 * Ohne das stirbt ein Emulator, dem der Speicher ausgeht, und der Agent, der
 * ihn gerade gemietet hat, bekommt einen Fehlschlag, den er nicht erklären
 * kann. Ein Neustart ist hier billiger als eine Fehldiagnose.
 */
function supervise(count) {
  const timer = setInterval(async () => {
    try {
      const registry = readJson(registryFile, { instances: [] });
      let changed = false;
      for (const instance of registry.instances) {
        const alive = listDevices(cfg).some((d) => d.serial === instance.serial && d.state === 'device');
        if (alive) continue;
        // Nur neu starten, wenn niemand die Lease hält — sonst arbeitet ein
        // Agent gerade darauf und bekäme die Maschine unter den Füßen weg.
        const free = new Lease(instance.lease, { timeoutMs: 1 });
        try {
          free.acquire('supervisor');
          free.release();
        } catch {
          continue;
        }
        log(`Instanz ${instance.index} (${instance.serial}) ist weg, starte neu …`);
        await startInstance(cfg, instance.index);
        changed = true;
      }
      if (changed) writeJson(registryFile, { instances: buildRegistry(count), createdAt: Date.now() });
      publish();
    } catch (err) {
      log(`Supervisor: ${err.message}`);
    }
  }, 15_000);
  timer.unref?.();
  process.on('SIGTERM', () => {
    clearInterval(timer);
    process.exit(0);
  });
}

function status() {
  const registry = readJson(registryFile, null);
  if (!registry) {
    console.log('Farm läuft nicht (keine instances.json). Start: node tools/devfarm/farmd.mjs start');
    return;
  }
  const pid = existsSync(pidFile) ? readFileSync(pidFile, 'utf8').trim() : '?';
  let alive = false;
  try {
    process.kill(Number(pid), 0);
    alive = true;
  } catch {
    alive = false;
  }
  console.log(`farmd pid ${pid} — ${alive ? 'läuft' : 'läuft NICHT'}`);
  console.log(`Konfiguration: ${cfg.instances} Instanzen ab Port ${cfg.basePort}, GPU ${cfg.gpu}\n`);
  const devices = new Map(listDevices(cfg).map((d) => [d.serial, d.state]));
  for (const instance of registry.instances) {
    const state = devices.get(instance.serial) ?? 'down';
    const free = new Lease(instance.lease, { timeoutMs: 1 });
    let held = 'frei';
    try {
      free.acquire('status');
      free.release();
    } catch {
      held = 'BELegt';
    }
    console.log(`  [${instance.index}] ${instance.serial.padEnd(16)} ${state.padEnd(9)} ${held}`);
  }
}

function stop() {
  const registry = readJson(registryFile, { instances: [] });
  for (const instance of registry.instances) {
    log(`stoppe ${instance.serial}`);
    stopInstance(cfg, instance.index);
  }
  for (const file of [pidFile]) {
    if (existsSync(file)) unlinkSync(file);
  }
  writeJson(registryFile, { instances: buildRegistry(0), stoppedAt: Date.now() });
  log('gestoppt');
}

const flags = parseFlags(process.argv.slice(2));
const command = process.argv[2] ?? 'status';
const count = Number(flags.instances ?? cfg.instances);

if (command === 'start') {
  await start(count);
  // Der Daemon soll weiterlaufen; opencode soll nicht auf ihn warten.
  await new Promise(() => {});
} else if (command === 'status') {
  status();
} else if (command === 'stop') {
  stop();
} else {
  console.error(`Aufruf: farmd.mjs start|status|stop  (--instances N)`);
  process.exit(2);
}
