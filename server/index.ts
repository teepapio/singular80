import 'dotenv/config';
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

app
  .listen({ port, host: '127.0.0.1' })
  .then(() => {
    console.log(`[singular80] API läuft auf http://localhost:${port}`);
    console.log('[singular80] Spiel + Dashboard im Dev-Modus: http://localhost:5173');
  })
  .catch((err) => {
    console.error('[singular80] Start fehlgeschlagen:', err);
    process.exit(1);
  });
