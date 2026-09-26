/**
 * Writes the release export presets into godot/export_presets.cfg.
 *
 * Godot only ever reads res://export_presets.cfg, so the presets have to live
 * there - but they are *generated* here, from config/app.json, so that there is
 * exactly one place where the package name, version code and SDK levels live.
 *
 * Two presets, both managed by this script:
 *
 *   [1] Google Play (AAB)          signed app bundle, everything included
 *   [2] Android (APK, schlank)     plain APK *without* the med/ and high/
 *                                   meshes — roughly 45 MB smaller, the mesh
 *                                   gallery then only offers the low-poly
 *                                   level
 *
 * The existing `Android` (APK) preset in the repo is left alone: it is the
 * full-size debug/sideload build the rest of the project uses.
 *
 * Idempotent: running it twice leaves the file byte-identical, and it only ever
 * touches its own indices.
 */
import { readFileSync, writeFileSync, copyFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import {
  config, PRESETS, REPO, GODOT_DIR, PROJECT, PRESET_NAME, HERE,
  ok, info, warn, step, done, abort, tryRun,
} from './lib.mjs';

export const AAB_PATH = join(REPO, 'build', 'singular80-play.aab');
export const SLIM_APK_PATH = join(REPO, 'build', 'singular80-leicht.apk');
export const SLIM_PRESET_NAME = 'Android (Leicht)';

/** Filter, der jedes Skript und jeden Wegwerf-Harness ausschließt. */
const BASE_EXCLUDE = 'tests/*, shot.gd, shot.tscn, probe.gd, _*, android/build/*, build/*';
/**
 * Additionally names the two richer detail levels.
 *
 * This is an *identification* marker, not the mechanism: `exclude_filter` only
 * applies to non-resource files, and an imported `.glb` is a resource. Measured
 * on this project, with these two patterns in the filter the export still
 * packed all 155 med and all 155 high meshes. The slim build therefore drops
 * the folders with `.gdignore` (see `build-apk-slim.mjs`); the pattern stays so
 * the preset can be recognised as the slim one.
 */
const SLIM_EXCLUDE = `${BASE_EXCLUDE}, assets/meshes/med/*, assets/meshes/high/*`;

function block(cfg, preset) {
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
  return `[preset.${preset.index}]

name="${preset.name}"
platform="Android"
runnable=false
advanced_options=true
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter="*.json"
exclude_filter="${preset.exclude}"
export_path="${preset.path}"
patches=PackedStringArray()
encryption_include_filters=""
encryption_exclude_filters=""
seed=0
encrypt_pck=false
encrypt_directory=false
script_export_mode=2

[preset.${preset.index}.options]

custom_template/debug=""
custom_template/release=""
gradle_build/use_gradle_build=true
gradle_build/gradle_build_directory="res://android"
gradle_build/android_source_template=""
; Komprimiert die native Bibliothek. Gemessen an diesem Projekt: die
; libgodot_android.so ist 70,0 MB und geht als ZIP-Eintrag auf 23,2 MB — das
; APK wird 47,7 MB (37 %) kleiner. Der Preis: Android entpackt die Bibliothek
; beim Installieren, das Gerät belegt also APK plus entpackte .so statt nur APK.
; Für den Download zählt das nicht, für den Speicher schon — siehe
; docs/RELEASE.md.
gradle_build/compress_native_libraries=true
; 0 ist APK, 1 ist AAB — Google Play nimmt für neue Apps nur AAB.
gradle_build/export_format=${preset.format}
gradle_build/min_sdk="${cfg.android.minSdk}"
gradle_build/target_sdk="${cfg.android.targetSdk}"
gradle_build/custom_theme_attributes={}
keystore/release="${process.env[cfg.android.keystoreEnv.pathEnv] ?? ''}"
keystore/release_user="${process.env[cfg.android.keystoreEnv.userEnv] ?? ''}"
keystore/release_password="${process.env[cfg.android.keystoreEnv.passwordEnv] ?? ''}"
${archs}
version/code=${cfg.version.versionCode}
version/name="${cfg.version.versionName}"
package/unique_name="${cfg.app.packageName}"
package/name="${cfg.app.storeName}"
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
 * Removes one preset block. A block ends at the next *preset* header —
 * `[preset.1.options]` also matches `/^\[preset\./`, so searching for the next
 * section cuts the block after a single line and corrupts the file.
 */
function stripIndex(text, index) {
  const pattern = new RegExp(
    `^\\[preset\\.${index}(?:\\.options)?\\]\\n[\\s\\S]*?(?=^\\[preset\\.\\d+(?:\\.options)?\\]\\n|(?![\\s\\S]))`,
    'gm',
  );
  return text.replace(pattern, '');
}

/**
 * Rewrites `#` comment lines to `;`.
 *
 * Godot's ConfigFile does **not** treat `#` as a comment. It strips the
 * whitespace, concatenates the line with the next one and — as soon as an `=`
 * appears — stores the result under a mangled key. In the shipped file that
 * silently destroyed `include_filter` and `exclude_filter` in the `Android`
 * preset, which is why the Godot exporter prints
 *
 *   ERROR: Couldn't find the given section "preset.0" and key "include_filter"
 *
 * and why `tests/*.gd` ended up inside the release build. `;` is the comment
 * character Godot really uses.
 */
function repairHashComments(text) {
  let repaired = 0;
  const fixed = text.split('\n').map((line) => {
    const m = line.match(/^(\s*)#(?!#)(.*)$/);
    if (!m) return line;
    repaired += 1;
    return `${m[1]};${m[2]}`;
  });
  return { text: fixed.join('\n'), repaired };
}

// --- main -------------------------------------------------------------------

/**
 * Rewrites the `exclude_filter` inside an existing preset block and returns the
 * previous file content, or null when the preset vanished.
 *
 * Only that one line. The preset keeps its own `export_path` and every other
 * choice its author made — another agent's test asserts on them, and a
 * read-modify-write that "improves" a stranger's block is how two agents lose
 * each other's work.
 */
function patchAdopted(file, preset) {
  const current = readFileSync(file, 'utf8');
  const heads = [...current.matchAll(/^\[preset\.(\d+)\][ \t]*$/gm)];
  for (const head of heads) {
    if (Number(head[1]) !== preset.index) continue;
    const start = head.index;
    const nextIdx = current.indexOf('\n[preset.', start + head[0].length);
    const end = nextIdx === -1 ? current.length : nextIdx + 1;
    const chunk = current.slice(start, end);
    if (!/^[ \t]*exclude_filter=/m.test(chunk)) return null;
    if (/^[ \t]*exclude_filter="[^"]*"/m.test(chunk).exec(chunk)[0] === `exclude_filter="${preset.exclude}"`) {
      return current;
    }
    const patched = chunk.replace(
      /^[ \t]*exclude_filter="[^"]*"/m,
      // A missing med/ exclusion is the one thing that must never slip through:
      // the build would then silently ship 50 MB more than promised.
      `exclude_filter="${preset.exclude}"`,
    );
    writeFileSync(file, current.slice(0, start) + patched + current.slice(end));
    return current;
  }
  return null;
}

const cfg = config();
step(`Export-Presets → ${PRESETS}`);

const wanted = [
  { name: PRESET_NAME, path: AAB_PATH, format: 1, exclude: BASE_EXCLUDE, managed: true },
  {
    name: SLIM_PRESET_NAME,
    path: SLIM_APK_PATH,
    format: 0,
    exclude: SLIM_EXCLUDE,
    managed: true,
    adopt: cfg.android.slim.adoptExisting ?? [],
  },
];

let text;
try {
  text = readFileSync(PRESETS, 'utf8');
} catch {
  abort(`Konnte ${PRESETS} nicht lesen. Läuft dieses Skript im Repo?`);
}

/**
 * Every `[preset.N]` with the name that belongs to it. The header and the name
 * are usually separated by a blank line, so a strict `]\nname=` pattern finds
 * nothing and every index looks free — which is how a foreign preset once got
 * overwritten. Read the block instead of guessing.
 */
function readPresets(source) {
  const out = new Map();
  const heads = [...source.matchAll(/^\[preset\.(\d+)\](?:_options)?[ \t]*$/gm)];
  for (const head of heads) {
    const start = head.index + head[0].length;
    const next = source.indexOf('\n[preset.', start);
    const block = source.slice(start, next === -1 ? source.length : next);
    const name = block.match(/^[ \t\n]*name="([^"]+)"/m)?.[1];
    if (name) out.set(name, { index: Number(head[1]), block, options: block.includes('.options]') });
  }
  return out;
}

const existing = readPresets(text);
for (const [name, entry] of existing) info(`gefunden: [${entry.index}] ${name}`);

/** Indices taken by somebody else — never one of those may be replaced. */
const foreign = new Set([...existing.values()].map((e) => e.index));

for (const preset of wanted) {
  if (existing.has(preset.name)) {
    preset.index = existing.get(preset.name).index;
    continue;
  }
  // A slim preset that somebody else already made is adopted instead of writing a
  // second one doing the same job.
  if (preset.adopt?.length) {
    const adopted = preset.adopt.find((name) => existing.has(name));
    if (adopted) {
      preset.index = existing.get(adopted).index;
      preset.name = adopted;
      preset.adopted = true;
      ok(`Schlankes Preset "${adopted}" [${preset.index}] wird übernommen statt ein zweites anzulegen.`);
      continue;
    }
  }
  // Smallest index that nobody uses.
  let candidate = 0;
  while (foreign.has(candidate)) candidate += 1;
  preset.index = candidate;
  foreign.add(candidate);
  info(`${preset.name}: freier Index ${candidate}.`);
}

for (const preset of wanted) {
  if (preset.adopted) continue; // nur exclude_filter und export_path nachtragen
  const stripped = stripIndex(text, preset.index);
  if (stripped === text) info(`${preset.name}: Index ${preset.index} ist frei.`);
  else info(`${preset.name}: eigener Block ${preset.index} wird ersetzt.`);
  text = stripped;
}

const repaired = repairHashComments(text);
if (repaired.repaired > 0) {
  text = repaired.text;
  ok(`${repaired.repaired} "#"-Kommentarzeile(n) zu ";" — Godots ConfigFile hatte include_filter/exclude_filter verschluckt.`);
}

// Cheap lint before anything else: a broken file makes the preset vanish
// without a warning, and the export then fails with a confusing message.
for (const preset of wanted) {
  if (preset.adopted) continue;
  for (const [n, line] of block(cfg, preset).split('\n').entries()) {
    if (line.trimStart().startsWith('#') && line.includes('=')) {
      abort(`Kommentar in Zeile ${n + 1} enthält "=" — ConfigFile parst das nicht:\n  ${line.trim()}`);
    }
  }
}

const blocks = [...wanted]
  .filter((p) => !p.adopted)
  .sort((a, b) => a.index - b.index)
  .map((preset) => block(cfg, preset))
  .join('\n\n');
if (blocks) writeFileSync(PRESETS, `${text.replace(/\s*$/, '')}\n\n${blocks}\n`);

// Adopted presets keep their body; only the exclusion is added, so a foreign
// author's `export_path` and every other choice survive untouched.
for (const preset of wanted.filter((p) => p.adopted)) {
  const patched = patchAdopted(PRESETS, preset);
  if (patched === null) abort(`"${preset.name}" verschwunden zwischen Lesen und Schreiben.`);
  ok(`"${preset.name}": exclude_filter gesetzt (${preset.exclude.includes('med') ? 'mit' : 'OHNE'} med/high-Ausschluss).`);
}
for (const preset of wanted) {
  const blockText = readPresets(readFileSync(PRESETS, 'utf8')).get(preset.name);
  if (!blockText) abort(`"${preset.name}" fehlt nach dem Schreiben.`);
  info(`${preset.name} [${blockText.index}] → ${blockText.block.match(/exclude_filter="([^"]*)"/)?.[1]}`);
}

// Authoritative check: let Godot parse the file and look every preset up. The
// harness lives next to this script and is copied into godot/ with a `_`
// prefix, which the exclude filters already exclude from every build.
const harness = join(GODOT_DIR, '_cfgtest.gd');
copyFileSync(join(HERE, 'validate-presets.gd'), harness);
for (const preset of wanted) {
  const parsed = tryRun(
    'godot',
    ['--headless', '--path', 'godot', '--script', 'res://_cfgtest.gd', '--', 'export_presets.cfg', preset.name],
    { cwd: REPO, timeout: 300_000 },
  );
  const line = parsed.out.split('\n').find((l) => l.startsWith('PARSE-')) ?? '';
  if (parsed.code !== 0 || !line.startsWith('PARSE-OK')) {
    abort(`Godot kann "${preset.name}" nicht lesen:\n  ${line.trim() || parsed.out.trim().split('\n').slice(-3).join(' ')}`);
  }
  ok(line.trim());
}

// Belt and braces: the filters actually made it into the file.
const written = readFileSync(PRESETS, 'utf8');
for (const preset of wanted) {
  if (!written.includes(`name="${preset.name}"`)) abort(`"${preset.name}" fehlt in der geschriebenen Datei.`);
  if (!written.includes(`gradle_build/export_format=${preset.format}`)) abort(`${preset.name}: falsches Format.`);
  if (!written.includes(preset.exclude)) abort(`${preset.name}: exclude_filter fehlt.`);
}
if (wanted.some((p) => p.name === SLIM_PRESET_NAME) && !written.includes('assets/meshes/med/*')) {
  abort('Der schlanke Preset schließt med/ nicht aus.');
}

done(`export_presets.cfg ist aktuell (${wanted.length} Presets).`);
