#!/usr/bin/env node
/**
 * Runs only the checks a change can actually reach.
 *
 *   node scripts/test-affected.mjs                 # working tree vs HEAD
 *   node scripts/test-affected.mjs --staged        # only what is staged
 *   node scripts/test-affected.mjs a.gd b.json     # these files
 *   node scripts/test-affected.mjs --base main~1  # everything since that commit
 *   node scripts/test-affected.mjs --dry-run       # print the plan, run nothing
 *   node scripts/test-affected.mjs --full          # the complete catalogue
 *
 * Why this exists: an agent that changed `godot/src/game/tetris/**` was told to
 * run `npm run typecheck`, `npm test` and the game suite. Measured on this tree
 * on 2026-10-02: 3 s + 24 s + 42 s = 69 s, of which 66 s said nothing about
 * Tetris — nine suites said it in 6 s. The reflex was not stupidity, the prompt
 * asked for it, and the fix is a tool that answers "what does this change
 * reach?" in one command, the way `scopes.mjs scope-for` answers "whose files
 * are these?".
 *
 * The two catalogue checks (`sync-content --check`, `locale check`) always run.
 * They cost 0.4 s together and they are the only thing that notices a mirror
 * that drifted from its source — the failure mode of every tool in this
 * repository that writes a file another tool reads.
 *
 * What is deliberately *not* narrowed: `vitest related` follows the module graph
 * through static imports only, and this tree loads its own `scripts/*.mjs`
 * through `createRequire` and reads JSON at runtime. `vitest related
 * server/changelog.ts` reports fourteen suites on this tree, three of them by
 * accident, and a file reached only through a runtime path reports none at all
 * — that is a green run which checked nothing. So a TypeScript change still runs
 * the whole Node suite (24 s). The half that really divides is the Godot one,
 * 42 s, and that is where the scope manifest earns its keep.
 *
 * The full run is not gone, it has a home: `npm run test:full`, which the APK
 * build (`npm run godot:apk*`) runs before it exports. A change that reaches no
 * scope at all says so instead of pretending to be verified.
 */
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildScopes, scopesForFiles, testCommand } from './scopes.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

/** Files every suite in the tree can see, so one of them means the whole Node suite. */
const FORCE_ALL_VITEST = new Set(['package.json', 'package-lock.json', 'vitest.config.ts', 'tsconfig.json', 'vite.config.ts']);

/**
 * Node suites that cover exactly one area, and the Godot scope that goes with
 * them. A content pack is checked by two Node suites and the `content` suites
 * that parse it; a catalogue by one Node suite and the sixteen language suites
 * of `core`, which run in no other scope.
 */
const VITEST_BY_AREA = [
  {
    name: 'content',
    prefix: ['content/', 'godot/assets/content/'],
    tests: ['tests/content.test.ts', 'tests/contentStore.test.ts'],
    scopes: ['content'],
  },
  {
    name: 'locale',
    prefix: ['locale/', 'godot/assets/locale/'],
    files: ['scripts/locale.mjs', 'scripts/locale.d.mts'],
    tests: ['tests/locale.test.ts'],
    scopes: ['core'],
  },
];

/**
 * The foundation every screen is built on: a change here can break any game,
 * and the suite that proves it — the `Screens` sweep — belongs to no scope at
 * all. `agent-ui.md` has said for a while that a base-class change is not done
 * when only `core` is green; this is where that sentence becomes a command
 * instead of a thing to remember.
 */
const FOUNDATION = /^(godot\/src\/core\/(ui|autoload)\/|godot\/src\/main\.gd$|godot\/main\.tscn$|godot\/project\.godot$|godot\/tests\/(run_tests|test_kit)\.gd$)/;

/**
 * Godot files no scope claims that also cannot change what a game does: an
 * imported asset, a `.uid` sibling, the scene shell. Running 42 s of catalogue
 * for one of these teaches nothing.
 */
const UNCLAIMED_HARMLESS = /^(godot\/.*\.uid|godot\/.*\.import|godot\/.*\.tscn|godot\/assets\/fonts\/.*|godot\/assets\/meshes\/lod\.json)$/;

/** Does this change touch the area a group of Node suites covers? */
function areaHit(area, files) {
  return files.some((f) => area.prefix.some((p) => f.startsWith(p)) || (area.files ?? []).includes(f));
}

