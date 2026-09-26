/**
 * Checks everything a Google Play release needs on this machine.
 *
 * Read-only: reports what is present, what is missing, and which Play rule the
 * missing piece is about. Run it before anything else.
 */
import { existsSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import {
  config, REPO, GODOT_DIR, PRESETS, PRESET_NAME, BUILD_DIR, ASSET_DIR,
  ok, info, warn, fail, step, done, which, godotVersion, androidSdkRoot, sdkmanager,
  tryRun, listTodos, isTodo,
} from './lib.mjs';

const cfg = config();
let problems = 0;
let notes = 0;

step('Werkzeugkette');
ok(`Node ${process.version}`);

const godot = godotVersion();
if (godot) {
  ok(`Godot ${godot}`);
  // Godot 4.7 ships a template that already targets API 36; 4.5 needs the patch.
  const majorMinor = godot.split('.')[1];
  info(
    Number(majorMinor) >= 7
      ? 'Godot ≥ 4.7 — die API-36-Anhebung sollte eigentlich überflüssig sein.'
      : `Godot ${majorMinor}.x — der Gradle-Template-Patch (npm run prepare) ist nötig.`,
  );
} else {
  fail('godot nicht im PATH');
  problems += 1;
}

const java = tryRun('java', ['-version']);
if (java.code === 0) {
  const line = java.out.split('\n')[0] ?? java.out;
  ok(line.trim());
  if (!/version "17|version "1\.8|version "21/.test(line)) {
    warn('Godot 4.5 verlangt Java 17 für den Gradle-Build.');
    notes += 1;
  }
} else {
  fail('java fehlt (JDK 17) — ohne Java kann kein AAB gebaut werden.');
  problems += 1;
}

if (which('keytool')) ok('keytool vorhanden (Keystore erzeugen/bestimätigen)');
else {
  fail('keytool fehlt — JDK 17 statt JRE installieren.');
  problems += 1;
}

if (which('jarsigner')) ok('jarsigner vorhanden (Signaturprüfung)');
else warn('jarsigner fehlt — AAB-Signatur wird nicht geprüft.');
if (which('unzip')) ok('unzip vorhanden');
else {
  fail('unzip fehlt (AAB-Strukturprüfung)');
  problems += 1;
}
if (which('convert')) ok('ImageMagick convert vorhanden (Grafiken erzeugen)');
else warn('ImageMagick fehlt — Icon/Feature Graphic müssen anders erzeugt werden.');

step('Android SDK');
const root = androidSdkRoot();
if (root) {
  ok(`SDK: ${root}`);
  if (sdkmanager()) ok('sdkmanager vorhanden');
  else {
    warn('sdkmanager fehlt — API 36 kann nicht nachinstalliert werden.');
    notes += 1;
  }
  for (const [label, dir] of [
    [`Plattform API ${cfg.android.targetSdk}`, join(root, 'platforms', cfg.android.platform)],
    [`Build-Tools ${cfg.android.buildTools}`, join(root, 'build-tools', cfg.android.buildTools)],
  ]) {
    if (existsSync(dir)) ok(label);
    else {
      fail(`${label} fehlt → npm run prepare`);
      problems += 1;
    }
  }
} else {
  fail('Kein Android SDK gefunden (ANDROID_HOME, ANDROID_SDK_ROOT oder ~/Android/Sdk).');
  problems += 1;
}

step('Godot-Android-Template');
const configGradle = join(GODOT_DIR, 'android', 'build', 'config.gradle');
if (!existsSync(configGradle)) {
  fail('godot/android/build fehlt → npm run prepare (ruft install-android-template.mjs auf)');
  problems += 1;
} else {
  const text = readFileSync(configGradle, 'utf8');
  const compile = Number(text.match(/compileSdk\s*:\s*(\d+)/)?.[1] ?? 0);
  const target = Number(text.match(/targetSdk\s*:\s*(\d+)/)?.[1] ?? 0);
  if (compile >= cfg.android.targetSdk) ok(`compileSdk ${compile}`);
  else {
    fail(`compileSdk ${compile} < ${cfg.android.targetSdk} → npm run prepare`);
    problems += 1;
  }
  if (target >= cfg.android.targetSdk) ok(`targetSdk ${target}`);
  else {
    fail(`targetSdk ${target} < ${cfg.android.targetSdk} → npm run prepare`);
    problems += 1;
  }
  if (/^\s*#/m.test(text)) {
    warn('config.gradle enthält noch "#"-Kommentare — harmlos für Groovy, aber unlesbar.');
    notes += 1;
  }
}

step('Export-Preset');
if (!existsSync(PRESETS)) {
  fail('godot/export_presets.cfg fehlt');
  problems += 1;
} else {
  const text = readFileSync(PRESETS, 'utf8');
  if (text.includes(`name="${PRESET_NAME}"`)) ok(`"${PRESET_NAME}" vorhanden`);
  else {
    fail('Play-Preset fehlt → npm run preset');
    problems += 1;
  }
  if (/keystore\/release_password=""/.test(text)) ok('Keystore-Passwort ist aus dem Preset entfernt');
  else {
    warn('keystore/release_password ist gesetzt — die Datei gehört nicht ins Git.');
    notes += 1;
  }
  if (/^\s*#/m.test(text)) {
    warn('export_presets.cfg hat "#"-Kommentarzeilen — Godots ConfigFile verschluckt dabei den nächsten Schlüssel.');
    notes += 1;
  }
}

step('Upload-Keystore');
const envPath = process.env[cfg.android.keystoreEnv.pathEnv];
if (envPath && existsSync(envPath)) ok(`${cfg.android.keystoreEnv.pathEnv}=${envPath}`);
else if (existsSync(join(process.env.HOME ?? '', '.android', 'play-upload.keystore'))) {
  warn('play-upload.keystore existiert, aber PLAY_KEYSTORE_PATH ist nicht gesetzt → export:');
  info('  export PLAY_KEYSTORE_PATH=~/.android/play-upload.keystore');
  info('  export PLAY_KEYSTORE_USER=singular80-upload');
  info('  export PLAY_KEYSTORE_PASSWORD=…');
  notes += 1;
} else {
  warn('Kein Upload-Keystore → npm run keystore (einmalig, Passwort sicher aufbewahren).');
  notes += 1;
}

step('Artefakte');
const aab = join(BUILD_DIR, 'singular80-play.aab');
if (existsSync(aab)) ok(`AAB ${(statSync(aab).size / 1024 / 1024).toFixed(1)} MB, gebaut ${new Date(statSync(aab).mtimeMs).toLocaleString('de-DE')}`);
else {
  info('Noch kein AAB gebaut → npm run build');
}
for (const [label, dir, pattern] of [
  ['Icon 512×512', ASSET_DIR, /^icon-512\.png$/],
  ['Feature Graphic 1024×500', ASSET_DIR, /^feature-graphic-1024x500\.png$/],
  ['Screenshots', join(BUILD_DIR, 'screenshots'), /^\d+_/],
]) {
  if (!existsSync(dir)) {
    info(`${label}: noch nichts vorhanden`);
    continue;
  }
  const { readdirSync } = await import('node:fs');
  const hits = readdirSync(dir).filter((f) => pattern.test(f));
  if (hits.length) ok(`${label}: ${hits.length} Datei(en)`);
  else info(`${label}: noch nichts vorhanden`);
}

step('Konfiguration');
const todos = listTodos();
if (todos.length === 0) ok('keine Platzhalter in config/app.json');
else {
  for (const { path } of todos) warn(`config/app.json → ${path}`);
  notes += todos.length;
}
for (const [name, url] of Object.entries(cfg.urls)) {
  if (isTodo(url)) continue;
  const scheme = /^https:\/\//.test(url) ? 'https' : /^http:\/\//.test(url) ? 'KLAU: http' : 'unknown';
  if (scheme === 'KLAU: http') {
    fail(`${name} ist http — Google erwartet für Datenschutz-Seiten eine erreichbare URL;`);
    problems += 1;
  }
}

done(
  problems
    ? `${problems} Problem(e), ${notes} Hinweis(e) — noch nicht abnahmebereit.`
    : notes
      ? `Werkzeugkette vollständig, ${notes} Hinweis(e) offen.`
      : 'Werkzeugkette vollständig und konfiguriert.',
);
