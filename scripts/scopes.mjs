#!/usr/bin/env node
/**
 * Scope manifest and pre-commit guard for parallel agents.
 *
 * The whole point: every file an agent is allowed to touch belongs to exactly
 * one scope. The runner starts a second agent in the same tree, so without an
 * exclusive ownership rule `git add -A` sweeps up a stranger's work and a
 * generated asset can be committed by whoever commits first.
 *
 *   node scripts/scopes.mjs list
 *   node scripts/scopes.mjs check tetris            # staged files vs scope
 *   node scripts/scopes.mjs check tetris,pang --staged
 *   node scripts/scopes.mjs explain godot/src/core/logic/asset_registry.gd
 *
 * A scope may claim `own` (private to it) and `shared` (files every agent
 * touches). Shared files are allowed but reported loudly, because they are the
 * places two agents genuinely collide.
 */
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

/**
 * Every game agent touches these. Listing them keeps the guard honest.
 *
 * The central test files are here rather than in a game's `own`: a game agent
 * does write rules tests, and hiding that would make the manifest wrong rather
 * than make the collision go away. It gets its own `godot/tests/test_<id>.gd`
 * instead, which nobody else claims.
 */
export const SHARED_FILES = [
  'godot/src/core/logic/asset_registry.gd',
  'godot/src/core/logic/game_registry.gd',
  'godot/src/core/autoload/router.gd',
  'godot/src/core/autoload/game_state.gd',
  'godot/assets/meshes/lod.json',
  'godot/tests/run_tests.gd',
  'godot/tests/test_logic.gd',
  'godot/tests/test_screens.gd',
  'godot/tests/test_improvements.gd',
  'package.json',
  'opencode.json',
  'AGENTS.md',
];

/**
 * Logic modules a game owns outright. Games without an entry either share a
 * generic module (cards, checkers, twenty48) or keep their rules in the screen.
 */
const GAME_LOGIC = {
  arena: ['godot/src/core/logic/arena_runs.gd'],
  tetris: ['godot/src/core/logic/tetris_rules.gd'],
  poker: ['godot/src/core/logic/holdem.gd'],
  freecell: ['godot/src/core/logic/cards.gd'],
  dame: ['godot/src/core/logic/checkers.gd'],
  '2048': ['godot/src/core/logic/twenty48.gd'],
  crystal3d: ['godot/src/core/logic/crystal_tower.gd'],
  'merge3d-christmas': ['godot/src/core/logic/merge3d.gd'],
  dragonrpg: ['godot/src/core/logic/dragon_rpg.gd'],
  dragonflight: ['godot/src/core/logic/dragon_flight.gd'],
  horserunner: ['godot/src/core/logic/horse_runner.gd'],
  pang: ['godot/src/core/logic/pang.gd'],
  metro3d: ['godot/src/core/logic/metro.gd'],
  candy3d: ['godot/src/core/logic/candy_match3.gd'],
  siedler: ['godot/src/core/logic/siedler.gd'],
};

/**
 * Registry entries that reuse another game's screen and logic module. They are
 * lobby entries and content themes, not separate code bases, so they resolve to
 * the base scope instead of claiming ownership a second time.
 */
const VARIANT_BASE = {
  'crystal3d-christmas': 'crystal3d',
  'crystal3d-halloween': 'crystal3d',
  'merge3d-christmas': 'merge3d',
  'merge3d-halloween': 'merge3d',
};

/**
 * The test suites each scope owns. This is what lets a game agent verify only
 * its own game: `npm run test:game -- --scope tetris` resolves to exactly the
 * suites listed here, and `validate()` fails if a name no longer exists in the
 * test files, so the mapping cannot rot silently.
 *
 * The `Screens` sweep is driven separately, by `screens` below.
 */
