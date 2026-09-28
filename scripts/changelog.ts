import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { appendSessionEntry } from '../server/changelog';

/**
 * `npm run changelog -- "was sich geändert hat"` — one line in `CHANGELOG.md`
 * for a change that did **not** come from a suggestion.
 *
 * Why this exists as a command: the runner writes the entries for implemented
 * suggestions, because only it knows a run succeeded. But plenty of work never
 * touches a suggestion — the owner reports a bug in a normal session, an agent
 * fixes it. Without a way to add that line, the changelog would show a history
 * that is only half of what happened, and the missing half is exactly the part
 * the owner asked about.
 *
 * The entry is prefixed `edi:` (see `sessionEntryLine`) so it is visibly not a
 * suggestion number.
 */

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const text = process.argv.slice(2).join(' ').trim();

if (text.length < 3) {
  console.error('Gebrauch: npm run changelog -- "was sich für den Spieler geändert hat"');
  process.exit(1);
}

const ok = appendSessionEntry(root, text);
if (!ok) {
  console.error('Changelog-Eintrag fehlgeschlagen — der Commit ist evtl. trotzdem da, prüfe `git log -1`.');
  process.exit(1);
}
console.log(`Changelog aktualisiert: edi: ${text}`);
