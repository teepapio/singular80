/**
 * Shared helpers for the googleplay/* scripts.
 *
 * Deliberately dependency free (no npm install needed) and side effect free:
 * every script in this folder is safe to run and reports its own status.
 */
import { existsSync, readFileSync, readdirSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const HERE = dirname(fileURLToPath(import.meta.url));
export const PROJECT = resolve(HERE, '..');
/** The Singular 80 Godot project. Everything Play-related writes into it. */
export const REPO = resolve(PROJECT, '..');
export const GODOT_DIR = join(REPO, 'godot');
export const PRESETS = join(GODOT_DIR, 'export_presets.cfg');
export const BUILD_DIR = join(PROJECT, 'build');
export const ASSET_DIR = join(PROJECT, 'assets');
export const SHOT_DIR = join(BUILD_DIR, 'screenshots');
export const TOOL_DIR = join(BUILD_DIR, 'tools');

/** bundletool is the only reliable way to read a protobuf AAB manifest. */
export const BUNDLETOOL_VERSION = '1.18.1';
// Google's Maven mirror, not repo1.maven.org: the Android tooling is published
// here and repo1 is not always reachable from a build machine.
export const BUNDLETOOL_URL =
  `https://dl.google.com/dl/android/maven2/com/android/tools/build/bundletool/${BUNDLETOOL_VERSION}/bundletool-${BUNDLETOOL_VERSION}.jar`;
export const bundletool = () => join(TOOL_DIR, `bundletool-${BUNDLETOOL_VERSION}.jar`);

/** Godot's gradle build writes the merged manifest as plain XML. */
export const ANDROID_BUILD = join(GODOT_DIR, 'android', 'build', 'build');

/** Name of the export preset this project owns inside godot/export_presets.cfg. */
export const PRESET_NAME = 'Google Play (AAB)';

export function config() {
  return JSON.parse(readFileSync(join(PROJECT, 'config', 'app.json'), 'utf8'));
}

let quiet = false;
export function silence() {
  quiet = true;
}

function say(line) {
  if (!quiet) console.log(line);
}

export const ok = (m) => say(`  [32m✓[0m ${m}`);
export const info = (m) => say(`  · ${m}`);
export const warn = (m) => say(`  [33m![0m ${m}`);
export const fail = (m) => say(`  [31m✗[0m ${m}`);
export const step = (m) => say(`\n[1m${m}[0m`);

export function done(message) {
  say(`\n[32m${message}[0m\n`);
  process.exit(0);
}

export function abort(message, code = 1) {
  fail(message);
  process.exit(code);
}

/** True when the value is still one of the `TODO:` placeholders. */
export function isTodo(value) {
  if (Array.isArray(value)) return value.some((v) => typeof v === 'string' && v.trim().startsWith('TODO:'));
  return typeof value === 'string' && (value.trim() === '' || value.trim().startsWith('TODO:'));
}

/** Every `TODO:` placeholder in config/app.json, as `{ path, value }`. */
export function listTodos() {
  const out = [];
  const walk = (node, path) => {
    for (const [key, value] of Object.entries(node)) {
      if (key.startsWith('$comment')) continue;
      const next = path ? `${path}.${key}` : key;
      if (value && typeof value === 'object' && !Array.isArray(value)) walk(value, next);
      else if (isTodo(value)) out.push({ path: next, value });
    }
  };
  walk(config(), '');
  return out;
}

export function run(cmd, args, opts = {}) {
  return execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], ...opts });
}

export function tryRun(cmd, args, opts = {}) {
  try {
    return { code: 0, out: run(cmd, args, opts) };
  } catch (err) {
    return { code: err.status ?? 1, out: `${err.stdout ?? ''}${err.stderr ?? ''}` };
  }
}

export function which(cmd) {
  const res = tryRun('sh', ['-c', `command -v ${cmd}`]);
  return res.code === 0 ? res.out.trim() : null;
}

export function ensureDir(dir) {
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  return dir;
}

/** Godot's own version string, e.g. `4.5.1.stable.official.f62fdbde1`. */
export function godotVersion() {
  const res = tryRun('godot', ['--version']);
  return res.code !== 0 ? null : res.out.trim();
}

export function androidSdkRoot() {
  const candidates = [
    process.env.ANDROID_HOME,
    process.env.ANDROID_SDK_ROOT,
    process.env.HOME ? join(process.env.HOME, 'Android', 'Sdk') : null,
    process.env.HOME ? join(process.env.HOME, 'android-sdk') : null,
  ].filter(Boolean);
  return candidates.find((dir) => existsSync(join(dir, 'platform-tools'))) ?? null;
}

/** Path to `sdkmanager`, or null when the Android command line tools are missing. */
export function sdkmanager() {
  const root = androidSdkRoot();
  if (!root) return null;
  const direct = join(root, 'cmdline-tools', 'latest', 'bin', 'sdkmanager');
  if (existsSync(direct)) return direct;
  const tools = join(root, 'cmdline-tools');
  if (!existsSync(tools)) return null;
  for (const entry of readdirSync(tools)) {
    const candidate = join(tools, entry, 'bin', 'sdkmanager');
    if (existsSync(candidate)) return candidate;
  }
  return null;
}
