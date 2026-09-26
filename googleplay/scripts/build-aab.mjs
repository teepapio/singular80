/**
 * Builds the signed Android App Bundle that Google Play accepts.
 *
 *   PLAY_KEYSTORE_PATH=… PLAY_KEYSTORE_USER=… PLAY_KEYSTORE_PASSWORD=… \
 *     npm run build
 *
 * Steps, in the order the tools require them:
 *   1. content:sync   — content/*.json must be mirrored into the Godot project
 *                       (the repo's own test would fail otherwise)
 *   2. godot:import   — import the mirrored assets
 *   3. android-template + prepare-toolchain — the template ships with
 *                       compileSdk 35 and is rewritten by every install
 *   4. install-export-preset — put the AAB preset in export_presets.cfg
 *   5. godot --export-release  → build/singular80-play.aab
 *   6. verify-aab      → check targetSdk, versionCode, permissions, signature
 *
 * Everything but the keystore is deterministic; the build can be repeated.
 */
import { existsSync, statSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  config, REPO, BUILD_DIR, ensureDir, PRESET_NAME,
  ok, info, warn, fail, step, done, abort, run, tryRun,
} from './lib.mjs';

const cfg = config();
const ks = cfg.android.keystoreEnv;
const path = process.env[ks.pathEnv];
const user = process.env[ks.userEnv];
const password = process.env[ks.passwordEnv];

step('1/6 Content spiegeln');
const sync = tryRun('node', ['scripts/sync-content.mjs'], { cwd: REPO });
if (sync.code !== 0) abort('content:sync fehlgeschlagen.');
ok('content/*.json → godot/assets/content/');

step('2/6 Godot-Import');
const imp = tryRun('godot', ['--headless', '--path', 'godot', '--import'], { cwd: REPO, timeout: 900_000 });
if (imp.code !== 0) {
  warn('Import meldete einen Fehler (oft harmlos: .godot/ wird geschrieben).');
  info(imp.out.split('\n').filter((l) => /ERROR|SCRIPT ERROR/i.test(l)).slice(0, 5).join('\n') || '—');
}
ok('Import durch.');

step('3/6 Android-Template + API-Level');
if (tryRun('node', ['scripts/install-android-template.mjs'], { cwd: REPO }).code !== 0) {
  abort('Android-Build-Template fehlt. Siehe Meldung oben.');
}
if (tryRun('node', ['googleplay/scripts/prepare-toolchain.mjs'], { cwd: REPO }).code !== 0) {
  abort('Toolchain-Vorbereitung fehlgeschlagen (siehe oben).');
}

step('4/6 Export-Preset');
// With credentials: Godot only reads the keystore from the preset file.
if (tryRun('node', ['googleplay/scripts/install-export-preset.mjs'], { cwd: REPO }).code !== 0) {
  abort('Preset-Installation fehlgeschlagen.');
}

step('5/6 Release-AAB bauen');
if (!path || !user || !password) {
  fail(`${ks.pathEnv}, ${ks.userEnv} und ${ks.passwordEnv} müssen gesetzt sein.`);
  info('Keystore anlegen:  npm run keystore');
  abort('Abbruch — es wurde kein Build gestartet.');
}
if (!existsSync(path)) {
  fail(`Keystore ${path} existiert nicht.`);
  abort('Abbruch.');
}

ensureDir(BUILD_DIR);
const aab = join(BUILD_DIR, 'singular80-play.aab');

// Strip the keystore password out of the preset again — before *and* after the
// export, so an aborted build never leaves it behind in the working tree.
function scrubPreset() {
  const clean = { ...process.env };
  delete clean[ks.pathEnv];
  delete clean[ks.userEnv];
  delete clean[ks.passwordEnv];
  const res = tryRun('node', ['googleplay/scripts/install-export-preset.mjs'], { cwd: REPO, env: clean });
  if (res.code !== 0) warn('Preset konnte nicht bereinigt werden — Passwort von Hand aus godot/export_presets.cfg löschen!');
  else ok('Preset bereinigt (kein Passwort in export_presets.cfg).');
}
process.on('exit', () => {
  const preset = join(REPO, 'godot', 'export_presets.cfg');
  try {
    const text = readFileSync(preset, 'utf8');
    if (text.includes(`keystore/release_password="${password}"`)) scrubPreset();
  } catch {
    /* nothing to clean up */
  }
});

const out = tryRun(
  'godot',
  ['--headless', '--path', 'godot', '--export-release', PRESET_NAME, aab],
  { cwd: REPO, env: { ...process.env }, timeout: 3_600_000 },
);
scrubPreset();
if (out.code !== 0) {
  console.log(out.out.split('\n').slice(-40).join('\n'));
  abort('Godot-Export fehlgeschlagen.');
}
if (!existsSync(aab)) abort(`Godot meldet Erfolg, aber ${aab} fehlt.`);

const mb = (statSync(aab).size / 1024 / 1024).toFixed(1);
ok(`AAB: ${aab} (${mb} MB)`);

if (Number(mb) > 190) {
  warn('Über 190 MB — die Basiskomponente eines AAB ist bei Google auf 200 MB Downloadgrenze.');
  info('Grenze überschreiten: die beiden reicheren LOD-Stufen entfernen (ca. 45 MB)');
  info('oder Play Asset Delivery benutzen (config/app.json → android.exportFormat).');
}

step('6/6 AAB prüfen');
const verify = tryRun('node', ['googleplay/scripts/verify-aab.mjs'], { cwd: REPO });
process.stdout.write(verify.out);
if (verify.code !== 0) abort('AAB-Verifikation fehlgeschlagen — bitte Meldungen beheben.');

done(`Release-Kandidat: ${aab}`);
