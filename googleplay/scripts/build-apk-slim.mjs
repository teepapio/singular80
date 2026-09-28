/**
 * Builds the **slim** APK: the full app without the `med/` and `high/` meshes.
 *
 *   npm run build:apk
 *
 * The two folders are only hidden from *one* export, never deleted: the mesh
 * tree is versioned, `AssetRegistry` and the test suites compare it against the
 * registry, and a parallel agent works in this very tree. The gallery then
 * offers the low-poly level only, which is what it already does when the LOD
 * generator has not run.
 *
 * Two traps, both measured on real artifacts:
 *   - `exclude_filter` *does* reach imported resources (0/155 med and high each
 *     way), but `.gdignore` is used here because it also survives a preset that
 *     a foreign agent regenerated without the pattern.
 *   - `export_filter="exclude"` is worse than useless: it ships the raw `.glb`
 *     sources, and an exported game cannot load a raw `.glb` — importing
 *     happens in the editor.
 *
 * "Export succeeded" is not proof. An APK that still weighs 120 MB means the
 * mechanism did not take effect, and that is the failure this script catches:
 * the package contents are compared against the md5 sums in the `.import` files
 * below, because a name-based check proves nothing (see `importedTargets`).
 */
import { existsSync, readFileSync, statSync, readdirSync, writeFileSync, rmSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import {
  config, REPO, BUILD_DIR, GODOT_DIR, PRESETS, ensureDir,
  ok, info, warn, fail, step, done, abort, tryRun, androidSdkRoot,
} from './lib.mjs';

const cfg = config();
const EXCLUDE_MARKER = 'assets/meshes/med/*';

/** The two directories that hold nothing but the generated detail levels. */
const MESH_DIR = join(GODOT_DIR, 'assets', 'meshes');
const LIFT_DIRS = [join(MESH_DIR, 'med'), join(MESH_DIR, 'high')];
const LIFT_MARKS = LIFT_DIRS.map((dir) => join(dir, '.gdignore'));

// The `.gdignore` files are the only mutation of the working tree, and a build
// killed between writing and removing them would leave the repository in slim
// mode — every later full build would quietly ship 50 MB less mesh. Hence the
// `finally`, the signal handlers, the entry check and tests/lightApk.test.ts.
let restored = false;
function restoreLifts() {
  if (restored) return;
  restored = true;
  for (const mark of LIFT_MARKS) rmSync(mark, { force: true });
  info('med/ und high/ wieder im Projekt (.gdignore entfernt).');
  // The meshes have to be back before anything else runs, or the next
  // `test:game` reports the missing tiers.
  tryRun('godot', ['--headless', '--path', 'godot', '--import'], { cwd: REPO, timeout: 900_000 });
}
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    warn(`${signal} — ich räume auf, bevor ich beende.`);
    restoreLifts();
    process.exit(130);
  });
}
// `abort()` calls process.exit() and skips every `finally`, so without this hook
// a failure *after* the markers were written would leave the tree silently thin.
process.on('exit', restoreLifts);

let problems = 0;
const check = (cond, good, bad) => {
  if (cond) ok(good);
  else {
    fail(bad);
    problems += 1;
  }
  return cond;
};

step('1/5 Preset mit Mesh-Ausschluss');
if (tryRun('node', ['googleplay/scripts/install-export-preset.mjs'], { cwd: REPO }).code !== 0) {
  abort('Preset-Installation fehlgeschlagen.');
}

/** Every preset whose exclude_filter drops the med/ meshes. */
function slimPresets() {
  const text = readFileSync(PRESETS, 'utf8');
  const out = [];
  for (const m of text.matchAll(/^\[preset\.(\d+)\][ \t]*$/gm)) {
    const start = m.index + m[0].length;
    const next = text.indexOf('\n[preset.', start);
    const chunk = text.slice(start, next === -1 ? text.length : next);
    const name = chunk.match(/^[ \t\n]*name="([^"]+)"/m)?.[1];
    const exclude = chunk.match(/^[ \t]*exclude_filter="([^"]*)"/m)?.[1] ?? '';
    const path = chunk.match(/^[ \t]*export_path="([^"]+)"/m)?.[1] ?? '';
    if (name && exclude.includes(EXCLUDE_MARKER)) out.push({ index: Number(m[1]), name, exclude, path });
  }
  return out;
}