/** The files a run should judge: explicit names, or the difference against a base. */
export function changedFiles({ files = [], staged = false, base = null, cwd = root } = {}) {
  if (files.length) return [...new Set(files)];
  const git = (args) => {
    const res = spawnSync('git', ['-C', cwd, ...args], { encoding: 'utf8' });
    return res.status === 0 ? (res.stdout ?? '').split('\n').map((s) => s.trim()).filter(Boolean) : null;
  };
  const out = [
    ...(git(['diff', '--name-only', staged ? '--cached' : 'HEAD']) ?? []),
    ...(git(['ls-files', '--others', '--exclude-standard']) ?? []),
  ];
  if (base) {
    // HEAD against the base as well, so a change that is already committed is
    // still visible to the plan — that is the case the gate cares about.
    out.push(...(git(['diff', '--name-only', base, 'HEAD']) ?? []));
  }
  return [...new Set(out)].sort();
}

/**
 * The plan: which commands prove this change, in the cheap order.
 *
 * `full` is the escape hatch and the APK build's mode — the complete catalogue
 * whatever changed, which is what a release wants and an agent does not need.
 *
 * The Godot half has three outcomes and the middle one is the point of the tool:
 * a change inside a game runs that game's suites, a change in a file nobody
 * owns runs the full catalogue, and a change that touches no game at all runs no
 * Godot test instead of all 42 seconds of one.
 */
export function affectedSteps(files, { full = false, hasNodeModules = true, scopes = buildScopes() } = {}) {
  if (full) return fullSteps(hasNodeModules);

  // Always, in every mode: 0.4 s together, and the only thing that notices a
  // mirror that drifted away from the file it was generated from.
  const steps = [
    { name: 'content:check', bin: 'node', args: ['scripts/sync-content.mjs', '--check'], timeout: 60_000, reasons: ['immer: der Spiegel muss zur Quelle passen'] },
    { name: 'locale:check', bin: 'node', args: ['scripts/locale.mjs', 'check'], timeout: 120_000, reasons: ['immer: Kataloge, Platzhalter, Spiegel'] },
  ];
  const add = (step) => {
    const filled = { ...step, reasons: step.reasons ?? [] };
    steps.push(filled);
    return filled;
  };
  const note = (text) => steps.push({ note: text });

  const forced = files.filter((f) => FORCE_ALL_VITEST.has(f));
  const tsFiles = files.filter((f) => /\.(ts|mts|tsx)$/.test(f));

  if (forced.length || (tsFiles.length && hasNodeModules)) {
    // `forced` first, and it wins: a changed `tsconfig.json` is a TypeScript
    // change that also changes what every other TypeScript change means.
    if (hasNodeModules) {
      add({
        name: 'typecheck',
        bin: 'npx',
        args: ['tsc', '--noEmit'],
        timeout: 600_000,
        reasons: forced.length ? [`${forced.join(', ')} liegt in tsconfig.json`] : [`${tsFiles.length} TypeScript-Datei(en)`],
      });
      add({
        name: 'npm test',
        bin: 'npm',
        args: ['test'],
        timeout: 900_000,
        reasons: forced.length
          ? [`${forced.join(', ')} ändert, worauf sich jede Suite verlässt`]
          // Said in the source of this file: `vitest related` follows static
          // imports, and this tree reaches its own scripts through
          // `createRequire` and JSON at runtime.
          : ['TypeScript geändert — der Node-Teil läuft ganz, `vitest related` kennt die createRequire-Wege nicht'],
      });
    }
  } else {
    const tests = [...new Set(VITEST_BY_AREA.filter((area) => areaHit(area, files)).flatMap((area) => area.tests))];
    if (tests.length && hasNodeModules) {
      add({ name: 'npm test (gezielt)', bin: 'npx', args: ['vitest', 'run', ...tests], timeout: 900_000, reasons: tests });
    }
  }

  const godotFiles = files.filter((f) => f.startsWith('godot/'));
  const { own, shared, unowned } = godotFiles.length
    ? scopesForFiles(godotFiles, scopes)
    : { own: new Map(), shared: [], unowned: [] };
  const foundation = files.filter((f) => FOUNDATION.test(f));
  const areas = VITEST_BY_AREA.filter((area) => areaHit(area, files));
  const orphans = unowned.filter((f) => !UNCLAIMED_HARMLESS.test(f));
  const names = [...new Set([...own.keys(), ...areas.flatMap((area) => area.scopes ?? [])])];

  if (foundation.length || shared.length || orphans.length) {
    const step = add({ name: 'Spieltests', bin: 'node', args: ['scripts/test-game.mjs'], timeout: 1_200_000, reasons: [] });
    step.reasons = [
      foundation.length ? `${foundation[0]} ist Fundament — jeder Screen baut darauf auf` : '',
      shared.length ? `${shared.join(', ')} ist geteilte Fläche` : '',
      orphans.length ? `${orphans.join(', ')} gehört keinem Spiel` : '',
    ].filter(Boolean);
  } else if (names.length) {
    const plan = testCommand(names, scopes);
    if (plan) {
      add({
        name: `Spieltests (${names.join(', ')})`,
        bin: 'node',
        args: ['scripts/test-game.mjs', '--scope', names.join(',')],
        timeout: 600_000,
        suites: plan.suites,
        screens: plan.screens,
        reasons: [...own.values(), ...areas.map((area) => area.name)].flat().slice(0, 3),
      });
    }
  }
  if (unowned.length && !orphans.length) {
    note(`${unowned.join(', ')} — herrenlos, aber ohne Wirkung auf ein Spiel.`);
  }
  return steps;
}

