#!/usr/bin/env node
/**
 * Installs the Godot Android build template into `godot/android/`.
 *
 * Godot expects the Gradle project at `res://android/build` (the editor does
 * this when you pick "Project ▸ Install Android Build Template"). The template
 * ships with the export templates, so a fresh clone can set itself up with:
 *
 *   npm run godot:android-template
 *
 * The whole thing is idempotent and safe to re-run; it never touches anything
 * outside `godot/android/`.
 */
import { existsSync, mkdirSync, cpSync, writeFileSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { readFileSync } from 'node:fs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const androidDir = join(root, 'godot', 'android');
const buildDir = join(androidDir, 'build');

/** Matches the editor's build, read from the engine binary. */
function detectVersion() {
  try {
    const out = execFileSync('godot', ['--version'], { encoding: 'utf8' });
    return out.trim().split(' ')[1] ?? '4.5.1.stable';
  } catch {
    return '4.5.1.stable';
  }
}

const version = process.env.GODOT_VERSION || detectVersion();
const candidates = [
  join(process.env.HOME ?? '', '.local/share/godot/export_templates', version, 'android_source.zip'),
  join(process.env.HOME ?? '', '.local/share/godot/export_templates', version.replace(/\.stable$/, ''), 'android_source.zip'),
];

const zip = candidates.find((path) => existsSync(path));
if (!zip) {
  console.error(`[android-template] Keine Export-Vorlage für ${version} gefunden.`);
  console.error('[android-template] Lade sie herunter von https://godotengine.org/download/archive');
  process.exit(1);
}

mkdirSync(buildDir, { recursive: true });

// Unpack into a scratch directory first: the archive has no top-level folder, so
// unpacking straight into godot/ would scatter files over the project.
const scratch = join(tmpdir(), `godot-android-template-${process.pid}`);
cpSync(zip, `${scratch}.zip`);
execFileSync('unzip', ['-q', '-o', `${scratch}.zip`, '-d', scratch]);

// The template is a Gradle project; the marker file tells Godot's editor that the
// build directory must be ignored by the project filesystem scan.
const entries = readdirSync(scratch, { withFileTypes: true });
for (const entry of entries) {
  cpSync(join(scratch, entry.name), join(buildDir, entry.name), { recursive: true, force: true });
}
writeFileSync(join(androidDir, '.build_version'), `${version}\n`);
writeFileSync(join(buildDir, '.gdignore'), '');

execFileSync('rm', ['-rf', scratch, `${scratch}.zip`]);

const gradle = join(buildDir, 'gradle', 'wrapper', 'gradle-wrapper.properties');
const distribution = readFileSync(gradle, 'utf8').match(/distributionUrl=.*gradle-([\d.]+)-bin/)?.[1] ?? '?';
console.log(`[android-template] Godot ${version} → godot/android/build (Gradle ${distribution})`);