const slim = slimPresets();
if (slim.length === 0) {
  abort(`Kein Preset schließt ${EXCLUDE_MARKER} aus.`);
}
if (slim.length > 1) {
  // Two agents can each add one; picking the wrong one would ship a different
  // build than the name says.
  warn(`${slim.length} Presets schließen die Meshes aus: ${slim.map((p) => `[${p.index}] ${p.name}`).join(', ')}`);
  info(`Verwendet wird "${cfg.android.slim.name}" — die anderen bitte entfernen.`);
}
const preset = slim.find((p) => p.name === cfg.android.slim.name) ?? slim[0];
info(`Preset: [${preset.index}] ${preset.name}`);

// --- build ------------------------------------------------------------------
const verifyOnly = process.argv.includes('--verify-only');
ensureDir(BUILD_DIR);
// The output path belongs to the preset: an adopted preset keeps the path its
// author chose. The fallback mirrors `SLIM_APK_PATH` in
// `install-export-preset.mjs` — deliberately not imported, because that module
// rewrites `export_presets.cfg` when it loads.
const apkPath = preset.path || join(BUILD_DIR, 'singular80-leicht.apk');
info(`Ausgabe: ${apkPath}`);

// --- signing ----------------------------------------------------------------
// Signing: a preset regenerated elsewhere carries no keystore and Godot then
// refuses to export ("Could not find release keystore"). Inject one for the
// build and restore the original three lines afterwards — this file is shared
// with another agent.
//
// Debug keystore first: every other APK in the repo is signed with it, so
// `adb install -r` upgrades the installed app instead of refusing to. Signing a
// sideload build with the Play *upload* key would break exactly that.
const debugKeystore = join(process.env.HOME ?? '', '.android', 'debug.keystore');
const useDebug = existsSync(debugKeystore);
const ksPath = useDebug ? debugKeystore : (process.env.PLAY_KEYSTORE_PATH ?? '');
const ksUser = useDebug ? 'androiddebugkey' : (process.env.PLAY_KEYSTORE_USER ?? '');
const ksPass = useDebug ? 'android' : (process.env.PLAY_KEYSTORE_PASSWORD ?? '');

function setKeystore(credentials) {
  const text = readFileSync(PRESETS, 'utf8');
  // A block spans the header *and* its `.options` section, so the boundary is
  // the next bare `[preset.N]` header. `indexOf('\n[preset.')` stops at
  // `[preset.N.options]` instead and cuts the keystore lines off.
  const heads = [...text.matchAll(/^\[preset\.(\d+)\][ \t]*$/gm)];
  for (const [i, head] of heads.entries()) {
    if (Number(head[1]) !== preset.index) continue;
    const start = head.index;
    const end = heads[i + 1]?.index ?? text.length;
    const chunk = text.slice(start, end);
    if (!/^[ \t]*keystore\/release=/m.test(chunk)) return null;
    const patched = chunk
      // A preset block spans the header *and* its `.options` section, so the
      // boundary is the next bare `[preset.N]` header. `indexOf('\n[preset.')`
      // stops at `[preset.N.options]` and cuts the keystore lines off.
      .replace(/^[ \t]*keystore\/release="[^"]*"/m, `keystore/release="${credentials.path}"`)
      .replace(/^[ \t]*keystore\/release_user="[^"]*"/m, `keystore/release_user="${credentials.user}"`)
      .replace(/^[ \t]*keystore\/release_password="[^"]*"/m, `keystore/release_password="${credentials.password}"`);
    writeFileSync(PRESETS, text.slice(0, start) + patched + text.slice(end));
    return chunk;
  }
  return null;
}

