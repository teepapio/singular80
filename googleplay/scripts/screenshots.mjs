/**
 * Renders real screenshots of the game's own screens for the Play store
 * listing. Play wants actual gameplay, not mock-ups — so the images come out of
 * the running Godot project at the project's native 1280×720 (16:9 landscape,
 * which is what Play recommends for games).
 *
 *   npm run screenshots                  → the default set below
 *   npm run screenshots -- lobby,tetris
 *   npm run screenshots -- --frames 12   → longer settle time per screen
 *   npm run screenshots -- --import DIR  → normalise PNG/JPG from DIR instead
 *
 * The harness lives in this folder and is copied into godot/ with a `_` prefix,
 * which export_presets.cfg already excludes from every build. Rendering the
 * game's own screens needs a display: `--headless` has no renderer.
 */
import { copyFileSync, existsSync, readdirSync, statSync, unlinkSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, extname, basename } from 'node:path';
import { HERE, GODOT_DIR, REPO, SHOT_DIR, ensureDir, ok, info, warn, fail, step, done, abort, tryRun, which } from './lib.mjs';

/**
 * Screen ids from godot/src/core/logic/game_registry.gd, chosen to cover the
 * five categories and the 2D/3D split. `:key=value` payloads switch debug data
 * on for the shot, e.g. `dragonrpg:level=3`.
 */
const DEFAULT_SHOTS = [
  'lobby',
  'tetris',
  'arena',
  'poker',
  '2048',
  'dragonrpg:level=3',
  'crystal3d',
  'metro3d',
];

const importFlag = process.argv.indexOf('--import');
if (importFlag !== -1) {
  importShots(process.argv[importFlag + 1]);
}

// Render mode from here on.
const args = process.argv.slice(2).filter((a, i, all) => a !== '--import' && all[i - 1] !== '--import');
let frames = 4;
const frameFlag = args.indexOf('--frames');
if (frameFlag !== -1) {
  frames = Number(args[frameFlag + 1]);
  args.splice(frameFlag, 2);
}
const screens = args.filter((a) => !a.startsWith('--'));
const shots = screens.length ? screens : DEFAULT_SHOTS;

if (existsSync(SHOT_DIR)) {
  for (const f of readdirSync(SHOT_DIR)) unlinkSync(join(SHOT_DIR, f));
}
ensureDir(SHOT_DIR);

step(`Screenshots: ${shots.join(', ')}`);

if (!existsSync(join(GODOT_DIR, 'main.tscn'))) {
  abort('godot/main.tscn fehlt — läuft dieses Skript im Repo?');
}

// Install the harness. `_` prefix ⇒ excluded from the export (see the preset).
const scriptTarget = join(GODOT_DIR, '_playstore_shots.gd');
const sceneTarget = join(GODOT_DIR, '_playstore_shots.tscn');
copyFileSync(join(HERE, 'playstore_shots.gd'), scriptTarget);
writeFileSync(
  sceneTarget,
  `[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://_playstore_shots.gd" id="1_shots"]

[node name="Shots" type="Node"]
script = ExtResource("1_shots")
`,
);
info('Harness nach godot/ kopiert (Präfix `_` → nicht im AAB).');

const run = tryRun(
  'godot',
  ['--headless', '--path', 'godot', 'res://_playstore_shots.tscn', '--', String(frames), SHOT_DIR, ...shots],
  { cwd: REPO, timeout: 1_800_000 },
);

// Godot prints a lot of noise; only the shot lines matter.
for (const line of run.out.split('\n')) {
  if (line.startsWith('SAVED ')) ok(line.replace('SAVED ', ''));
  else if (line.startsWith('SHOTS-DISPLAY ')) info(line.trim());
  else if (line.startsWith('SHOTS-DONE ')) info(line.trim());
  else if (/SCRIPT ERROR|Compile Error|kein Bild/.test(line)) fail(line.trim());
}