/** The complete catalogue: what a release proves, what no agent has to. */
export function fullSteps(hasNodeModules) {
  const steps = [
    { name: 'content:check', bin: 'node', args: ['scripts/sync-content.mjs', '--check'], timeout: 60_000, reasons: ['immer: der Spiegel muss zur Quelle passen'] },
    { name: 'locale:check', bin: 'node', args: ['scripts/locale.mjs', 'check'], timeout: 120_000, reasons: ['immer: Kataloge, Platzhalter, Spiegel'] },
  ];
  if (hasNodeModules) {
    steps.push(
      { name: 'typecheck', bin: 'npx', args: ['tsc', '--noEmit'], timeout: 600_000, reasons: ['voll'] },
      { name: 'npm test', bin: 'npm', args: ['test'], timeout: 900_000, reasons: ['voll'] },
    );
  }
  steps.push({ name: 'Spieltests', bin: 'node', args: ['scripts/test-game.mjs'], timeout: 1_200_000, reasons: ['voll'] });
  return steps;
}

/** Runs the plan in order and stops at the first red step. */
export function runSteps(steps, { cwd = root, log = console.log } = {}) {
  for (const step of steps) {
    if (step.note) {
      log(`  ${step.note}`);
      continue;
    }
    log(`\n▸ ${step.name}${step.suites !== undefined ? `  (${step.suites} Suite(n), ${step.screens} Screen(s))` : ''}`);
    if (step.reasons?.length) log(`  ${step.reasons.join(' · ')}`);
    const res = spawnSync(step.bin, step.args, { cwd, stdio: 'inherit', timeout: step.timeout ?? 600_000, killSignal: 'SIGKILL' });
    if (res.status !== 0) return { ok: false, step };
  }
  return { ok: true, step: null };
}

function main(argv) {
  const full = argv.includes('--full');
  const dry = argv.includes('--dry-run');
  const baseAt = argv.findIndex((a) => a === '--base' || a.startsWith('--base='));
  const base = baseAt === -1 ? null : (argv[baseAt].includes('=') ? argv[baseAt].split('=')[1] : argv[baseAt + 1]);
  const skip = new Set([baseAt, baseAt === -1 ? -1 : baseAt + 1]);
  const explicit = argv.filter((a, i) => !a.startsWith('--') && !skip.has(i));
  const files = changedFiles({ files: explicit, staged: argv.includes('--staged'), base });
  const steps = affectedSteps(files, { full, hasNodeModules: existsSync(join(root, 'node_modules')) });

  if (!files.length && !steps.length) {
    console.log('[test:affected] Keine geänderten Dateien — nichts zu prüfen.');
    return 0;
  }
  console.log(`[test:affected] ${files.length} geänderte Datei(en), ${steps.filter((s) => s.bin).length} Schritt(e)${full ? ' (voll)' : ''}\n`);
  for (const step of steps) {
    if (step.note) { console.log(`  ~ ${step.note}`); continue; }
    console.log(`  ${step.bin} ${step.args.join(' ')}${step.suites !== undefined ? `    # ${step.suites} Suite(n), ${step.screens} Screen(s)` : ''}`);
  }
  if (!steps.some((s) => s.bin)) console.log('  (nichts — keine dieser Dateien erreicht einen Test)');
  console.log('');
  if (dry) return 0;
  const res = runSteps(steps);
  if (!res.ok) {
    console.error(`\n[test:affected] ${res.step.name} ist rot.`);
    console.error('[test:affected] Der volle Lauf beweist mehr: node scripts/test-affected.mjs --full');
    return 1;
  }
  console.log('\n[test:affected] Alles grün.');
  return 0;
}

if (process.argv[1] && process.argv[1].endsWith('test-affected.mjs')) {
  process.exit(main(process.argv.slice(2)));
}