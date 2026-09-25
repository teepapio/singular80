import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createApp } from '../server/app';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const dataDir = mkdtempSync(join(tmpdir(), 'singular80-smoke-'));
const app = createApp({
  dataDir,
  contentDir: join(root, 'content'),
  projectRoot: root,
  distDir: join(root, 'dist'),
  runnerEnabled: false,
});

let failures = 0;
function check(name: string, condition: boolean, detail = ''): void {
  if (condition) {
    console.log(`  ✅ ${name}`);
  } else {
    failures += 1;
    console.error(`  ❌ ${name}${detail ? ` — ${detail}` : ''}`);
  }
}

async function call<T>(base: string, path: string, init?: RequestInit): Promise<{ status: number; body: T }> {
  const res = await fetch(`${base}${path}`, {
    headers: { 'Content-Type': 'application/json' },
    ...init,
  });
  const body = (await res.json().catch(() => null)) as T;
  return { status: res.status, body };
}

async function main(): Promise<void> {
  await app.listen({ port: 0, host: '127.0.0.1' });
  const address = app.server.address();
  const port = typeof address === 'object' && address ? address.port : 0;
  const base = `http://127.0.0.1:${port}`;
  console.log(`\nSmoke-Test gegen ${base}\n`);

  const health = await call<{ ok: boolean }>(base, '/api/health');
  check('Health-Endpoint', health.status === 200 && health.body.ok === true);

  const content = await call<{ enemies: unknown[]; weapons: unknown[]; upgrades: unknown[] }>(base, '/api/content');
  check(
    'Content wird geladen',
    content.status === 200 && content.body.enemies.length > 0 && content.body.weapons.length > 0 && content.body.upgrades.length > 0,
  );

  const first = await call<{ id: number; category: string; clusterSize: number }>(base, '/api/suggestions', {
    method: 'POST',
    body: JSON.stringify({ text: 'Füge einen Slime Gegner hinzu, der in kleine Slimes zerfällt', author: 'Smoke' }),
  });
  check('Vorschlag anlegen', first.status === 200 && first.body.id > 0);
  check('Kategorie automatisch erkannt', first.body.category === 'content', `war ${first.body.category}`);

  const similar = await call<{ id: number; canonicalId: number | null; clusterSize: number }>(base, '/api/suggestions', {
    method: 'POST',
    body: JSON.stringify({ text: 'Neuer Gegner: Slime der sich teilt', author: 'Smoke' }),
  });
  check('Duplikat wird geclustert', similar.body.canonicalId === first.body.id, `canonicalId=${similar.body.canonicalId}`);
  check('Cluster-Größe wird berechnet', similar.body.clusterSize === 2, `clusterSize=${similar.body.clusterSize}`);

  const unrelated = await call<{ canonicalId: number | null }>(base, '/api/suggestions', {
    method: 'POST',
    body: JSON.stringify({ text: 'Bitte die Musik im Menü leiser machen', author: 'Smoke' }),
  });
  check('Unähnlicher Vorschlag wird nicht geclustert', unrelated.body.canonicalId === null);

  const bad = await call<{ error: string }>(base, '/api/suggestions', {
    method: 'POST',
    body: JSON.stringify({ text: 'x' }),
  });
  check('Zu kurzer Vorschlag wird abgelehnt', bad.status === 400);

  const vote1 = await call<{ votes: number }>(base, `/api/suggestions/${first.body.id}/vote`, {
    method: 'POST',
    body: JSON.stringify({ voterId: 'smoke-voter-1' }),
  });
  const vote2 = await call<{ votes: number }>(base, `/api/suggestions/${first.body.id}/vote`, {
    method: 'POST',
    body: JSON.stringify({ voterId: 'smoke-voter-1' }),
  });
  check('Stimme zählt', vote1.body.votes === 1);
  check('Doppelte Stimme zählt nicht', vote2.body.votes === 1);

  const approved = await call<{ status: string }>(base, `/api/suggestions/${first.body.id}`, {
    method: 'PATCH',
    body: JSON.stringify({ status: 'approved' }),
  });
  check('Status ändern', approved.body.status === 'approved');

  const list = await call<{ suggestions: { score: number; id: number; breakdown: { votes: number } }[]; stats: { total: number } }>(
    base,
    '/api/suggestions',
  );
  check('Liste enthält alle Vorschläge', list.body.suggestions.length === 3 && list.body.stats.total === 3);
  const scores = list.body.suggestions.map((s) => s.score);
  check(
    'Liste ist nach Score sortiert',
    scores.every((score, index) => index === 0 || scores[index - 1] >= score),
    scores.join(', '),
  );

  const settings = await call<{ webhookConfigured: boolean }>(base, '/api/settings', {
    method: 'PUT',
    body: JSON.stringify({ discordWebhook: 'https://discord.com/api/webhooks/123456/testtoken' }),
  });
  check('Webhook-Einstellung speichern', settings.body.webhookConfigured === true);

  const missing = await call<{ error: string }>(base, '/api/suggestions/999999');
  check('404 für unbekannten Vorschlag', missing.status === 404);

  console.log(failures === 0 ? '\nAlle Smoke-Tests bestanden.\n' : `\n${failures} Test(s) fehlgeschlagen.\n`);
  await app.close();
  rmSync(dataDir, { recursive: true, force: true });
  process.exit(failures === 0 ? 0 : 1);
}

main().catch(async (err) => {
  console.error('Smoke-Test abgebrochen:', err);
  await app.close().catch(() => undefined);
  rmSync(dataDir, { recursive: true, force: true });
  process.exit(1);
});
