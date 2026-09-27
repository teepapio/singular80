import 'dotenv/config';
import { networkInterfaces } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createApp } from './app';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

const app = createApp({
  dataDir: process.env.DATA_DIR ?? join(root, 'data'),
  contentDir: process.env.CONTENT_DIR ?? join(root, 'content'),
  projectRoot: root,
  distDir: join(root, 'dist'),
});

const port = Number(process.env.PORT ?? 8787);
/**
 * Bind-Adresse. `0.0.0.0` ist Absicht und nicht Bequemlichkeit: ohne sie kommt
 * ein Vorschlag vom Handy oder Tablet nie an — `127.0.0.1` auf dem Server ist
 * auf dem Gerät ein anderer Rechner, und der Vorschlag bleibt in der
 * Warteschlange des Spiels. Für einen reinen Rechnerbetrieb genügt
 * `HOST=127.0.0.1`.
 *
 * Achtung: die API hat keine Anmeldung, und über denselben Port ist auch das
 * Dashboard erreichbar. In einem fremden oder öffentlichen Netz ist `0.0.0.0`
 * deshalb die falsche Wahl.
 */
const host = process.env.HOST?.trim() || '0.0.0.0';

app
  .listen({ port, host })
  .then(() => {
    console.log(`[singular80] API läuft auf http://localhost:${port} (gebunden an ${host})`);
    console.log('[singular80] Spiel + Dashboard im Dev-Modus: http://localhost:5173');
    if (host === '0.0.0.0') {
      // Die Adresse, die ein Gerät eintragen muss. Ohne diesen Hinweis bleibt
      // das Feld leer und der Spieler sieht nur "offline".
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