if (run.out.includes('SHOTS-NO-RENDERER')) {
  step('Kein Renderer');
  info('Godot läuft headless — der Dummy-Renderer zeichnet keine Frames,');
  info('d.h. Screenshots aus dem Spiel sind auf dieser Maschine nicht möglich.');
  warn('Drei Wege, die funktionieren:');
  info('  1. Auf einem echten Gerät: Spiel starten, navigieren, dann');
  info('       adb exec-out screencap -p > /tmp/shot.png');
  info('     und die PNGs mit "npm run screenshots -- --import /pfad/zum/ordner"');
  info('     auf 1280×720 bringen und prüfen.');
  info('  2. Am Desktop mit Fenster:  godot --path godot');
  info('     dann Fenster-Screenshot (Play erlaubt auch echte Desktop-Aufnahmen).');
  info('  3. Auf einem Rechner mit Grafik:  npm run screenshots');
  abort('Keine Screenshots erzeugt — headless ist dafür nicht geeignet.');
}

const produced = existsSync(SHOT_DIR) ? readdirSync(SHOT_DIR).filter((f) => f.endsWith('.png')) : [];
if (produced.length === 0) {
  console.log(run.out.split('\n').slice(-25).join('\n'));
  abort('Keine Screenshots erzeugt — siehe Ausgabe oben.');
}

if (produced.length < shots.length) {
  warn(`${produced.length} von ${shots.length} Screenshots — die übrigen bitte prüfen.`);
}

step('Play-Anforderungen an Screenshots');
for (const f of produced) {
  const size = statSync(join(SHOT_DIR, f)).size / 1024;
  info(`${f}  ${(size / 1024).toFixed(2)} MB`);
}
info('Hochladen: Grow users → Main store listing → Graphics → Phone screenshots');
info('Erlaubt: 16:9 quer (1280×720 passt), max. 8 Stück, min. 2, JPEG oder 24-Bit PNG.');

done(`${produced.length} Screenshots in ${SHOT_DIR}`);

/**
 * Normalises externally taken screenshots to what Play expects: 16:9
 * landscape, 1280×720, PNG without alpha, letterboxed rather than cropped
 * (cropping would cut off HUD elements, which Play's own review dislikes).
 */
function importShots(dir) {
  step(`Screenshots importieren aus ${dir}`);
  if (!dir || !existsSync(dir)) abort(`Verzeichnis ${dir} existiert nicht.`);
  if (!which('convert')) abort('ImageMagick convert fehlt —-normalisieren nicht möglich.');
  if (existsSync(SHOT_DIR)) for (const f of readdirSync(SHOT_DIR)) unlinkSync(join(SHOT_DIR, f));
  ensureDir(SHOT_DIR);

  const files = readdirSync(dir).filter((f) => ['.png', '.jpg', '.jpeg'].includes(extname(f).toLowerCase()));
  if (files.length === 0) abort(`Keine Bilddateien in ${dir}.`);
  if (files.length > 8) warn(`${files.length} Bilder — Play nimmt höchstens 8 pro Gerätetyp.`);

  files.sort();
  for (const [i, f] of files.entries()) {
    const src = join(dir, f);
    const out = join(SHOT_DIR, `${String(i + 1).padStart(2, '0')}-${basename(f, extname(f))}.png`);
    // -extent pads to the exact canvas, centred, with the project's background
    // colour (0.031, 0.047, 0.086) instead of black bars.
    const res = tryRun('convert', [
      src,
      '-background', '#080c16',
      '-gravity', 'center',
      '-resize', '1280x720>',
      '-extent', '1280x720',
      '-alpha', 'off',
      out,
    ]);
    if (res.code !== 0) {
      fail(`${f}: convert fehlgeschlagen`);
      continue;
    }
    const dims = tryRun('identify', ['-format', '%wx%h %[channels]', out]);
    ok(`${basename(out)}  ${dims.out.trim()}  ${(statSync(out).size / 1024).toFixed(0)} KB`);
  }

  step('Play-Anforderungen');
  const count = readdirSync(SHOT_DIR).filter((f) => f.endsWith('.png')).length;
  if (count >= 2) ok(`${count} Screenshots (Play verlangt mindestens 2 über verschiedene Gerätetypen, 3+ empfohlen)`);
  else fail(`Nur ${count} — Play verlangt mindestens zwei.`);
  ok('Format 1280×720 = 16:9 quer, das empfohlene Format für Spiele.');
  ok('PNG 24-Bit ohne Alpha — von Play akzeptiert.');
  warn('Screenshots müssen das echte Spiel zeigen, keine Mock-ups, keine Geräte-Rahmen.');
  warn('Keine Text-Overlays mit Claims ("Best", "#1", "Jetzt laden").');
  done(`${count} Screenshots normalisiert in ${SHOT_DIR}`);
}