let ksOriginal = null;
let ksRestored = false;
function restoreKeystore() {
  if (ksRestored || ksOriginal === null) return;
  ksRestored = true;
  try {
    setKeystore({
      path: ksOriginal.match(/^[ \t]*keystore\/release="([^"]*)"/m)?.[1] ?? '',
      user: ksOriginal.match(/^[ \t]*keystore\/release_user="([^"]*)"/m)?.[1] ?? '',
      password: ksOriginal.match(/^[ \t]*keystore\/release_password="([^"]*)"/m)?.[1] ?? '',
    });
  } catch {
    /* best effort — a stray keystore line is better than a failed build */
  }
}
process.on('exit', restoreKeystore);

function signPreset() {
  if (!ksPath || !existsSync(ksPath)) {
    abort(
      'Kein Keystore für das APK.\n' +
        '  Erwartet: ~/.android/debug.keystore (wie alle anderen APKs hier) — sonst\n' +
        '  `npm run keystore` und PLAY_KEYSTORE_PATH/USER/PASSWORD setzen.',
    );
  }
  ksOriginal = setKeystore({ path: ksPath, user: ksUser, password: ksPass });
  if (ksOriginal === null) abort('Keystore-Felder im Preset nicht gefunden.');
  info(`Signatur: ${ksPath} (${useDebug ? 'Debug-Key wie die übrigen APKs' : 'PLAY_KEYSTORE_*'})`);
}

if (!verifyOnly) {
  // A stale pair means an earlier run was killed; building on top of it would
  // hide the problem.
  const stale = LIFT_MARKS.filter((mark) => existsSync(mark));
  if (stale.length > 0) {
    abort(
      'Es liegen bereits .gdignore-Dateien im Baum — ein früherer Build wurde '
      + 'unterbrochen.\n'
      + '  rm -f godot/assets/meshes/med/.gdignore godot/assets/meshes/high/.gdignore\n'
      + '  godot --headless --path godot --import',
    );
  }

  step('2/5 Content spiegeln + Import');
  if (tryRun('node', ['scripts/sync-content.mjs'], { cwd: REPO }).code !== 0) abort('content:sync fehlgeschlagen.');
  tryRun('godot', ['--headless', '--path', 'godot', '--import'], { cwd: REPO, timeout: 900_000 });

  step('3/5 Android-Template + API-Level');
  tryRun('node', ['scripts/install-android-template.mjs'], { cwd: REPO });
  if (tryRun('node', ['googleplay/scripts/prepare-toolchain.mjs'], { cwd: REPO }).code !== 0) {
    abort('Toolchain-Vorbereitung fehlgeschlagen.');
  }

  // The exclusion itself: hide the two folders from the project, then let the
  // editor re-index what is left. Nothing in the export output would say so if
  // this silently stopped working — the md5 comparison below is the only proof.
  step('4/5 Release-APK bauen (Detailstufen aus dem Projekt nehmen)');
  try {
    for (const dir of LIFT_DIRS) mkdirSync(dir, { recursive: true });
    for (const mark of LIFT_MARKS) writeFileSync(mark, '');
    info('med/ und high/ aus dem Projekt genommen (.gdignore).');
    tryRun('godot', ['--headless', '--path', 'godot', '--import'], { cwd: REPO, timeout: 900_000 });
    signPreset();

    if (existsSync(apkPath)) {
      const { unlinkSync } = await import('node:fs');
      unlinkSync(apkPath);
    }
    const out = tryRun('godot', ['--headless', '--path', 'godot', '--export-release', preset.name, apkPath], {
      cwd: REPO,
      timeout: 3_600_000,
    });
    if (out.code !== 0) {
      console.log(out.out.split('\n').slice(-30).join('\n'));
      abort('Godot-Export fehlgeschlagen.');
    }
    if (!existsSync(apkPath)) abort(`Godot meldet Erfolg, aber ${apkPath} fehlt.`);
  } finally {
    restoreLifts();
    restoreKeystore();
  }
}
if (!existsSync(apkPath)) abort(`${apkPath} fehlt — erst ohne --verify-only bauen.`);
const mb = (statSync(apkPath).size / 1024 / 1024).toFixed(1);
ok(`APK: ${apkPath} (${mb} MB)`);

