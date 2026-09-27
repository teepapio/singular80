/**
 * `npm run backup` — the dashboard's memory, as a file in the repository.
 *
 *   npm run backup            status: was steht in der Datei, was fehlt hier?
 *   npm run backup -- write   Momentaufnahme schreiben (das gehört dann ins Git)
 *   npm run backup -- read    Datei einlesen und mit der Datenbank zusammenführen
 *
 * The dashboard has buttons for all three; this script exists for the moments the
 * dashboard is not open — a cron job, a fresh clone, or a machine whose database
 * is gone and whose repository is not.
 */
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Store } from '../server/db';
import {
  backupPath,
  backupStatus,
  buildSnapshot,
  describeBackup,
  mergeSnapshot,
  readSnapshotFile,
  writeSnapshotFile,
} from '../server/backup';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const command = (process.argv[2] ?? 'status').toLowerCase();
const store = new Store(process.env.DATA_DIR ?? join(root, 'data'));
const path = backupPath(root);

function line(text: string): void {
  console.log(text);
}

if (command === 'write') {
  const snapshot = buildSnapshot(store, root);
  writeSnapshotFile(path, snapshot);
  const c = snapshot.counts;
  line(`Backup geschrieben: ${backupStatus(store, root).path}`);
  line(`  ${c.suggestions} Vorschläge, ${c.runs} Runs, ${c.votes} Stimmen (von ${snapshot.machine})`);
  line('  Jetzt committen: git add ' + backupStatus(store, root).path + ' && git commit -m "chore(backup): Dashboard-Historie"');
} else if (command === 'read') {
  let snapshot;
  try {
    snapshot = readSnapshotFile(path);
  } catch (err) {
    line(`FEHLER: ${(err as Error).message}`);
    process.exit(1);
  }
  if (!snapshot) {
    line(`Keine Backup-Datei unter ${path}.`);
    process.exit(1);
  }
  const report = mergeSnapshot(store, snapshot, { projectRoot: root });
  line(`Backup gelesen (${snapshot.machine}, ${new Date(snapshot.writtenAt).toLocaleString('de-DE')}):`);
  line(`  ${report.suggestionsAdded} Vorschläge neu, ${report.suggestionsUpdated} aktualisiert`);
  line(`  ${report.votesAdded} Stimmen, ${report.runsAdded} Runs neu, ${report.runsCompleted} Runs mit Ergebnis nachgetragen`);
  line(describeBackup(backupStatus(store, root)));
} else if (command === 'status') {
  const status = backupStatus(store, root);
  line(`${status.path} — ${status.exists ? 'vorhanden' : 'noch nicht angelegt'}`);
  line(describeBackup(status));
  if (status.exists && (status.missingHere > 0 || status.differing > 0)) {
    line('Mit `npm run backup -- read` nachladen.');
  }
} else {
  line(`Unbekanntes Kommando "${command}". Erlaubt: status, write, read.`);
  process.exit(1);
}