const SCOPE_SUITES = {
  arena: ['PlayerStats', 'Arena — Spielablauf', 'Arena — Wellenvorschau', 'Arena — Kill-Ketten', 'Arena — Dash'],
  tetris: ['Tetris — Eingabe', 'Tetris — Punktewertung', 'Tetris — T-Spin-Erkennung',
    'Tetris — Vorschaukette', 'Tetris — Brettgefahr'],
  poker: ['Karten & Texas Hold\'em', 'Kartenspiele — Eingabe',
    'Poker — Persönlichkeiten', 'Poker — Tisches lesen', 'Poker — Typen-Bilanz'],
  freecell: ['Kartenspiele — Eingabe'],
  dame: ['Dame — Regeln', 'Dame — Schlagzug-Analyse', 'Dame — Ziehbare Steine', 'Dame — Tipp am Brett'],
  crystal3d: ['Crystal Tower', 'Crystal Tower — Flusskette', 'Crystal Tower — Flusspunkte',
    'Crystal Tower — Screen'],
  merge3d: ['Merge 3D'],
  horserunner: ['Pferde-Parcours', 'Pferde-Parcours — Beinahe-Treffer', 'Pferde-Parcours — Kette'],
  dragonrpg: ['Drachen-RPG', 'Drachen-RPG — Loot-Rarität'],
  dragonflight: [
    'Drachenflug — Stammdaten', 'Drachenflug — Vererbung', 'Drachenflug — Zuchtvorhersage',
    'Drachenflug — Elemente', 'Drachenflug — Werte', 'Drachenflug — Profil & Zucht',
    'Drachenflug — Allele', 'Drachenflug — Blutbild', 'Drachenflug — Zuchtziel',
    'Drachenflug — Beste Paarung', 'Drachenflug — Ei-Vorschau',
  ],
  pang: ['Pang', 'Pang — Treffer', 'Pang — Doppelgriff', 'Pang — Kugelbudget'],
  metro3d: [
    'Metropol 3D — Regeln', 'Metropol 3D — Netz', 'Metropol 3D — Wirtschaft',
    'Metropol 3D — Screen', 'Metropol 3D — Linienbau', 'Metropol 3D — Spielablauf',
    'Metropol 3D — Bedarfsprognose', 'Metropol 3D — Fehlende Linien',
    'Metropol 3D — Berufsverkehrs-Prognose', 'Metropol 3D — Anschluss-Marker',
  ],
  '2048': ['2048'],
  candy3d: [
    'Candy Crush — Reihen', 'Candy Crush — Züge', 'Candy Crush — Spezialbonbons',
    'Candy Crush — Blöcke', 'Candy Crush — Schwerkraft', 'Candy Crush — Level-Generator',
    'Candy Crush — Level', 'Candy Crush — Tageslevel', 'Candy Crush — Belohnungen',
    'Candy Crush — Undo', 'Candy Crush — Spielablauf',
  ],
  siedler: ['Siedler — Insel', 'Siedler — Produktionsketten', 'Siedler — Fahnen und Straßen', 'Siedler — Wirtschaft'],
  meshes: ['Asset-Registry', 'Mesh-Galerie', 'Mesh — Detailstufen', 'Mesh-Galerie — Anordnung',
    'Mesh-Galerie — Merkliste'],
  lobby: ['Lobby-Geometrie', 'Vorschlagsdialog'],
  core: ['Mechaniken', 'Inventar', 'Vorschlag — Herkunft'],
  content: ['Content', 'Content-Integrität', 'Content-Synchronisation'],
  dashboard: [],
  tests: [],
};

