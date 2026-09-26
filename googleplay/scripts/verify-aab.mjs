/**
 * Verifies the built AAB against the things Google Play actually rejects, so
 * the failure shows up here instead of as a "your app targets an old version of
 * Android" mail three days later.
 *
 * An AAB's base/manifest/AndroidManifest.xml is binary protobuf, so this script
 * asks the real tools instead of guessing:
 *   - `bundletool dump manifest`  → readable XML (bundled jar, see prepare-toolchain)
 *   - `jarsigner -verify`         → an AAB is signed like a JAR (v1 scheme)
 *   - `unzip -l`                 → structure and native ABIs
 *
 * Usage:  node scripts/verify-aab.mjs [path/to/file.aab]
 * Env:    PLAY_KEYSTORE_SHA256=<hex sha256 of the upload certificate, colons ok>
 */
import { existsSync, readFileSync, statSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import {
  config, BUILD_DIR, ensureDir, bundletool, BUNDLETOOL_VERSION, ANDROID_BUILD, GODOT_DIR,
  ok, info, warn, fail, step, done, abort, tryRun, listTodos,
} from './lib.mjs';

const cfg = config();
const aabPath = process.argv[2] ?? join(BUILD_DIR, 'singular80-play.aab');

let problems = 0;
const check = (cond, good, bad) => {
  if (cond) ok(good);
  else {
    fail(bad);
    problems += 1;
  }
  return cond;
};

step(`AAB prüfen: ${aabPath}`);
if (!existsSync(aabPath)) abort(`${aabPath} fehlt — erst \`npm run build\`.`);
info(`${(statSync(aabPath).size / 1024 / 1024).toFixed(1)} MB`);

// --- structure --------------------------------------------------------------
const listing = tryRun('unzip', ['-l', aabPath]);
if (listing.code !== 0) abort('Die Datei ist kein ZIP.');
const entries = listing.out
  .split('\n')
  .slice(1)
  .map((line) => line.trim().split(/\s+/).pop())
  .filter(Boolean);

check(entries.includes('BundleConfig.pb'), 'BundleConfig.pb → es ist ein AAB.', 'Kein BundleConfig.pb → das ist ein APK. Play nimmt für neue Apps nur AAB.');
check(entries.some((e) => e.startsWith('base/manifest/')), 'Basis-Modul vorhanden.', 'base/manifest/ fehlt.');
check(entries.some((e) => e.startsWith('base/lib/arm64-v8a/')), 'arm64-v8a-Libs im Basis-Modul.', 'Keine arm64-v8a-Libs.');
for (const [abi, on] of Object.entries(cfg.android.architectures)) {
  const present = entries.some((e) => e.startsWith(`base/lib/${abi}/`));
  if (on && !present) {
    fail(`${abi} ist aktiviert, aber nicht im Bundle.`);
    problems += 1;
  }
  if (!on && present) info(`${abi} liegt im Bundle, ist aber deaktiviert — Play würde die ABI nicht ausliefern.`);
}
if (!cfg.android.architectures['armeabi-v7a']) {
  info('Nur arm64: 32-Bit-Geräte (alte Android-7/8-Handys) können die App nicht installieren.');
}

// --- manifest ---------------------------------------------------------------
// Priority 1: bundletool reads the protobuf manifest out of the bundle. The jar
//   on dl.google.com is the *library* (no Main-Class); put the
//   `bundletool-all-<version>.jar` from the GitHub release into build/tools/ to
//   enable this path.
// Priority 2: the merged manifest Gradle wrote during this very build — plain
//   XML, same build, no extra dependency.
let manifest = '';
const jar = bundletool();
if (jar && existsSync(jar)) {
  const dump = tryRun('java', ['-jar', jar, 'dump', 'manifest', `--bundle=${aabPath}`, '--module=base']);
  if (dump.code === 0 && dump.out.includes('<manifest')) {
    manifest = dump.out;
    ok(`Manifest gelesen (bundletool ${BUNDLETOOL_VERSION}).`);
  } else {
    info('bundletool-Jar hat keine Main-Class (Bibliotheksvariante) — übersprungen.');
    info(`Volle Version nach build/tools/ legen: bundletool-all-${BUNDLETOOL_VERSION}.jar`);
  }
}

if (!manifest) {
  const merged = findMergedManifest();
  if (merged) {
    const age = (statSync(aabPath).mtimeMs - statSync(merged).mtimeMs) / 1000;
    // The merged manifest is a *build artefact of one export*. A different
    // build (e.g. the slim APK) leaves a newer one behind, and reading that
    // would check the wrong file — a green result for a manifest that was never
    // in this bundle. Only accept one from the same build: written shortly
    // before the bundle and not a minute after it.
    if (age < -30 || age > 120) {
      abort(
        `Kein Manifest aus diesem Build gefunden.\n` +
          `  Jüngstes: ${merged.replace(`${GODOT_DIR}/`, 'godot/')}\n` +
          `  (${age < 0 ? `${(-age).toFixed(0)} s nach` : `${age.toFixed(0)} s vor`} dem AAB — das ist ein anderer Build)\n` +
          '  Das Manifest im AAB ist binäres Protobuf und lässt sich nur mit\n' +
          '  bundletool lesen. Also: `npm run build` neu laufen lassen, oder die\n' +
          '  vollständige bundletool-all.jar nach googleplay/build/tools/ legen.',
      );
    }
    manifest = readFileSync(merged, 'utf8');
    ok(`Manifest gelesen (Gradle-Merge aus demselben Build): ${merged.replace(`${GODOT_DIR}/`, 'godot/')}`);
  } else {
    abort(
      'Kein Manifest gefunden — weder bundletool noch ein Gradle-Merge.\n' +
        '  `npm run build` erzeugt beides; ohne Manifest lässt sich targetSdk\n' +
        '  nicht prüfen, und genau daran lehnt Play neue Apps ab.',
    );
  }
}

if (manifest) {
  const str = (attr) => manifest.match(new RegExp(`${attr}="([^"]*)"`))?.[1] ?? null;
  const target = Number(str('android:targetSdkVersion'));
  const min = Number(str('android:minSdkVersion'));
  const versionCode = Number(str('android:versionCode'));
  const versionName = str('android:versionName');
  const pkg = str('package');
  const perms = [...new Set([...manifest.matchAll(/uses-permission android:name="([^"]+)"/g)].map((m) => m[1]))].sort();

  info(`targetSdk=${target} minSdk=${min} versionCode=${versionCode} versionName=${versionName}`);
  info(`package=${pkg}`);
  info(`permissions: ${perms.join(', ') || '—'}`);

  check(
    Number.isFinite(target) && target >= cfg.android.targetSdk,
    `targetSdkVersion ${target} erfüllt die Anforderung (≥ ${cfg.android.targetSdk}).`,
    `targetSdkVersion ist ${str('android:targetSdkVersion') ?? 'unbekannt'}; Google verlangt seit 31.08.2026 API ${cfg.android.targetSdk}. ` +
      'Fix: `npm run prepare` (hebt das Gradle-Template) bzw. Godot auf 4.7+ aktualisieren.',
  );
  check(
    Number.isFinite(min) && min === cfg.android.minSdk,
    `minSdkVersion ${min} wie konfiguriert.`,
    `minSdkVersion ${min} ≠ ${cfg.android.minSdk} in config/app.json.`,
  );
  check(pkg === cfg.app.packageName, `Paketname ${pkg} stimmt.`, `Paketname ${pkg} ≠ ${cfg.app.packageName}. Play identifiziert die App danach; ein späterer Wechsel ist nicht möglich.`);
  check(
    versionCode === cfg.version.versionCode,
    `versionCode ${versionCode} wie in config/app.json.`,
    `versionCode ${versionCode} ≠ ${cfg.version.versionCode} — Play lehnt Uploads ab, deren versionCode nicht höher ist als der veröffentlichste.`,
  );
  check(
    manifest.includes('android:isGame="true"') || manifest.includes('android:appCategory="game"'),
    'Manifest ist als Spiel deklariert.',
    'Manifest ist nicht als Spiel deklariert — dann verlangt Play Altersfreigabe 12+, was mit Poker nicht zusammenpasst.',
  );

  const FORBIDDEN = ['QUERY_ALL_PACKAGES', 'MANAGE_EXTERNAL_STORAGE', 'REQUEST_INSTALL_PACKAGES', 'AD_ID'];
  const found = perms.filter((p) => FORBIDDEN.some((f) => p.includes(f)));
  check(found.length === 0, 'Keine sensiblen Permissions.', `Unerwartete Permissions: ${found.join(', ')} — im "Declare permissions"-Formular begründen oder entfernen.`);
  check(perms.includes('android.permission.INTERNET'), 'INTERNET vorhanden.', 'INTERNET fehlt — Backend, Content und Vorschläge laufen nicht.');
  check(perms.includes('android.permission.VIBRATE'), 'VIBRATE vorhanden (App braucht es für Gamepad-Feedback).', 'VIBRATE fehlt — ggf. ungenutzt, aber deklariert lassen oder entfernen.');

  const appLabel = str('android:label');
  if (appLabel) info(`android:label=${appLabel}`);
} else {
  warn('Manifest nicht geprüft — targetSdk, Version und Permissions bitte manuell kontrollieren.');
}

// --- signature --------------------------------------------------------------
const jarsigner = tryRun('sh', ['-c', 'command -v jarsigner']);
if (jarsigner.code === 0) {
  const res = tryRun('jarsigner', ['-verify', '-certs', aabPath]);
  const verified = /jar verified/i.test(res.out);
  check(verified, 'Signatur gültig (jarsigner).', 'Signatur ungültig oder fehlend — Play lehnt unsignierte Bundles ab.');
  const sha = res.out.match(/SHA-256: ([0-9a-f:]{40,})/i)?.[1];
  if (sha) {
    info(`Zertifikat SHA-256: ${sha}`);
    const expected = process.env.PLAY_KEYSTORE_SHA256;
    if (expected) {
      const norm = (v) => v.replace(/[^0-9a-f]/gi, '').toUpperCase();
      check(
        norm(sha) === norm(expected),
        'Signatur passt zum erwarteten Upload-Key.',
        'Signatur passt NICHT zum erwarteten Upload-Key — falscher oder vertauschter Keystore.',
      );
    }
  }
} else {
  warn('jarsigner fehlt (JDK) — Signatur nicht geprüft.');
}

// --- placeholders -----------------------------------------------------------
const todos = listTodos();
if (todos.length) {
  warn(`${todos.length} Platzhalter in config/app.json — Rechtstexte und Store-Angaben sind noch nicht fertig:`);
  for (const { path } of todos) info(`  ${path}`);
}

if (problems > 0) abort(`${problems} Problem(e) gefunden.`);
done('AAB ist bereit für den Play-Upload.');

/**
 * Newest `bundle_manifest/**\/AndroidManifest.xml` below Gradle's build dir.
 * That is the manifest AGP turns into `base/manifest/AndroidManifest.xml`.
 */
function findMergedManifest() {
  const roots = [
    join(ANDROID_BUILD, 'intermediates', 'bundle_manifest'),
    join(ANDROID_BUILD, 'intermediates', 'merged_manifests'),
    join(ANDROID_BUILD, 'intermediates', 'merged_manifest'),
  ].filter((dir) => existsSync(dir));
  const found = [];
  const walk = (dir, depth) => {
    if (depth > 4) return;
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) walk(full, depth + 1);
      else if (entry.name === 'AndroidManifest.xml') found.push(full);
    }
  };
  for (const root of roots) walk(root, 0);
  if (found.length === 0) return null;
  return found.sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs)[0];
}
