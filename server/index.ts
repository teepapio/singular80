import 'dotenv/config';
import { networkInterfaces } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createApp } from './app';
import { findTerminal } from './terminal';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

/**
 * Run each OpenCode session in a terminal window, so the owner can watch and
 * type into it instead of reading a frozen log pane in the dashboard.
 *
 * `S80_TERMINAL=0` turns it off without a code change — worth having, because a
 * session that cannot be supervised is worse than one that merely runs quietly.
 * A terminal that is present but unusable (no DISPLAY, because the dev server
 * hangs off `setsid`) is detected per run and falls back on its own.
 */
const terminal = findTerminal();
const terminalRuns = process.env.S80_TERMINAL !== '0' && terminal !== null;
if (process.env.S80_TERMINAL === '0') {
  console.log('[singular80] Terminal-Läufe abgeschaltet (S80_TERMINAL=0) — Ausgabe im Dashboard.');
} else if (terminalRuns) {
  console.log(`[singular80] Läufe öffnen ein Terminalfenster (${terminal.bin}).`);
}

const app = createApp({
  dataDir: process.env.DATA_DIR ?? join(root, 'data'),
  contentDir: process.env.CONTENT_DIR ?? join(root, 'content'),
  projectRoot: root,
  distDir: join(root, 'dist'),
  terminalRuns,
});

const port = Number(process.env.PORT ?? 8787);
/**
 * Bind address. `0.0.0.0` is deliberate, not convenient: without it a suggestion
 * from a phone or tablet never arrives — `127.0.0.1` on the server is a different
 * machine on the device, and the suggestion stays in the game's queue. For a
 * desktop-only setup `HOST=127.0.0.1` is enough.
 *
 * Note: the API has no login, and the dashboard is reachable on the same port.
 * In a foreign or public network `0.0.0.0` is the wrong choice.
 */
const host = process.env.HOST?.trim() || '0.0.0.0';

app
  .listen({ port, host })
  .then(() => {
    console.log(`[singular80] API läuft auf http://localhost:${port} (gebunden an ${host})`);
    console.log('[singular80] Spiel + Dashboard im Dev-Modus: http://localhost:5173');
    if (host === '0.0.0.0') {
      // The address a device has to enter. Without this hint the field stays
      // empty and the player just sees "offline".
      for (const [name, addrs] of Object.entries(networkInterfaces())) {
        for (const addr of addrs ?? []) {
          if (addr.family === 'IPv4' && !addr.internal) {
            console.log(`[singular80] Im Gerät eintragen: http://${addr.address}:${port}  (${name})`);
          }
        }
      }
    }
  })
  .catch((err) => {
    console.error('[singular80] Start fehlgeschlagen:', err);
    process.exit(1);
  });