// --- verify -----------------------------------------------------------------
step('5/5 APK prüfen');
const listing = tryRun('unzip', ['-l', apkPath]);
if (listing.code !== 0) abort('Die Datei ist kein APK (kein ZIP).');
const entries = listing.out
  .split('\n')
  .slice(1)
  .map((line) => line.trim().split(/\s+/).pop())
  .filter(Boolean);
const inApk = new Set(entries);

// Collects, per tier, the `assets/…` path every imported mesh ends up at in the
// APK. The tiers are only distinguishable by the md5 the `.import` files
// record, so a name-based check would call a full mesh set a clean slim build.
function importedTargets(tier) {
  const root = join(GODOT_DIR, 'assets', 'meshes');
  const dir = tier === 'low' ? root : join(root, tier);
  if (!existsSync(dir)) return [];
  const out = [];
  // The mesh folders are grouped by collection (`pang/`, `candy/`, …), so a
  // flat readdir would silently see only the ungrouped meshes and report a
  // green check on a fraction of the truth.
  const walk = (current, prefix) => {
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      if (entry.isDirectory()) {
        // `med/` and `high/` live inside the low mesh root, so the low walk has
        // to step over them — otherwise it counts all three tiers and reports
        // the med/high meshes as "missing" when they were never meant to ship.
        if (tier === 'low' && (entry.name === 'med' || entry.name === 'high')) continue;
        walk(join(current, entry.name), `${prefix}${entry.name}/`);
        continue;
      }
      if (!entry.name.endsWith('.glb')) continue;
      const meta = readFileSync(join(current, `${entry.name}.import`), 'utf8');
      const target = meta.match(/path="([^"]+)"/)?.[1];
      // `res://` is mounted at `assets/` in the APK, so `res://.godot/imported/x.scn`
      // is stored as `assets/.godot/imported/x.scn`.
      if (target) out.push({ key: `${tier === 'low' ? '' : `${tier}/`}${prefix}${entry.name}`, apk: `assets/${target.replace(/^res:\/\//, '')}` });
    }
  };
  walk(dir, '');
  return out;
}

const low = importedTargets('low');
const rich = [...importedTargets('med'), ...importedTargets('high')];
check(low.length > 100, `${low.length} Low-Poly-Meshes im Projekt.`, `Nur ${low.length} Low-Poly-Meshes gefunden — stimmt die Pfadannahme nicht?`);
info(`${rich.length} reichere Meshes (med + high) müssen draußen bleiben.`);

const missingLow = low.filter((m) => !inApk.has(m.apk));
check(missingLow.length === 0, `Alle ${low.length} Low-Poly-Meshes sind im Paket.`, `${missingLow.length} Low-Poly-Meshes fehlen, z. B. ${missingLow.slice(0, 3).map((m) => m.key).join(', ')} — das Spiel hätte nichts zum Laden.`);

const leaked = rich.filter((m) => inApk.has(m.apk));
check(leaked.length === 0, `Keines der ${rich.length} med-/high-Meshes ist im Paket.`, `${leaked.length} reichere Meshes im Paket, z. B. ${leaked.slice(0, 5).map((m) => m.key).join(', ')} — exclude_filter greift nicht.`);

const lodEntry = [...inApk].find((e) => e.endsWith('lod.json'));
check(Boolean(lodEntry), `lod.json ist dabei (${lodEntry}).`, 'lod.json fehlt — die Galerie zeigt keine Dreieckszahlen.');

