#!/usr/bin/env node
/**
 * Runs the headless Godot suite, optionally scoped to one or more scopes.
 *
 *   npm run test:game                          # alles (Merge-Gate)
 *   npm run test:game -- --scope pang          # nur Pangs Suiten + Screens
 *   npm run test:game -- --scope tetris,pang
 *   npm run test:game -- --scope meshes
 *   npm run test:game -- --isolated            # in einem eigenen Worktree
 *
 * Why a wrapper instead of passing `--only` straight to Godot: the mapping from
 * "a game" to "the test suites that cover it" lives in `scripts/scopes.mjs`, the
 * same manifest that decides file ownership. One source of truth means a game
 * agent cannot end up testing the wrong thing because a list drifted.
 *
 * `--full` forces the complete catalogue even when a scope is given.
 *
 * `--isolated` runs the suite in a throwaway worktree instead of the shared
 * tree. Measured cost: 11 s of import, 113 MB, and in exchange the run tests a
 * snapshot instead of a moving target. That is not a small thing: a suite that
 * starts in a shared tree can read a file another session rewrote halfway
 * through, and the failure it reports then belongs to somebody else — one
 * measured here was a parse error that surfaced ten minutes in, in a test file
 * another agent had committed to three minutes before.
 */
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildScopes, testArgs, gameIds } from './scopes.mjs';
import { importGodot } from './worktree.mjs';

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

/**
 * `--isolated`: a worktree of HEAD, so the suite sees the committed state and
 * nothing else. Detached, in a temp directory, removed again — nothing about it
 * survives the run, which is the point: it is a measuring instrument, not a
 * lane. The import is the price of admission and is reported, because 11 s that
 * looks like a hang is how a tool teaches its user to distrust it.
 */
const isolated = argv.includes('--isolated');
let runRoot = root;
let isoDir = null;
if (isolated) {
  isoDir = mkdtempSync(join(tmpdir(), 's80-verify-'));
  const added = spawnSync('git', ['-C', root, 'worktree', 'add', '--detach', isoDir, 'HEAD'], { encoding: 'utf8' });
  if (added.status !== 0) {
    console.error(`[test:game] Worktree nicht anlegbar: ${(added.stderr ?? '').trim() || added.error?.message}`);
    process.exit(1);
  }
  const imported = importGodot(isoDir, { log: (line) => console.log(`[test:game] ${line}`) });
  if (!imported.ok) {
    console.error(`[test:game] Import im Worktree fehlgeschlagen: ${imported.reason}`);
    spawnSync('git', ['-C', root, 'worktree', 'remove', '--force', isoDir]);
    process.exit(1);
  }
  runRoot = isoDir;
  console.log(`[test:game] isoliert in ${isoDir}`);
}

const cmd = spawnSync(
  'godot',
  ['--headless', '--path', 'godot', '--script', 'res://tests/run_tests.gd', '--', ...godotArgs],
  {
    cwd: runRoot,
    stdio: 'inherit',
    env: { ...process.env, XDG_DATA_HOME: userHome },
    timeout: budgetSeconds * 1000,
    killSignal: 'SIGKILL',
  },
);

const cleanup = () => {
  if (keep) console.log(`[test:game] User-Daten behalten: ${userHome}`);
  else rmSync(userHome, { recursive: true, force: true });
  if (isoDir) {
    // `git worktree remove` also drops the admin entry under `.git/worktrees`;
    // deleting the directory alone would leave that behind until the next
    // `git worktree prune`, and `list` would report a checkout that is gone.
    spawnSync('git', ['-C', root, 'worktree', 'remove', '--force', isoDir]);
    rmSync(isoDir, { recursive: true, force: true });
  }
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
