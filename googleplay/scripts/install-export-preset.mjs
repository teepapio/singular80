/**
 * Writes the `Google Play (AAB)` export preset into godot/export_presets.cfg.
 *
 * Godot only ever reads res://export_presets.cfg, so the preset has to live
 * there - but it is *generated* here, from config/app.json, so that there is
 * exactly one place where the package name, version code and SDK levels live.
 *
 * Idempotent: running it twice leaves the file byte-identical. It never
 * touches the existing `Android` (APK) preset, and it is a no-op when another
 * agent has a different working-tree state (it only ever appends/replaces its
 * own block).
 */
import { readFileSync, writeFileSync, copyFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import {
  config, PRESETS, REPO, GODOT_DIR, PROJECT, PRESET_NAME, HERE,
  ok, info, warn, step, done, abort, tryRun,
} from './lib.mjs';

export const AAB_PATH = join(REPO, 'build', 'singular80-play.aab');

function block(cfg) {
  const { app, version, android } = cfg;
  const archs = Object.entries(android.architectures)
    .map(([abi, on]) => `architectures/${abi}=${on ? 'true' : 'false'}`)
    .join('\n');
  // Godot reads the keystore from the preset file, not from the environment.
  // build-aab.mjs therefore installs the preset *with* the credentials, runs the
  // export and reinstalls it without them right afterwards, so the password
  // never survives in the working tree.
  const ks = android.keystoreEnv;
  // Godot ships its own launcher icon unless these are set. The files come from
  // `npm run assets`; if they are not there yet the app simply keeps the
  // project icon, so this stays optional.
  const icons = join(PROJECT, 'assets', 'generated');
  const icon = (name) => (existsSync(join(icons, name)) ? join(icons, name) : '');
  return `[preset.1]

name="${PRESET_NAME}"
platform="Android"
runnable=false
advanced_options=true
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter="*.json"
exclude_filter="tests/*, shot.gd, shot.tscn, probe.gd, _*, android/build/*, build/*"
export_path="${AAB_PATH}"
patches=PackedStringArray()
encryption_include_filters=""
encryption_exclude_filters=""
seed=0
encrypt_pck=false
encrypt_directory=false
script_export_mode=2

[preset.1.options]

custom_template/debug=""
custom_template/release=""
gradle_build/use_gradle_build=true
gradle_build/gradle_build_directory="res://android"
gradle_build/android_source_template=""
gradle_build/compress_native_libraries=false
; 0 ist APK, 1 ist AAB — Google Play nimmt für neue Apps nur AAB.
gradle_build/export_format=1
gradle_build/min_sdk="${android.minSdk}"
gradle_build/target_sdk="${android.targetSdk}"
gradle_build/custom_theme_attributes={}
keystore/release="${process.env[ks.pathEnv] ?? ''}"
keystore/release_user="${process.env[ks.userEnv] ?? ''}"
keystore/release_password="${process.env[ks.passwordEnv] ?? ''}"
${archs}
version/code=${version.versionCode}
version/name="${version.versionName}"
package/unique_name="${app.packageName}"
package/name="${app.storeName}"
package/signed=true
package/app_category=2
package/retain_data_on_uninstall=true
package/exclude_from_recents=false
package/show_in_android_tv=false
package/show_in_app_library=true
package/show_as_launcher_app=false
launcher_icons/main_192x192="${icon('icon-192.png')}"
launcher_icons/adaptive_foreground_432x432="${icon('adaptive-foreground-432.png')}"
launcher_icons/adaptive_background_432x432="${icon('adaptive-background-432.png')}"
launcher_icons/adaptive_monochrome_432x432="${icon('adaptive-monochrome-432.png')}"
graphics/opengl_debug=false
shader_baker/enabled=false
xr_features/xr_mode=0
gesture/swipe_to_dismiss=false
screen/immersive_mode=true
screen/edge_to_edge=false
screen/support_small=true
screen/support_normal=true
screen/support_large=true
screen/support_xlarge=true
screen/background_color=Color(0.031, 0.047, 0.086, 1)
user_data_backup/allow=false
command_line/extra_args=""
apk_expansion/enable=false
apk_expansion/SALT=""
apk_expansion/public_key=""
permissions/custom_permissions=PackedStringArray()
permissions/internet=true
permissions/vibrate=true
permissions/wake_lock=false
permissions/write_external_storage=false`;
}

/**
 * Rewrites `#` comment lines to `;` inside the preset file.
 *
 * Godot's ConfigFile does **not** treat `#` as a comment. It strips the
 * whitespace, concatenates the line with the next one and — as soon as an `=`
 * appears — stores the result under a mangled key. In the shipped file that
 * silently destroyed `include_filter` and `exclude_filter` in the `Android`
 * preset, which is why the Godot exporter prints
 *
 *   ERROR: Couldn't find the given section "preset.0" and key "include_filter"
 *
 * and why `tests/*.gd` ends up inside the release build. `;` is the comment
 * character Godot really uses.
 *
 * Only whole-line comments are touched; values and keys are never modified.
 */
function repairHashComments(text) {
  const lines = text.split('\n');
  let repaired = 0;
  const fixed = lines.map((line) => {
    const m = line.match(/^(\s*)#(?!#)(.*)$/);
    if (!m) return line;
    repaired += 1;
    return `${m[1]};${m[2]}`;
  });
  return { text: fixed.join('\n'), repaired };
}

/**
 * Removes every previously written Play block, including orphaned
 * `[preset.1.options]` sections. A block must end at the next *preset* header —
 * `[preset.1.options]` itself matches `/^\[preset\./`, so a naive search for the
 * next section cuts the block after a single line and leaves a corrupted file.
 */
function stripPlayBlocks(text) {
  return text
    .replace(/^\[preset\.1(?:\.options)?\]\n[\s\S]*?(?=^\[preset\.\d+(?:\.options)?\]\n|(?![\s\S]))/gm, '')
    .replace(/\n{3,}/g, '\n\n');
}

const cfg = config();
step(`Export-Preset → ${PRESETS}`);

// Cheap lint first: Godot's ConfigFile treats `#` as a comment only while the
// line holds no `=`, and a broken file makes the preset vanish without warning.
for (const [n, line] of block(cfg).split('\n').entries()) {
  if (line.trimStart().startsWith('#') && line.includes('=')) {
    abort(`Kommentar in Zeile ${n + 1} enthält "=" — ConfigFile parst das nicht:\n  ${line.trim()}`);
  }
}

let text;
try {
  text = readFileSync(PRESETS, 'utf8');
} catch {
  abort(`Konnte ${PRESETS} nicht lesen. Läuft dieses Skript im Repo?`);
}

const cleaned = stripPlayBlocks(text);
if (cleaned === text) {
  ok(`Preset "${PRESET_NAME}" ist bereits aktuell.`);
} else {
  info('Vorhandener Block wird ersetzt …');
}
text = cleaned;

const repaired = repairHashComments(text);
if (repaired.repaired > 0) {
  text = repaired.text;
  ok(`${repaired.repaired} "#"-Kommentarzeile(n) zu ";" — Godots ConfigFile hatte include_filter/exclude_filter verschluckt.`);
}

{
  const highest = Math.max(
    0,
    ...[...text.matchAll(/^\[preset\.(\d+)\]$/gm)].map((m) => Number(m[1])),
  );
  if (highest !== 0) {
    warn(`godot/export_presets.cfg hat ${highest + 1} Presets; der Play-Block landet als [preset.${highest + 1}].`);
    warn('Prüfe die Indizes, bevor du baust (Godot braucht lückenlose Indizes).');
  }
}

const next = `${text.replace(/\s*$/, '')}\n\n${block(cfg)}\n`;
writeFileSync(PRESETS, next);
ok(`"${PRESET_NAME}" geschrieben (AAB, targetSdk ${cfg.android.targetSdk}, versionCode ${cfg.version.versionCode}).`);

// Authoritative check: let Godot itself parse the file and look the preset up.
// The harness lives next to this script and is copied into godot/ with a `_`
// prefix, which export_presets.cfg already excludes from every build.
const harness = join(GODOT_DIR, '_cfgtest.gd');
copyFileSync(join(HERE, 'validate-presets.gd'), harness);
const parsed = tryRun(
  'godot',
  ['--headless', '--path', 'godot', '--script', 'res://_cfgtest.gd', '--', 'export_presets.cfg', PRESET_NAME],
  { cwd: REPO, timeout: 300_000 },
);
const line = parsed.out.split('\n').find((l) => l.startsWith('PARSE-')) ?? '';
if (parsed.code !== 0 || !line.startsWith('PARSE-OK')) {
  abort(`Godot kann export_presets.cfg nicht parsen:\n  ${line.trim() || parsed.out.trim().split('\n').slice(-3).join(' ')}`);
}
ok(line.trim());

// Godot reads export presets at import time; a malformed file fails silently in
// the editor and only shows up as a missing preset. The ConfigFile check above
// is the real gate, this is the belt-and-braces one.
const written = readFileSync(PRESETS, 'utf8');
if (!written.includes(`name="${PRESET_NAME}"`)) abort('Preset-Datei unvollständig geschrieben.');
if (!/gradle_build\/export_format=1/.test(written)) abort('export_format ist nicht AAB.');

done('export_presets.cfg ist aktuell.');
