import 'dotenv/config';
import { networkInterfaces } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createApp } from './app';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

/**
 * One worktree and one branch per run. Off unless `S80_ISOLATE_RUNS=1`, because
 * it changes where a finished run's commits are: they land on
 * `agent/suggestion-<id>`, and `npm run gate` merges them into `main`,
 * runs the suites there and pushes. Off means every run keeps working in the
 * shared tree with the scope lanes, exactly as before.
 */
const isolateRuns = process.env.S80_ISOLATE_RUNS === '1';
if (isolateRuns) {
  console.log('[singular80] Läufe arbeiten in eigenen Worktrees (S80_ISOLATE_RUNS=1) — zusammenführen mit: npm run gate');
}

const app = createApp({
  dataDir: process.env.DATA_DIR ?? join(root, 'data'),
  contentDir: process.env.CONTENT_DIR ?? join(root, 'content'),
  projectRoot: root,
  distDir: join(root, 'dist'),
  isolateRuns,
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