/** Screens each scope should open in the integration sweep. */
const SCOPE_SCREENS = {
  arena: ['arena'],
  tetris: ['tetris'],
  poker: ['poker'],
  freecell: ['freecell'],
  dame: ['dame'],
  crystal3d: ['crystal3d', 'crystal3d_christmas', 'crystal3d_halloween'],
  'merge3d-christmas': ['merge3d_christmas', 'merge3d_halloween'],
  horserunner: ['horserunner'],
  dragonrpg: ['dragonrpg'],
  dragonflight: ['dragonflight', 'dragonflight_run', 'dragonflight_hatchery'],
  pang: ['pang', 'pang_menu'],
  metro3d: ['metro3d'],
  '2048': ['g2048'],
  candy3d: ['candy3d'],
  siedler: ['siedler'],
  meshes: [],
  lobby: ['lobby', 'lobby_list'],
  core: [],
  content: [],
  tests: [],
};

/** Every `t.suite("…")` name any test file declares. */
export function allSuites() {
  const out = new Set();
  const dir = join(root, 'godot/tests');
  if (!existsSync(dir)) return out;
  for (const name of readdirSync(dir)) {
    if (!name.startsWith('test_') || !name.endsWith('.gd')) continue;
    const text = readFileSync(join(dir, name), 'utf8');
    for (const m of text.matchAll(/t\.suite\("([^"]+)"\)/g)) out.add(m[1]);
  }
  return out;
}

const read = (p) => readFileSync(join(root, p), 'utf8');

/** game id -> its directory under godot/src/game, derived from the two registries. */
export function gameDirs() {
  const reg = read('godot/src/core/logic/game_registry.gd');
  const rout = read('godot/src/core/autoload/router.gd');
  const screens = new Map(
    [...rout.matchAll(/"([\w]+)":\s*"(res:\/\/src\/game\/[^"]+)"/g)].map((m) => [m[1], m[2]]),
  );
  const out = new Map();
  for (const m of reg.matchAll(/"id":\s*"([^"]+)"[\s\S]*?"screen":\s*"([^"]+)"/g)) {
    const [, id, screen] = m;
    const path = screens.get(screen);
    if (!path) continue;
    out.set(id, path.split('/src/game/')[1].split('/')[0]);
  }
  return out;
}

export function gameIds() {
  return [...gameDirs().keys()];
}

const staticScopes = {
  meshes: {
    agent: 'meshes',
    label: 'Meshes & LOD-Stufen',
    own: [
      'godot/assets/meshes/**',
      'scripts/blender/**',
      'godot/src/core/logic/asset_registry.gd',
    ],
    shared: [],
  },
  dashboard: {
    agent: 'dashboard',
    label: 'Dashboard & Server',
    own: ['server/**', 'src/dashboard/**', 'src/shared/**', 'dashboard.html', 'vite.config.ts', 'index.html'],
    shared: ['package.json'],
  },
  lobby: {
    agent: 'lobby',
    label: 'Lobby & Kategorien',
    own: ['godot/src/game/lobby/**', 'godot/src/core/logic/lobby.gd', 'godot/src/core/logic/mesh_gallery.gd'],
    shared: ['godot/src/core/logic/game_registry.gd', 'godot/src/core/logic/asset_registry.gd'],
  },
  tests: {
    agent: 'build',
    label: 'Test-Harness',
    // Only the harness itself. `godot/tests/test_<spiel>.gd` belongs to the
    // game of that name, so a game agent can add regression tests without two
    // games ever appending to the same file.
    own: ['godot/tests/test_kit.gd', 'vitest.config.ts', 'tsconfig.json', 'tests/**'],
    shared: ['package.json', 'godot/tests/run_tests.gd', 'godot/tests/test_logic.gd',
      'godot/tests/test_screens.gd', 'godot/tests/test_improvements.gd'],
  },
  core: {
    agent: 'build',
    label: 'Kernlogik & Basisklassen',
    own: [
      'godot/src/core/logic/mechanics/**',
      'godot/src/core/logic/player_stats.gd',
      'godot/src/core/logic/item_inventory.gd',
      'godot/src/core/logic/suggestion_context.gd',
      'godot/src/core/ui/**',
      'godot/src/core/autoload/input_setup.gd',
      'godot/src/core/autoload/api_client.gd',
      'godot/src/core/autoload/content_store.gd',
      'godot/src/core/autoload/audio_service.gd',
    ],
    shared: ['godot/src/core/autoload/game_state.gd', 'godot/src/core/logic/game_registry.gd'],
  },
  content: {
    agent: 'game',
    label: 'Content-Packs (Gegner, Waffen, Modi)',
    own: ['content/**'],
    shared: [],
  },
};

function globToRegExp(glob) {
  const escaped = glob.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*\*\//g, '\u0000').replace(/\*\*/g, '\u0001').replace(/\*/g, '[^/]*').replace(/\?/g, '[^/]');
  return new RegExp(`^${escaped.split('\u0000').join('(?:.*/)?').split('\u0001').join('.*')}$`);
}

export function buildScopes() {
  const dirs = gameDirs();
  const scopes = new Map();

  // Basis-Spiele zuerst: jede Variante braucht ihren Basis-Scope, und
  // `merge3d` existiert nur als Variante, nie als Registry-Eintrag.
  const bases = new Set([...dirs.keys()].filter((id) => !VARIANT_BASE[id]));
  for (const base of Object.values(VARIANT_BASE)) bases.add(base);

  for (const base of bases) {
    const dir = dirs.get(base) ?? [...dirs.values()].find((d) => d === base.replace('-', ''))
      ?? [...dirs.values()].find((d) => d.startsWith(base.split('-')[0]));
    if (!dir) continue;
    // A game agent also gets a private test file of its own. That is where new
    // regression tests go, so two games never append to the same suite file.
    // The trailing `*` also claims Godot's `test_<id>.gd.uid`, which is
    // committed like every other script and would otherwise be unownable.
    const own = [
      `godot/src/game/${dir}/**`,
      `godot/tests/test_${base}.gd*`,
      ...(GAME_LOGIC[base] ?? GAME_LOGIC[dir] ?? []),
    ];
    scopes.set(base, {
      agent: 'game',
      label: `Spiel ${base}`,
      dir,
      own,
      suites: SCOPE_SUITES[base] ?? [],
      screens: SCOPE_SCREENS[base] ?? [],
      shared: SHARED_FILES.filter((f) => !own.includes(f)),
    });
  }

  for (const [id, base] of Object.entries(VARIANT_BASE)) {
    if (!scopes.has(base) || !dirs.has(id)) continue;
    scopes.set(id, { ...scopes.get(base), label: `Spiel ${id} (Variante von ${base})`, aliasOf: base });
  }
  for (const [name, def] of Object.entries(staticScopes)) {
    scopes.set(name, {
      ...def,
      own: def.own ?? [],
      shared: def.shared ?? [],
      suites: SCOPE_SUITES[name] ?? [],
      screens: SCOPE_SCREENS[name] ?? [],
    });
  }
  return scopes;
}

/** Flattens scopes to the exact godot arguments a scoped test run needs. */
export function testArgs(names, scopes = buildScopes()) {
  const suites = new Set();
  const screens = new Set();
  for (const n of names) {
    const s = scopes.get(n);
    if (!s) throw new Error(`unbekannter Scope '${n}'`);
    for (const x of s.suites) suites.add(x);
    for (const x of s.screens) screens.add(x);
  }
  return {
    suites: [...suites],
    screens: [...screens],
    args: [
      ...(suites.size ? ['--only', [...suites].join('|')] : []),
      ...(screens.size ? ['--screens', [...screens].join(',')] : []),
    ],
  };
}

export function matchScope(file, scope) {
  for (const glob of scope.own) if (globToRegExp(glob).test(file)) return 'own';
  for (const glob of scope.shared) if (globToRegExp(glob).test(file)) return 'shared';
  return null;
}

export function ownerOf(file, scopes) {
  const hits = [];
  for (const [name, scope] of scopes) {
    const kind = matchScope(file, scope);
    if (kind === 'own') hits.push(name);
  }
  return hits;
}

/** Self-check: the manifest must be unambiguous and must match the repository. */
export function validate(scopes = buildScopes()) {
  const problems = [];
  for (const [name, scope] of scopes) {
    if (!scope.own.length) problems.push(`Scope '${name}' hat keine own-Globs`);
    for (const glob of scope.own) {
      if (glob.endsWith('/**')) {
        // A directory must exist — that is the typo check.
        const dir = glob.slice(0, -3);
        if (!existsSync(join(root, dir))) problems.push(`Scope '${name}': ${dir} existiert nicht`);
        continue;
      }
      // A named file is a *permission*, not a requirement: a game agent is
      // expected to create `godot/tests/test_<id>.gd` the first time it needs
      // one. Only the containing directory is checked, so a typo in the path
      // still shows up.
      const parent = glob.split('/').slice(0, -1).join('/');
      if (parent && !existsSync(join(root, parent))) {
        problems.push(`Scope '${name}': ${parent} existiert nicht (für ${glob})`);
      }
    }
  }
  // Exklusivität: keine Datei darf zwei Scopes gehören. Varianten sind
  // ausgenommen — sie spiegeln bewusst den Basis-Scope.
  const seen = new Map();
  for (const [name, scope] of scopes) {
    if (scope.aliasOf) continue;
    for (const glob of scope.own) {
      if (glob.endsWith('/**')) {
        const dir = glob.slice(0, -3);
        for (const other of seen.keys()) {
          if (other.startsWith(dir) || dir.startsWith(other)) {
            problems.push(`Überschneidung: '${name}' und der Scope für ${other} beanspruchen ${dir}`);
          }
        }
        seen.set(dir, name);
      } else {
        if (seen.has(glob)) problems.push(`Überschneidung: '${name}' und '${seen.get(glob)}' beanspruchen ${glob}`);
        seen.set(glob, name);
      }
    }
  }
  // Jede Suite muss genau einem Scope gehören. Ohne diese Prüfung landet eine
  // Suite in keinem Scope und läuft nur im Volllauf mit — der zuständige Agent
  // merkt seine Regression erst beim Merge.
  const suites = allSuites();
  const claimed = new Map();
  for (const [name, scope] of scopes) {
    if (scope.aliasOf) continue;
    for (const suite of scope.suites ?? []) {
      if (claimed.has(suite) && !SHARED_SUITES.has(suite)) {
        problems.push(`Suite '${suite}' ist doppelt vergeben: '${claimed.get(suite)}' und '${name}'`);
        continue;
      }
      if (!claimed.has(suite)) claimed.set(suite, name);
    }
  }
  for (const suite of suites) {
    if (!claimed.has(suite) && !INFRA_SUITES.has(suite)) {
      problems.push(`Suite '${suite}' gehört zu keinem Scope — sie läuft nur im Volllauf mit`);
    }
  }

  // Jedes Registry-Spiel braucht einen Scope.
  for (const id of gameIds()) if (!scopes.has(id)) problems.push(`Spiel '${id}' hat keinen Scope`);

  // Suite-Zuordnung: jeder Name muss real existieren, sonst testet der Scope
  // still nichts und der Agent glaubt, er sei grün.
  for (const [name, scope] of scopes) {
    for (const suite of scope.suites ?? []) {
      if (!suites.has(suite)) problems.push(`Scope '${name}': Suite '${suite}' existiert nicht in den Tests`);
    }
  }
  return problems;
}

/** Suites that belong to the harness itself rather than to any one scope. */
const INFRA_SUITES = new Set(['Screens', 'Vorschlagsdialog']);

/**
 * Suites that deliberately cover two games at once. The card games share one
 * input suite because they share a screen base; a change to either can break it.
 */
const SHARED_SUITES = new Set(['Kartenspiele — Eingabe']);

function gitStaged() {
  try {
    return execFileSync('git', ['diff', '--cached', '--name-only', 'HEAD'], { cwd: root, encoding: 'utf8' })
      .split('\n').map((s) => s.trim()).filter(Boolean);
  } catch {
    return [];
  }
}

function gitChanged() {
  try {
    return execFileSync('git', ['status', '--porcelain'], { cwd: root, encoding: 'utf8' })
      .split('\n').map((l) => l.slice(3).trim()).filter(Boolean);
  } catch {
    return [];
  }
}

export function check(names, files) {
  const scopes = buildScopes();
  const out = { ok: true, violations: [], shared: [], checked: [] };
  for (const name of names) {
    const scope = scopes.get(name);
    if (!scope) {
      out.ok = false;
      out.violations.push({ file: '-', scope: name, reason: 'unbekannter Scope' });
      continue;
    }
    out.checked.push(name);
    for (const file of files) {
      if (!file || file.startsWith('.claude/')) continue;
      const kind = matchScope(file, scope);
      if (kind === 'own') continue;
      if (kind === 'shared') { out.shared.push(`${file}  (${name}, geteilte Datei)`); continue; }
      const others = ownerOf(file, scopes).filter((o) => o !== name);
      out.ok = false;
      out.violations.push({
        file,
        scope: name,
        reason: others.length ? `gehört '${others.join("', '")}'` : 'außerhalb des Scopes',
      });
    }
  }
  return out;
}

// CLI. Only when this file is the entry point — `test-game.mjs` imports the
// manifest above and must not trigger the argument parsing here.
const invokedDirectly = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (invokedDirectly) {
const argv = process.argv.slice(2);
const cmd = argv[0];
const scopes = buildScopes();

if (cmd === 'list' || !cmd) {
  const pad = Math.max(...[...scopes.keys()].map((k) => k.length));
  for (const [name, s] of scopes) {
    console.log(`${name.padEnd(pad)}  ${s.agent.padEnd(10)}  ${s.label}`);
  }
  const problems = validate(scopes);
  if (problems.length) {
    console.error('\nManifest-Fehler:');
    for (const p of problems) console.error(`  ✗ ${p}`);
    process.exit(1);
  }
  console.log(`\n${scopes.size} Scopes, Manifest ist konsistent.`);
} else if (cmd === 'explain') {
  const file = argv[1] ?? '';
  for (const [name, s] of scopes) {
    const kind = matchScope(file, s);
    if (kind) console.log(`${kind.padEnd(7)} ${name}  (${kind === 'own' ? 'eigen' : 'geteilt'})`);
  }
  if (![...scopes.values()].some((s) => matchScope(file, s))) console.log('kein Scope beansprucht diese Datei');
} else if (cmd === 'check') {
  const names = (argv[1] ?? '').split(',').map((s) => s.trim()).filter(Boolean);
  if (!names.length) { console.error('Aufruf: scopes.mjs check <scope>[,<scope>]'); process.exit(2); }
  const files = argv.includes('--changed') ? gitChanged() : gitStaged();
  if (!files.length) { console.log('Keine Dateien im Index — nichts zu prüfen.'); process.exit(0); }
  const res = check(names, files);
  if (res.shared.length) {
    console.log('Geteilte Dateien (zusammenführen, nicht exklusiv):');
    for (const s of res.shared) console.log(`  ~ ${s}`);
  }
  if (!res.ok) {
    console.error('\nScope-Verstöße:');
    for (const v of res.violations) console.error(`  ✗ ${v.file}  — ${v.reason}  (${v.scope})`);
    process.exit(1);
  }
  console.log(`\n✓ ${res.checked.join(', ')}: ${files.length} Datei(en) im erlaubten Bereich.`);
} else {
  console.error(`Unbekanntes Kommando '${cmd}'. Erlaubt: list | check | explain`);
  process.exit(2);
}
}