// No raw .glb is ever shipped unchanged — Godot imports them.
const raw = [...inApk].filter((e) => /assets\/meshes\/.*\.glb$/.test(e));
check(raw.length === 0, 'Keine Roh-GLB im Paket (nur die importierten).', `${raw.length} Roh-GLB im Paket — der Export hat die Quellen mitgenommen.`);

const sdk = androidSdkRoot();
const aapt2 = sdk
  ? [...['36.1.0', '36.0.0', '35.0.0'].map((v) => join(sdk, 'build-tools', v, 'aapt2'))].find((p) => existsSync(p))
  : null;
if (aapt2) {
  const badging = tryRun(aapt2, ['dump', 'badging', apkPath]);
  if (badging.code === 0) {
    // aapt2 prints `minSdkVersion:`, older aapt printed `sdkVersion:`. The word
    // boundary keeps `targetSdkVersion` from matching either.
    const line = (re) => badging.out.match(re)?.[1] ?? '?';
    const pkg = line(/package: name='([^']+)'/);
    const target = line(/targetSdkVersion:'([^']+)'/);
    const min = line(/minSdkVersion:'([^']+)'/) !== '?' ? line(/minSdkVersion:'([^']+)'/) : line(/\bsdkVersion:'([^']+)'/);
    const compile = line(/compileSdkVersion='([^']+)'/);
    const perms = [...badging.out.matchAll(/uses-permission: name='([^']+)'/g)].map((m) => m[1]);
    info(`package=${pkg} minSdk=${min} targetSdk=${target} compileSdk=${compile}`);
    info(`permissions: ${perms.join(', ') || '—'}`);
    check(pkg === cfg.app.packageName, `Paketname ${pkg}.`, `Paketname ${pkg} ≠ ${cfg.app.packageName}.`);
    check(min === String(cfg.android.minSdk), `minSdk ${min} wie konfiguriert.`, `minSdk ${min} ≠ ${cfg.android.minSdk}.`);
    check(perms.length <= 2 && perms.every((p) => /INTERNET|VIBRATE/.test(p)),
      `Permissions wie erwartet (${perms.length}).`,
      `Unerwartete Permissions: ${perms.join(', ')} — dafür ist das Formular "Declare permissions" auszufüllen.`);
    // The API-36 target requirement applies to Play uploads, not to a sideloaded
    // APK, so this is information rather than a blocker.
    if (Number(target) < cfg.android.targetSdk) {
      info(`targetSdk ${target} — für ein Sideload-APK in Ordnung; Play verlangt ${cfg.android.targetSdk} (siehe docs/RELEASE.md).`);
    }
  } else {
    warn('aapt2 konnte das APK nicht lesen.');
  }
} else {
  warn('aapt2 fehlt → Paketname und Permissions nicht geprüft.');
}

// Report the win against the full APK, which lands in the repo's `build/` or in
// this folder depending on which script built it.
const full = [join(BUILD_DIR, 'singular80.apk'), join(REPO, 'build', 'singular80.apk')].find((p) => existsSync(p));
if (full) {
  const fullMb = statSync(full).size / 1024 / 1024;
  ok(`Volles APK: ${fullMb.toFixed(1)} MB → schlank: ${mb} MB (−${(fullMb - Number(mb)).toFixed(1)} MB, −${(((fullMb - Number(mb)) / fullMb) * 100).toFixed(0)} %)`);
} else {
  info('Kein volles APK zum Vergleich gefunden (npm run godot:apk:release).');
}
info(`Installieren:  adb install -r ${apkPath}`);
info('Gleicher Debug-Key wie die übrigen APKs → update über die bestehende Installation.');
info('Hinweis: dieser Build hat das Manifest im Gradle-Verzeichnis ersetzt.');
info('  `npm run verify` prüft das AAB jetzt gegen ein anderes Manifest und');
info('  verweigert die Freigabe — vorher `npm run build` neu laufen lassen.');

if (problems > 0) abort(`${problems} Problem(e) — das APK ist nicht das, was der Preset verspricht.`);
done(`Schlankes APK: ${apkPath} (${mb} MB)`);
