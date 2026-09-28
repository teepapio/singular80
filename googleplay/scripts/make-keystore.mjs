/**
 * Creates the *upload* keystore for Google Play.
 *
 * Play App Signing is mandatory: the key you upload with is only an "upload
 * key" and Google re-signs the app with its own app-signing key. Losing the
 * upload key means asking Google to reset it, which takes days — so it is
 * created *outside* the repository, next to the Android debug keystore, and the
 * passwords are asked for interactively.
 *
 *   npm run keystore            → creates ~/.android/play-upload.keystore
 *   npm run keystore -- --path /secure/place/upload.keystore
 *
 * Afterwards export the three values and keep them in a password manager:
 *   export PLAY_KEYSTORE_PATH=~/.android/play-upload.keystore
 *   export PLAY_KEYSTORE_USER=singular80-upload
 *   export PLAY_KEYSTORE_PASSWORD=…
 */
import { existsSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { homedir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { config, which, ok, info, warn, fail, step, done, abort, listTodos } from './lib.mjs';

const cfg = config();
const args = process.argv.slice(2);
const pathFlag = args.indexOf('--path');
const target = resolve(
  pathFlag !== -1 ? args[pathFlag + 1] : join(homedir(), '.android', 'play-upload.keystore'),
);
const user = process.env.PLAY_KEYSTORE_USER || 'singular80-upload';
const password = process.env.PLAY_KEYSTORE_PASSWORD;

step('Upload-Keystore');

if (!which('keytool')) {
  abort('keytool fehlt — JDK 17 installieren (openjdk-17-jdk).');
}

if (existsSync(target)) {
  warn(`${target} existiert bereits.`);
  info('Nichts überschrieben: derselbe Schlüssel muss für alle Uploads weiterleben.');
  info('Neu erzeugen nur, wenn du Google bitten willst, den Upload-Key zu resetten.');
  done('Keystore unverändert.');
}

// Godot 4.5+ requires PKCS#8 for release/upload keystores; -storetype PKCS12
// is what keytool produces by default and what Godot's exporter documents.
info('Passwort wird interaktiv abgefragt (nicht als Argument — sonst landet es in der Shell-History).');
info('  • mindestens 6 Zeichen');
info('  • später sicher aufbewahren: ohne diesen Key sind keine Updates mehr möglich');

const argsKt = [
  '-genkeypair',
  '-keystore', target,
  '-storetype', 'PKCS12',
  '-alias', 'singular80-upload',
  '-keyalg', 'RSA',
  '-keysize', '4096',
  '-sigalg', 'SHA256withRSA',
  '-validity', '10000',
  '-dname', 'CN=Singular 80, OU=Google Play Upload, O=singular80, L=-, ST=-, C=DE',
];

mkdirSync(dirname(target), { recursive: true });

if (password) {
  // Non-interactive path, for CI or a password manager integration.
  const res = spawnSync('keytool', [...argsKt, '-storepass', password, '-keypass', password], { stdio: 'inherit' });
  if (res.status !== 0) abort('keytool ist fehlgeschlagen.');
} else {
  const res = spawnSync('keytool', argsKt, { stdio: 'inherit' });
  if (res.status !== 0) abort('keytool ist fehlgeschlagen.');
}

ok(`Keystore: ${target}`);
ok(`Alias:    ${user}`);
info(`Fingerprint (in Play Console unter "App credentials" sichtbar):`);
spawnSync('keytool', ['-list', '-v', '-keystore', target, '-alias', 'singular80-upload'], { stdio: 'inherit' });

const missing = listTodos();
if (missing.length) {
  warn(`${missing.length} Platzhalter stehen noch in config/app.json (siehe docs/PLAN.md).`);
}

done('Nächster Schritt: PLAY_KEYSTORE_* exportieren, dann `npm run build`.');
