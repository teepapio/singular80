#!/usr/bin/env node
/**
 * Die Farm-Schleife: die App meldet sich hier, Agenten steuern von hier aus.
 *
 *   node tools/devfarm/bridge.mjs            Start (Port aus config.json)
 *   node tools/devfarm/bridge.mjs status
 *
 * Warum ein langlebiger Prozess und kein Socket pro Test: die App soll sich
 * einmal melden und dann Kommandos **abholen** (Long-Poll). So braucht die Farm
 * keinen offenen Port in die App, und eine Session überlebt einen Neustart des
 * Testtreibers, ohne dass die App neu startet.
 *
 * Das Protokoll ist absichtlich winzig und textbasiert, damit ein Subagent es
 * notfalls mit `curl` bedienen kann, wenn er keinen Node hat:
 *
 *   POST /register            → {"id":"…"}
 *   GET  /next?id=…           → {"op":"audit","args":{}}   (wartet sonst)
 *   POST /event               → {"id":…,"type":"audit","data":{…}}
 *   POST /command             → {"id":…,"op":"goto","args":{"screen":"tetris"}}
 *   GET  /events?id=…         → {"events":[…]}              (ab `since`)
 *   GET  /health              → {"apps":…,"queued":…}
 */
import { createServer } from 'node:http';
import { loadConfig, hash, readJson, writeJson } from './lib/core.mjs';

const cfg = loadConfig();
const PORT = Number(process.env.DEVFARM_BRIDGE ?? cfg.bridgePort);

/** appId → { device, registeredAt, queue: [], events: [], lastSeen } */
const apps = new Map();
/** Wie lange ein `/next` maximal hängt. Etwas kürzer als der client-seitige
 *  Poll-Timeout, damit der Client nie an einer offenen Anfrage klebt. */
const HOLD_MS = 25_000;

const log = (...parts) => console.log(`[bridge ${new Date().toISOString().slice(11, 19)}]`, ...parts);

function json(res, code, body) {
  const text = JSON.stringify(body);
  res.writeHead(code, {
    'content-type': 'application/json',
    'access-control-allow-origin': '*',
    'access-control-allow-headers': 'content-type',
    'access-control-allow-methods': 'GET,POST,OPTIONS',
  });
  res.end(text);
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (chunk) => {
      data += chunk;
      // Eine Meldung ist winzig; alles Größere ist ein Fehlversuch und soll
      // den Speicher nicht auffüllen.
      if (data.length > 4_000_000) req.destroy();
    });
    req.on('end', () => {
      try {
        resolve(data ? JSON.parse(data) : {});
      } catch {
        resolve({});
      }
    });
  });
}

/** Merkt sich Ereignisse, damit Agenten sie nachlesen können. */
function pushEvent(id, type, data) {
  const app = apps.get(id);
  if (!app) return;
  app.events.push({ at: Date.now(), type, data });
  // Unbegrenzt wachsen zu lassen ist der Klassiker: ein langer Testlauf
  // erzeugt zehntausend Zeilen und der Speicher des Testwerkzeugs wird zum
  // Problem des Testwerkzeugs.
  if (app.events.length > 5000) app.events.splice(0, app.events.length - 5000);
  log(`event ${type} von ${id.slice(0, 8)}`);
}

/** Wer wartet gerade auf ein Kommando? */
const waiters = new Map();

function drain(app) {
  const waiter = waiters.get(app.id);
  if (!waiter) return;
  if (app.queue.length === 0) return;
  waiters.delete(app.id);
  clearTimeout(waiter.timer);
  const command = app.queue.shift();
  json(waiter.res, 200, command);
}

const server = createServer(async (req, res) => {
  if (req.method === 'OPTIONS') return json(res, 204, {});

  try {
    if (req.url === '/health' || req.url === '/status') {
      return json(res, 200, {
        ok: true,
        apps: [...apps.values()].map((a) => ({
          id: a.id,
          device: a.device,
          lastSeen: a.lastSeen,
          queued: a.queue.length,
          events: a.events.length,
        })),
        uptimeSeconds: Math.round(process.uptime()),
      });
    }

    if (req.url === '/register' && req.method === 'POST') {
      const body = await readBody(req);
      const id = hash(`${body.device ?? '?'}:${body.model ?? '?'}:${Date.now()}`, 12);
      apps.set(id, {
        id,
        device: body.device ?? '?',
        model: body.model ?? '?',
        godot: body.godot ?? '?',
        screen: body.screen ?? null,
        registeredAt: Date.now(),
        lastSeen: Date.now(),
        queue: [],
        events: [],
      });
      log(`app ${id.slice(0, 8)} angemeldet (${body.device})`);
      return json(res, 200, { id, poll: 20 });
    }

    if (req.url?.startsWith('/next') && req.method === 'GET') {
      const id = new URL(req.url, 'http://x').searchParams.get('id');
      const app = apps.get(id);
      if (!app) return json(res, 404, { error: 'unbekannte app' });
      app.lastSeen = Date.now();
      if (app.queue.length > 0) return json(res, 200, app.queue.shift());
      // Lange warten, statt im Sekundentakt zu fragen: der Emulator ist der
      // teuerste Teil im Spiel, nicht der HTTP-Server.
      const timer = setTimeout(() => {
        waiters.delete(id);
        json(res, 200, {});
      }, HOLD_MS);
      waiters.set(id, { res, timer });
      return undefined;
    }

    if (req.url === '/event' && req.method === 'POST') {
      const body = await readBody(req);
      const app = apps.get(body.id);
      if (app) {
        app.lastSeen = Date.now();
        if (body.type === 'screen' && body.data?.current) app.currentScreen = body.data.current;
        pushEvent(body.id, String(body.type ?? '?'), body.data ?? {});
      }
      return json(res, 200, { ok: true });
    }

    if (req.url === '/command' && req.method === 'POST') {
      const body = await readBody(req);
      let targets = [...apps.values()];
      if (body.id) targets = targets.filter((a) => a.id === body.id);
      if (body.device) targets = targets.filter((a) => a.device.includes(String(body.device)));
      if (targets.length === 0) return json(res, 404, { error: 'keine passende app' });
      for (const app of targets) {
        app.queue.push({ op: String(body.op), args: body.args ?? {} });
        drain(app);
      }
      return json(res, 200, { ok: true, delivered: targets.map((a) => a.id) });
    }

    if (req.url?.startsWith('/events') && req.method === 'GET') {
      const url = new URL(req.url, 'http://x');
      const id = url.searchParams.get('id');
      const since = Number(url.searchParams.get('since') ?? 0);
      const type = url.searchParams.get('type');
      const app = id ? apps.get(id) : [...apps.values()][0];
      if (!app) return json(res, 404, { error: 'keine app' });
      let events = app.events.filter((e) => e.at > since);
      if (type) events = events.filter((e) => e.type === type);
      return json(res, 200, { id: app.id, events });
    }

    return json(res, 404, { error: 'unbekannter Endpunkt' });
  } catch (err) {
    return json(res, 500, { error: err.message });
  }
});

if (process.argv[2] === 'status') {
  console.log(JSON.stringify({ port: PORT, apps: apps.size }, null, 2));
} else {
  server.listen(PORT, '0.0.0.0', () => {
    log(`lausche auf 0.0.0.0:${PORT} — erreichbar aus dem Emulator als ${cfg.bridgeHost}:${PORT}`);
    writeJson(`${cfg.stateDir}/bridge.json`, { port: PORT, pid: process.pid, startedAt: Date.now() });
  });
  const shutdown = () => {
    log('beende');
    process.exit(0);
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}
