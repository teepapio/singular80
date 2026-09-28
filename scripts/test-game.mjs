#!/usr/bin/env node
/**
 * Runs the headless Godot suite, optionally scoped to one or more scopes.
 *
 *   npm run test:game                          # alles (Merge-Gate)
 *   npm run test:game -- --scope pang          # nur Pangs Suiten + Screens
 *   npm run test:game -- --scope tetris,pang
 *   npm run test:game -- --scope meshes
 *
 * Why a wrapper instead of passing `--only` straight to Godot: the mapping from
 * "a game" to "the test suites that cover it" lives in `scripts/scopes.mjs`, the
 * same manifest that decides file ownership. One source of truth means a game
 * agent cannot end up testing the wrong thing because a list drifted.
 *
 * `--full` forces the complete catalogue even when a scope is given.
 */
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildScopes, testArgs, gameIds } from './scopes.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

const argv = process.argv.slice(2);
const flag = (name) => {
  const i = argv.indexOf(`--${name}`);
  if (i === -1) return null;
  const eq = argv[i].includes('=');
  if (eq) return argv[i].split('=').slice(1).join('=');
  return argv[i + 1] ?? '';
};

const scopes = buildScopes();
const raw = flag('scope');
const names = raw ? raw.split(',').map((s) => s.trim()).filter(Boolean) : [];
const full = argv.includes('--full');

if (raw && names.some((n) => !scopes.has(n))) {
  const known = [...scopes.keys()].join(', ');
  console.error(`Unbekannter Scope. Bekannt: ${known}`);
  process.exit(2);
}

let godotArgs = [];
let label = 'vollständig';
if (names.length && !full) {
  const { args, suites, screens: scr } = testArgs(names, scopes);
  godotArgs = args;
  label = `${names.join(', ')} → ${suites.length} Suite(n), ${scr.length} Screen(s)`;
  if (!suites.length && !scr.length) {
    console.error(`Scope '${names.join(', ')}' ist auf keine Tests abgebildet.`);
    console.error('Das ist ein Fehler im Manifest — Scope ergänzen oder Suite schreiben.');
    process.exit(2);
  }
}

/**
 * Every run gets a private Godot user-data directory.
 *
 * Without this the suite writes to the player's real save: several tests call
 * `Game.submit_score`, `Pang.unlock_level` and friends, which rewrite
 * `user://singular80.cfg`. Two concurrent runs then race on that
 * read-modify-write, and a green run silently clobbers real progress. Godot has
 * no `--user-data-dir` flag, but on Linux it derives the path from
 * `XDG_DATA_HOME`, so overriding that is enough.
 */
const userHome = mkdtempSync(join(tmpdir(), 's80-test-'));
mkdirSync(join(userHome, 'godot', 'app_userdata'), { recursive: true });
const keep = argv.includes('--keep-userdata');

/**
 * A wall-clock ceiling. Without it a suite that fails to *compile* leaves the
 * SceneTree running forever, because the crash happens before `quit()`.
 */
const budgetSeconds = Number(flag('timeout') ?? (names.length && !full ? 240 : 900));
const cmd = spawnSync(
  'godot',
  ['--headless', '--path', 'godot', '--script', 'res://tests/run_tests.gd', '--', ...godotArgs],
  {
    cwd: root,
    stdio: 'inherit',
    env: { ...process.env, XDG_DATA_HOME: userHome },
    timeout: budgetSeconds * 1000,
    killSignal: 'SIGKILL',
  },
);

const cleanup = () => {
  if (keep) console.log(`[test:game] User-Daten behalten: ${userHome}`);
  else rmSync(userHome, { recursive: true, force: true });
};
cleanup();

if (cmd.error) {
  const message = cmd.error.message ?? '';
  if (message.includes('ETIMEDOUT')) {
    console.error(`\n[test:game] ABBRUCH nach ${budgetSeconds}s — eine Suite hängt oder konnte nicht kompilieren.`);
    console.error('[test:game] Häufigste Ursache: ein Screen-Skript mit Parse-Fehler, dann läuft der SceneTree ohne quit().');
    process.exit(124);
  }
  console.error(`[test:game] godot nicht gefunden: ${message}`);
  process.exit(127);
}
console.log(`\n[test:game] Umfang: ${label}`);
process.exit(cmd.status ?? 1);
