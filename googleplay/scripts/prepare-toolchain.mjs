/**
 * Brings the local toolchain to the state Google Play requires as of
 * 2026-08-31: apps must target Android 16 / API level 36.
 *
 * Two independent things can deliver API 36, and this script picks whichever
 * is available:
 *
 *   1. `sdkmanager "platforms;android-36"` installs the platform, and
 *      `patchAndroidTemplate()` raises compileSdk/targetSdk/buildTools in
 *      godot/android/build/config.gradle to match. This is the path that works
 *      with the Godot version that is installed today.
 *   2. Upgrading Godot to a release whose template already targets 36 (4.7+).
 *      `check-env.mjs` reports which one applies; the patch is a no-op then.
 *
 * `npm run godot:android-template` rewrites godot/android/build from the
 * engine's zip, so the patch has to be applied *after* every install. The
 * `build` script therefore calls this file again before exporting.
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import {
  config, GODOT_DIR, REPO, androidSdkRoot, sdkmanager, which,
  ok, info, warn, fail, step, done, abort, run, tryRun,
  ensureDir, TOOL_DIR, bundletool, BUNDLETOOL_URL, BUNDLETOOL_VERSION,
} from './lib.mjs';

const cfg = config();
const { targetSdk, compileSdk, buildTools, platform, minSdk } = cfg.android;

/** `platforms;android-36` for "android-36", `build-tools;36.0.0` for "36.0.0". */
function sdkPackageIds() {
  const ids = [];
  if (platform) ids.push(`platforms;${platform}`);
  if (buildTools) ids.push(`build-tools;${buildTools}`);
  return ids;
}

function installSdkPackages() {
  const root = androidSdkRoot();
  if (!root) {
    fail('Kein Android SDK gefunden (ANDROID_HOME / ~/Android/Sdk).');
    info('Godot braucht es nur für den Gradle-Build, den Play verlangt.');
    return false;
  }
  const manager = sdkmanager();
  if (!manager) {
    fail('sdkmanager fehlt — "Android SDK Command-line Tools (latest)" installieren.');
    return false;
  }
  const ids = sdkPackageIds();
  step(`Android SDK: ${ids.join(', ')}`);
  const wanted = ids.filter((id) => {
    const dir = id.startsWith('platforms;') ? join(root, 'platforms', id.slice('platforms;'.length)) : join(root, 'build-tools', id.slice('build-tools;'.length));
    return !existsSync(dir);
  });
  if (wanted.length === 0) {
    ok(`API ${targetSdk} ist bereits installiert (${root}).`);
    return true;
  }
  info(`Installiere: ${wanted.join(', ')} (kann ein paar Minuten dauern)`);
  // Piped, not inherited: sdkmanager draws a progress bar that buries the rest
  // of the output. On failure the tail is printed instead.
  const res = tryRun(manager, [...wanted, `--sdk_root=${root}`]);
  if (res.code !== 0) {
    fail('sdkmanager ist fehlgeschlagen. Letzte Zeilen:');
    for (const line of res.out.split('\n').filter((l) => l.trim()).slice(-6)) info(`  ${line.trim()}`);
    return false;
  }
  ok('Installiert.');
  return true;
}

/**
 * Raises the Gradle template to the configured SDK levels. Idempotent, and safe
 * to re-run after `npm run godot:android-template` overwrote the directory.
 */
function patchAndroidTemplate() {
  const build = join(GODOT_DIR, 'android', 'build');
  const configGradle = join(build, 'config.gradle');
  step(`Godot-Android-Template → API ${targetSdk}`);

  if (!existsSync(configGradle)) {
    warn('godot/android/build fehlt — erst `npm run godot:android-template`.');
    return false;
  }

  const before = readFileSync(configGradle, 'utf8');
  let after = before;
  // `key : <value>,` → keep the comma and any trailing comment, replace only the
  // value. The template is Groovy source: dropping a comma silently breaks it.
  const set = (key, value) => {
    const re = new RegExp(`^(\\s*${key}\\s*:\\s*)([^,\\n]*)(\\s*,\\s*(?://[^\\n]*)?)`, 'm');
    if (!re.test(after)) {
      warn(`  ${key} nicht gefunden — Template-Struktur unerwartet, bitte prüfen.`);
      return;
    }
    after = after.replace(re, (_m, head, _old, tail) => `${head}${value}${tail}`);
  };
  set('compileSdk', compileSdk);
  set('targetSdk', targetSdk);
  set('minSdk', minSdk);
  set('buildTools', `'${buildTools}'`);

  // Groovy syntax check: every entry of ext.versions is a bare `key: value`
  // pair. A dropped comma would only surface as a Gradle parse error hours
  // into the build, so verify the shape right here.
  const broken = after.match(/^\s*(compileSdk|minSdk|targetSdk|buildTools)\s*:[^\n]*$/m);
  if (broken && !broken[0].includes(',')) {
    abort(`Patch hat die Syntax zerlegt: ${broken[0].trim()}`);
  }

  if (after === before) {
    ok(`Template steht bereits auf compileSdk ${compileSdk} / targetSdk ${targetSdk}.`);
  } else {
    writeFileSync(configGradle, after);
    ok(`compileSdk → ${compileSdk}, targetSdk → ${targetSdk}, buildTools → ${buildTools}.`);
  }

  // AGP warns (and future versions refuse) when compileSdk is newer than the
  // plugin knows. Silence the warning instead of pinning an older AGP that the
  // engine's Gradle files may not be compatible with.
  const props = join(build, 'gradle.properties');
  if (existsSync(props)) {
    const text = readFileSync(props, 'utf8');
    const key = `android.suppressUnsupportedCompileSdk=${compileSdk}`;
    if (text.includes(key)) {
      ok('gradle.properties: suppressUnsupportedCompileSdk gesetzt.');
    } else {
      writeFileSync(props, `${text.replace(/\s*$/, '')}\n\n# Added by googleplay/scripts/prepare-toolchain.mjs — Godot's AGP predates API ${compileSdk}.\n${key}\n`);
      ok(`gradle.properties: ${key} ergänzt.`);
    }
  }
  return true;
}

/**
 * bundletool is a single jar on Maven Central. Only used to read the protobuf
 * manifest back out of a built AAB (see verify-aab.mjs), so a failure here is
 * not fatal for building — only for verifying.
 */
function fetchBundletool() {
  step('bundletool');
  const jar = bundletool();
  if (existsSync(jar)) {
    ok(`bereit (${BUNDLETOOL_VERSION}).`);
    return true;
  }
  ensureDir(TOOL_DIR);
  info(`lade ${BUNDLETOOL_URL}`);
  const res = tryRun('sh', ['-c', `curl -fsSL -o "${jar}" "${BUNDLETOOL_URL}"`]);
  if (res.code !== 0) {
    warn('Download fehlgeschlagen (Netzwerk?). verify-aab überspringt dann die Manifest-Prüfung.');
    return false;
  }
  ok('heruntergeladen.');
  return true;
}

const sdkOk = installSdkPackages();
const templateOk = patchAndroidTemplate();
const btOk = fetchBundletool();

if (!which('java')) warn('Java 17 fehlt — der Gradle-Build startet dann nicht.');
if (!which('godot')) abort('Godot nicht im PATH.');

const version = tryRun('godot', ['--version']);
if (version.code === 0) info(`Godot ${version.out.trim()}`);

done(
  sdkOk && templateOk && btOk
    ? `Toolchain bereit für targetSdk ${targetSdk}. Jetzt: npm run keystore && npm run build`
    : 'Toolchain unvollständig — siehe Meldungen oben.',
);
