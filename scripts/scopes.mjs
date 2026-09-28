#!/usr/bin/env node
/**
 * Scope manifest and pre-commit guard for parallel agents.
 *
 * The runner starts a second agent in the same tree, so every file must belong
 * to exactly one scope — otherwise `git add -A` sweeps up a stranger's work.
 *
 *   node scripts/scopes.mjs list
 *   node scripts/scopes.mjs check tetris            # staged files vs scope
 *   node scripts/scopes.mjs check tetris,pang --staged
 *   node scripts/scopes.mjs explain godot/src/core/logic/asset_registry.gd
 *   node scripts/scopes.mjs scope-for               # changed files -> which suites
 *   node scripts/scopes.mjs scope-for a.gd b.gd
 *
 * `own` is private to the scope, `shared` is a file every agent touches.
 */
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

/**
 * Files every game agent touches. The central test files sit here rather than
 * in a game's `own`; a game gets its own `godot/tests/test_<id>.gd` instead,
 * which nobody else claims.
 */
export const SHARED_FILES = [
  'godot/src/core/logic/asset_registry.gd',
  'godot/src/core/logic/game_registry.gd',
  'godot/src/core/autoload/router.gd',
  'godot/src/core/autoload/game_state.gd',
  // Godot writes a `.uid` next to every script it imports and the repository
  // versions them all, so a shared script without its `.uid` is an unownable
  // file: `git add -A` picks it up and the pre-commit guard has to call it a
  // violation.
  'godot/src/core/autoload/router.gd.uid',
  'godot/src/core/autoload/game_state.gd.uid',
  'godot/src/core/logic/game_registry.gd.uid',
  'godot/assets/meshes/lod.json',
  'godot/tests/run_tests.gd',
  'godot/tests/test_logic.gd',
  'godot/tests/test_screens.gd',
  'godot/tests/test_improvements.gd',
  'godot/tests/run_tests.gd.uid',
  'godot/tests/test_logic.gd.uid',
  'godot/tests/test_screens.gd.uid',
  'godot/tests/test_improvements.gd.uid',
  'package.json',
  'opencode.json',
  'AGENTS.md',
  // The runner writes a changelog line after every successful run and commits it
  // on its own (`git commit -- CHANGELOG.md`). Nobody's `own`, everybody's
  // business: without it here the commit is reported as "außerhalb des Scopes"
  // for whichever lane happened to run, and an agent told that would look for a
  // way around the guard rather than for the missing entry.
  'CHANGELOG.md',
];

/**
 * Files that belong to no agent, listed so the ownership rule can say "this one
 * is on purpose" instead of staying quiet about it.
 *
 * Everything here is either written by a person, written by a tool that is not
 * an agent, or belongs to a release process no suggestion agent touches. The
 * list is deliberately short and each line says why — a growing allowlist is the
 * same failure as an unowned file, only quieter, because the rule then passes
 * for a reason nobody re-reads.
 */
export const UNOWNED_ALLOWED = [
  // The repository itself: identity, licence, the file that lists what is
  // ignored, and the example for the secrets that never get committed.
  'LICENSE',
  'README.md',
  '.gitignore',
  '.env.example',
  // `npm install` writes it, no agent decides its content.
  'package-lock.json',
  // `npm run backup -- write` writes it. The dashboard history belongs in the
  // repository, and it is data, not code.
  'backup/dashboard.json',
  // The agent definitions themselves: an agent cannot own the prompt it is given.
  '.opencode/**',
  // The Play release project. Its own scripts, its own config, its own docs, its
  // own checks — it is a pipeline the owner runs, not a lane a suggestion agent
  // works in, and `preflight.mjs` is the guard for it.
  'googleplay/**',
];

/**
 * Logic modules a game owns outright. A game without an entry shares a generic
 * module (cards, checkers, twenty48) or keeps its rules in the screen.
 */
const GAME_LOGIC = {
  arena: ['godot/src/core/logic/arena_runs.gd'],
  tetris: ['godot/src/core/logic/tetris_rules.gd'],
  poker: ['godot/src/core/logic/holdem.gd'],
  freecell: ['godot/src/core/logic/cards.gd'],
  dame: ['godot/src/core/logic/checkers.gd'],
  '2048': ['godot/src/core/logic/twenty48.gd'],
  crystal3d: ['godot/src/core/logic/crystal_tower.gd'],
  // The logic file hangs off the base scope: `buildScopes` reads
  // `GAME_LOGIC[base]`, so an entry under a variant key would never be read.
  merge3d: ['godot/src/core/logic/merge3d.gd'],
  dragonrpg: ['godot/src/core/logic/dragon_rpg.gd'],
  dragonflight: ['godot/src/core/logic/dragon_flight.gd'],
  horserunner: ['godot/src/core/logic/horse_runner.gd'],
  pang: ['godot/src/core/logic/pang.gd'],
  metro3d: ['godot/src/core/logic/metro.gd'],
  candy3d: ['godot/src/core/logic/candy_match3.gd'],
  siedler: ['godot/src/core/logic/siedler.gd'],
};

/**
 * Entries that reuse another game's screen and logic: lobby entries and content
 * themes, so they resolve to the base scope instead of claiming it twice.
 */
const VARIANT_BASE = {
  'crystal3d-christmas': 'crystal3d',
  'crystal3d-halloween': 'crystal3d',
  'merge3d-christmas': 'merge3d',
  'merge3d-halloween': 'merge3d',
};

/**
 * Suite files whose name is neither the registry id nor the directory name.
 *
 * One game owns two files because one of them is a screen sweep and the other
 * the rules, and splitting them was a decision. The pattern is derived where it
 * can be; this is the rest.
 */
const EXTRA_GAME_TESTS = {
  metro3d: ['test_metro_screens'],
};

/**
 * The test suites each scope owns: `npm run test:game -- --scope tetris`
 * resolves to exactly these. `validate()` fails if a name no longer exists.
 *
 * The `Screens` sweep is driven separately, by `screens` below.
 */
const SCOPE_SUITES = {
  arena: ['PlayerStats', 'Arena — Spielablauf', 'Arena — Wellenvorschau', 'Arena — Kill-Ketten', 'Arena — Dash',
    'Arena — Level-Angebote', 'Arena — Kennzahl-Schreibweisen'],
  tetris: ['Tetris — Eingabe', 'Tetris — Punktewertung', 'Tetris — T-Spin-Erkennung',
    'Tetris — Vorschaukette', 'Tetris — Brettgefahr', 'Tetris — Drehen & Wall-Kicks',
    'Tetris — Wall-Kick-Tabellen', 'Tetris — T-Spin aus der Drehung', 'Tetris — Zugvorschau'],
  poker: ['Karten & Texas Hold\'em', 'Kartenspiele — Eingabe',
    'Poker — Persönlichkeiten', 'Poker — Tisches lesen', 'Poker — Typen-Bilanz'],
  freecell: ['Kartenspiele — Eingabe', 'FreeCell — Folgen', 'FreeCell — Supermove-Kapazität',
    'FreeCell — Sicherheit', 'FreeCell — Tipptext', 'FreeCell — Tippvorschlag',
    'FreeCell — Tipp ist immer erlaubt', 'FreeCell — Sackgasse', 'FreeCell — Tipp am Anfang',
    'FreeCell — Tipp am Screen'],
  dame: ['Dame — Regeln', 'Dame — Schlagzug-Analyse', 'Dame — Ziehbare Steine', 'Dame — Tipp am Brett'],
  crystal3d: ['Crystal Tower', 'Crystal Tower — Flusskette', 'Crystal Tower — Flusspunkte',
    'Crystal Tower — Screen', 'Crystal Tower — Screen fehlt'],
  merge3d: ['Merge 3D', 'Merge 3D — Tipp', 'Merge 3D — Tipptext und Brettdruck', 'Merge 3D — Tipp am Screen'],
  horserunner: ['Pferde-Parcours', 'Pferde-Parcours — Beinahe-Treffer', 'Pferde-Parcours — Kette'],
  dragonrpg: ['Drachen-RPG', 'Drachen-RPG — Loot-Rarität',
    'Drachen-RPG — Fluchttuning', 'Drachen-RPG — Fluchtrichtung', 'Drachen-RPG — Drachenflucht'],
  dragonflight: [
    'Drachenflug — Stammdaten', 'Drachenflug — Vererbung', 'Drachenflug — Zuchtvorhersage',
    'Drachenflug — Elemente', 'Drachenflug — Werte', 'Drachenflug — Profil & Zucht',
    'Drachenflug — Allele', 'Drachenflug — Blutbild', 'Drachenflug — Zuchtziel',
    'Drachenflug — Beste Paarung', 'Drachenflug — Ei-Vorschau',
  ],
  pang: ['Pang', 'Pang — Treffer', 'Pang — Doppelgriff', 'Pang — Kugelbudget', 'Pang — Wellenwarnung'],
  metro3d: [
    'Metropol 3D — Regeln', 'Metropol 3D — Netz', 'Metropol 3D — Wirtschaft',
    'Metropol 3D — Screen', 'Metropol 3D — Linienbau', 'Metropol 3D — Spielablauf',
    'Metropol 3D — Bedarfsprognose', 'Metropol 3D — Fehlende Linien',
    'Metropol 3D — Berufsverkehrs-Prognose', 'Metropol 3D — Anschluss-Marker',
  ],
  '2048': ['2048', '2048 — Vorschau', '2048 — Vorschau zählt mit', '2048 — Vorschau und Endgame', '2048 — Screen'],
  candy3d: [
    'Candy Crush — Reihen', 'Candy Crush — Züge', 'Candy Crush — Spezialbonbons',
    'Candy Crush — Blöcke', 'Candy Crush — Schwerkraft', 'Candy Crush — Level-Generator',
    'Candy Crush — Level', 'Candy Crush — Tageslevel', 'Candy Crush — Belohnungen',
    'Candy Crush — Undo', 'Candy Crush — Momente',
    'Candy Crush — Frame-Takt', 'Candy Crush — Ergebnisbildschirm', 'Candy Crush — Spielablauf',
    'Candy Crush — Kombinationen',
  ],
  siedler: ['Siedler — Insel', 'Siedler — Produktionsketten', 'Siedler — Fahnen und Straßen',
    'Siedler — Wirtschaft', 'Siedler — Ratgeber: Erzeuger', 'Siedler — Ratgeber: Stillstand',
    'Siedler — Ratgeber: Rangfolge', 'Siedler — Ratgeber: Taktgleichheit',
    'Siedler — Ratgeber: Handlung', 'Siedler — Handelswege: Messung',
    'Siedler — Handelswege: Bericht', 'Siedler — Handelswege: Optimierung',
    'Siedler — Handelswege: Ware und Wert', 'Siedler — Handelswege: Streckenteilung',
    'Siedler — Ratgeber: Lagerplatz'],
  meshes: ['Asset-Registry', 'Mesh-Galerie', 'Mesh — Detailstufen', 'Mesh-Galerie — Halle'],
  lobby: ['Lobby-Geometrie', 'Vorschlagsdialog'],
  core: ['Mechaniken', 'Inventar', 'Vorschlag — Herkunft', 'Auftragsweg', 'Server-Adresse',
    'Vorschlags-Warteschlange', 'Vorschlags-Warteschlange — Ablage',
    'Vorschlags-Warteschlange — Backoff', 'Vorschlags-Warteschlange — Obergrenze',
    'Vorschlags-Warteschlange — Zustellung', 'Rechtliches & Melden',
    'Sprachen — Kataloge', 'Sprachen — Auflösung', 'Sprachen — Platzhalter',
    'Sprachen — Plural', 'Sprachen — Zahlen', 'Sprachen — Wechsel',
    'Sprachen — Oberfläche',
    'Sprachen — Idempotenz gesamt', 'Sprachen — Pluralformen',
    'Sprachen — Spielerdatei', 'Sprachen — Vorlagenvertrag',
    'Sprachen — Platzhalterverworfen', 'Sprachen — Abfrage',
    'Sprachen — Zahlenränder', 'Sprachen — Kaltstart',
    'Sprachen — Übersetzungen'],
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
  // The screen list hangs off the base scope: variants inherit it, so a list
  // under a variant key would never be read.
  merge3d: ['merge3d_christmas', 'merge3d_halloween'],
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
  tooling: {
    agent: 'merge',
    label: 'Werkzeuge & Manifest',
    // Every game agent has to touch `scopes.mjs` to register its new suites,
    // so an unowned manifest would flag the step it requires.
    //
    // Spelled out rather than `scripts/**`: a broad glob would overlap the
    // meshes scope, and the manifest has no way to subtract.
    own: [
      'scripts/scopes.mjs',
      'scripts/test-game.mjs',
      'scripts/sync-content.mjs',
      'scripts/locale.mjs',
      // The lane tools: one worktree and one branch per agent run, and the gate
      // that merges them into `main`. They were untracked when the manifest was
      // last read, which is exactly the case the ownership rule could not see —
      // see `unownedFiles` below. This is their lane, and it is this one, because
      // the alternative is that the next agent looking for an owner finds none.
      // `worktree.d.mts` is named because `server/isolation.ts` imports the
      // module, and a runner change that does not typecheck is no runner change.
      'scripts/worktree.mjs',
      'scripts/worktree.d.mts',
      'scripts/merge-gate.mjs',
      // The types for the gate, for the same reason as `worktree.d.mts`: the
      // test imports the module, and an untyped import is a typecheck error.
      'scripts/merge-gate.d.mts',
      // Die Typen für den Test, der das Werkzeug benutzt. `.d.mts`, weil der
      // Import auf `locale.mjs` zeigt und TypeScript daneben genau das sucht.
      'scripts/locale.d.mts',
      'scripts/install-guard.sh',
      'scripts/install-android-template.mjs',
      'scripts/smoke.ts',
      'scripts/backup.ts',
      // Writes the session's line into CHANGELOG.md. It has to be a named file
      // rather than `scripts/**`, which the meshes scope already reaches into.
      'scripts/changelog.ts',
      // Device work: the debug bridge, and the fonts the app and the desktop
      // build both ship. Named one by one because `scripts/**` would swallow the
      // meshes scope and `godot/assets/**` would swallow the content mirror.
      'scripts/adb-device.sh',
      'godot/assets/fonts/**',
      // The Godot project shell: the scene graph's entry point, the project
      // configuration every export reads (`emulate_mouse_from_touch` lives
      // there), the export preset and the app icon. One suggestion agent changes
      // one of them — and it is this lane, because the alternative is that the
      // next one finds no owner either.
      'godot/main.tscn',
      'godot/project.godot',
      'godot/export_presets.cfg',
      'godot/icon.svg',
      'godot/icon.svg.import',
      'godot/src/main.gd',
      'godot/src/main.gd.uid',
      'start.sh',
      'packaging/singular80.desktop',
    ],
    shared: ['package.json'],
  },
  meshes: {
    agent: 'meshes',
    label: 'Meshes & LOD-Stufen',
    own: [
      'godot/assets/meshes/**',
      'scripts/blender/**',
      'godot/src/core/logic/asset_registry.gd',
      'godot/src/core/logic/asset_registry.gd.uid',
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
    own: [
      'godot/src/game/lobby/**',
      'godot/src/core/logic/lobby.gd',
      'godot/src/core/logic/lobby.gd.uid',
      'godot/src/core/logic/mesh_gallery.gd',
      'godot/src/core/logic/mesh_gallery.gd.uid',
    ],
    shared: ['godot/src/core/logic/game_registry.gd', 'godot/src/core/logic/asset_registry.gd'],
  },
  tests: {
    agent: 'build',
    label: 'Test-Harness',
    // Only the harness itself. `godot/tests/test_<spiel>.gd` belongs to the game
    // of that name, so two games never append to the same file.
    own: [
      'godot/tests/test_kit.gd',
      'godot/tests/test_kit.gd.uid',
      'vitest.config.ts',
      'tsconfig.json',
      'tests/**',
    ],
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
      // Die Sprachschicht. `loc.gd` trägt die Kataloge, `loc.gd.uid` gehört dazu,
      // damit ein neues Skript nicht ohne die Datei liegen bleibt, die das Repo
      // sonst überall mitführt.
      'godot/src/core/logic/loc.gd',
      'godot/src/core/logic/loc.gd.uid',
      'godot/src/core/logic/suggestion_context.gd',
      // The legal and reporting addresses. Nothing else in the game is a legal
      // document, and the Play-mandated abuse report hangs on this one file.
      'godot/src/core/logic/app_legal.gd',
      'godot/src/core/logic/app_legal.gd.uid',
      // Each logic module brings its `.uid` sibling: the repo versions 61 of
      // them under `godot/src/`, so a new logic file that leaves its `.uid`
      // untracked is an inconsistency, not a detail.
      'godot/src/core/logic/suggestion_context.gd.uid',
      'godot/src/core/logic/suggestion_queue.gd',
      'godot/src/core/logic/suggestion_queue.gd.uid',
      'godot/src/core/logic/player_stats.gd.uid',
      'godot/src/core/logic/item_inventory.gd.uid',
      // Die Kataloge liegen im Repo und sind ins Godot-Projekt gespiegelt, genau
      // wie `content/*.json` — beide Wege prüft `npm test` gegeneinander.
      'locale/**',
      'godot/assets/locale/**',
      'godot/src/core/ui/**',
      'godot/src/core/autoload/input_setup.gd',
      'godot/src/core/autoload/input_setup.gd.uid',
      'godot/src/core/autoload/api_client.gd',
      'godot/src/core/autoload/api_client.gd.uid',
      'godot/src/core/autoload/content_store.gd',
      'godot/src/core/autoload/content_store.gd.uid',
      'godot/src/core/autoload/audio_service.gd',
      'godot/src/core/autoload/audio_service.gd.uid',
      // Its own test file, as the games have: so nobody writes into
      // `test_logic.gd`.
      'godot/tests/test_core.gd',
      'godot/tests/test_core.gd.uid',
      'godot/tests/test_loc.gd',
      'godot/tests/test_loc.gd.uid',
    ],
    // No `suites` and no `screens` here on purpose. `buildScopes()` overwrites
    // both from `SCOPE_SUITES` / `SCOPE_SCREENS` for every static scope, so a
    // list written into this object is dead the moment it is read — and it was
    // also the copy missing the whole `Sprachen — *` block, which made it a
    // trap: an agent adding a suite to the wrong list saw `list` stay green.
    shared: ['godot/src/core/autoload/game_state.gd', 'godot/src/core/logic/game_registry.gd'],
  },
  content: {
    agent: 'game',
    label: 'Content-Packs (Gegner, Waffen, Modi)',
    // The mirror under `godot/assets/content/` belongs here and not to a game:
    // it is written by `npm run content:sync` from `content/*.json` and
    // `npm test` fails when the two differ, so whoever edits a pack edits both.
    own: ['content/**', 'godot/assets/content/**'],
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

  // Base games first: every variant needs its base scope, and `merge3d` exists
  // only as a variant, never as a registry entry.
  const bases = new Set([...dirs.keys()].filter((id) => !VARIANT_BASE[id]));
  for (const base of Object.values(VARIANT_BASE)) bases.add(base);

  for (const base of bases) {
    const dir = dirs.get(base) ?? [...dirs.values()].find((d) => d === base.replace('-', ''))
      ?? [...dirs.values()].find((d) => d.startsWith(base.split('-')[0]));
    if (!dir) continue;
    // A game agent also gets a private test file, so two games never append to
    // the same suite file. The trailing `*` also claims Godot's
    // `test_<id>.gd.uid`, which is committed like every other script and would
    // otherwise be unownable.
    const logic = GAME_LOGIC[base] ?? GAME_LOGIC[dir] ?? [];
    const own = [
      `godot/src/game/${dir}/**`,
      `godot/tests/test_${base}.gd*`,
      // The suite file is named after the *directory* in two games, so the glob
      // built from the registry id (`candy3d` -> `test_candy3d.gd`) pointed at
      // nothing while the real file sat unowned: `test_candy_match3.gd` with ten
      // suites, `test_metro.gd` and `test_metro_screens.gd`. `validate()` only
      // compared suite *names*, and those were all claimed, so the manifest
      // called itself consistent. Deriving the second name from the directory
      // covers the case instead of listing it, and `EXTRA_GAME_TESTS` below
      // takes the rest.
      `godot/tests/test_${dir}.gd*`,
      ...(EXTRA_GAME_TESTS[base] ?? []).map((f) => `godot/tests/${f}.gd*`),
      ...logic.flatMap((file) => [file, `${file}.uid`]),
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
  // Exclusivity: no file may belong to two scopes. Variants are exempt — they
  // deliberately mirror the base scope.
  //
  // Two passes, because a directory glob swallows a named file and the old
  // single pass could only compare like with like: `tests/**` was checked
  // against other `/**` globs and `tests/foo.ts` only against other named globs,
  // so naming a file *inside* a directory another scope owns was invisible. The
  // order scopes are declared in decided whether it was caught at all, which is
  // the worst possible property for a rule whose job is to be boring.
  const dirGlobs = new Map();
  const fileGlobs = new Map();
  for (const [name, scope] of scopes) {
    if (scope.aliasOf) continue;
    for (const glob of scope.own) {
      if (glob.endsWith('/**')) {
        const dir = glob.slice(0, -3);
        // The identical directory from two scopes is the same overlap the
        // prefix test below reports, so it is checked here instead: collecting
        // into a Map first would keep only the last claim and say nothing.
        if (dirGlobs.has(dir) && dirGlobs.get(dir) !== name) {
          problems.push(`Überschneidung: '${name}' und '${dirGlobs.get(dir)}' beanspruchen ${dir}`);
        } else if (!dirGlobs.has(dir)) {
          dirGlobs.set(dir, name);
        }
      } else {
        // Two scopes naming the same file, same reasoning.
        if (fileGlobs.has(glob) && fileGlobs.get(glob) !== name) {
          problems.push(`Überschneidung: '${name}' und '${fileGlobs.get(glob)}' beanspruchen ${glob}`);
        } else if (!fileGlobs.has(glob)) {
          fileGlobs.set(glob, name);
        }
      }
    }
  }
  for (const [dir, owner] of dirGlobs) {
    for (const [other, otherOwner] of dirGlobs) {
      if (dir === other) continue;
      if (other.startsWith(dir) || dir.startsWith(other)) {
        problems.push(`Überschneidung: '${owner}' und der Scope für ${otherOwner} beanspruchen ${dir}`);
      }
    }
  }
  for (const [glob, name] of fileGlobs) {
    for (const [dir, owner] of dirGlobs) {
      if (glob.startsWith(`${dir}/`)) {
        problems.push(`Überschneidung: '${name}' beansprucht ${glob}, das im Verzeichnis ${dir} des Scopes '${owner}' liegt`);
      }
    }
  }
  // Every suite must belong to exactly one scope. Unclaimed, a suite runs only
  // in the full run and the responsible agent sees the regression at merge time.
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

  // Every registry game needs a scope.
  for (const id of gameIds()) if (!scopes.has(id)) problems.push(`Spiel '${id}' hat keinen Scope`);

  // Every name must really exist, or the scope silently tests nothing and the
  // agent believes it is green.
  for (const [name, scope] of scopes) {
    for (const suite of scope.suites ?? []) {
      if (!suites.has(suite)) problems.push(`Scope '${name}': Suite '${suite}' existiert nicht in den Tests`);
    }
  }

  // And the reverse: a suite file the runner never loads never runs, so a green
  // run checks less than the repo contains.
  //
  // The runner stays hand-kept: the suites take different parameters, and an
  // async `run()` cannot be invoked via `call()` ("Trying to call an async
  // function without await"). This check makes the hand-keeping verifiable.
  const runner = readFileSync(join(root, 'godot/tests/run_tests.gd'), 'utf8');
  for (const file of suiteFiles()) {
    // Either reference form counts: by path (`load("res://tests/test_x.gd")`) or
    // by `class_name` (`TestX.new()`). The class-name form needs a built global
    // class cache, which is why the per-game suites use the path form.
    const base = file.split('/').pop();
    const className = (readFileSync(join(root, file), 'utf8').match(/class_name\s+(\w+)/) ?? [])[1];
    if (!runner.includes(base) && !(className && runner.includes(className))) {
      problems.push(`${file} wird von run_tests.gd nicht geladen — die Suite läuft nie`);
    }
  }

  // A suite NAME in the manifest is not a file. `SCOPE_SUITES.candy3d` listed ten
  // Candy Crush suites while the file they live in — `test_candy_match3.gd`, named
  // after the directory — belonged to nobody, and the same for both Metro files.
  // The suite check passed, so nobody noticed: two agents could each `git add` a
  // file the other was editing. Ownership is a property of the file, so it is
  // checked on the file, in addition to the two rules below that would catch it
  // anyway — this one says it in the words that name the cause.
  for (const file of suiteFiles()) {
    const owners = ownerOf(file, scopes);
    const sharedBy = [...scopes.values()].filter((s) => !s.aliasOf && matchScope(file, s) === 'shared');
    if (!owners.length && !sharedBy.length) {
      problems.push(`${file} enthält Suites, gehört aber keinem Scope — die Datei hat keinen Besitzer`);
    }
  }

  // Every tracked file must be somebody's, or be on the allowlist with a reason.
  //
  // This is the rule that would have caught all 88 unowned files on the day they
  // appeared. Nothing before it looks at the repository at all: the manifest
  // describes what it claims and checks itself for contradictions, so a file
  // nobody claimed was invisible from the start — and invisible is exactly what a
  // shared working tree punishes, because `git add -A` takes it and no scope
  // check can object to a file no scope knows.
  const unowned = unownedFiles(scopes);
  if (unowned === null) {
    problems.push('git ls-files schlägt fehl — die Eigentumsprüfung konnte nicht laufen');
  } else {
    for (const file of unowned) {
      problems.push(`${file} gehört keinem Scope (own oder shared) — siehe UNOWNED_ALLOWED`);
    }
  }
  return problems;
}

/**
 * Tracked files that no scope claims and the allowlist does not cover, plus
 * untracked ones — a file on disk nobody has claimed is exactly the file a
 * stranger's `git add -A` takes.
 *
 * `null` means "could not tell", which is not the same as "none": without git
 * there is no list of what the repository contains, and reporting an empty
 * result would turn a broken check into a green one.
 */
export function unownedFiles(scopes = buildScopes()) {
  const files = repoFiles();
  if (files === null) return null;
  const allowed = UNOWNED_ALLOWED.map((glob) => globToRegExp(glob));
  return files
    .filter((file) => !allowed.some((re) => re.test(file)))
    // `own` and `shared` both count: a shared file is exactly as reachable by a
    // stranger's `git add -A` as an owned one, it is just allowed to be reached
    // by several people on purpose.
    .filter((file) => ![...scopes.values()].some((s) => matchScope(file, s) !== null));
}

/**
 * `git ls-files` once per process, and `false` for "git is not available here".
 *
 * `validate()` runs on every `GET /api/scopes` and the server already caches the
 * manifest itself, so caching the file list costs nothing and keeps a dashboard
 * poll from spawning git. `null` is "not read yet", which is why it is not also
 * the value for "git failed" — the two mean different things to the caller.
 */
let trackedCache = null;

/**
 * Everything the repository contains: tracked, plus untracked and not ignored.
 *
 * The untracked half is not a nicety. `git ls-files` alone cannot see a file
 * that nobody has staged yet, and an unclaimed file is at its most dangerous
 * precisely then — it is a stranger's work in progress, and the moment it gets
 * staged the same rule that passed a moment ago starts failing, in a session
 * that has no idea why. Measured on this repository: three files of finished
 * tooling (`worktree.mjs`, `worktree.d.mts`, `merge-gate.mjs`) sat untracked and
 * unowned for a day while `scopes.mjs list` printed "Manifest ist konsistent".
 *
 * `--exclude-standard` is what keeps this useful rather than noisy: `log/`,
 * `data/`, `dist/`, `build/`, `node_modules/`, `godot/.godot/` and the probe
 * scripts `.gitignore` already names never reach the check.
 */
function repoFiles() {
  if (trackedCache === null) {
    const read = (args) => {
      const res = execFileSync('git', args, { cwd: root, encoding: 'utf8', maxBuffer: 1e8 });
      return res.split('\n').map((s) => s.trim()).filter(Boolean);
    };
    try {
      trackedCache = [
        ...read(['ls-files']),
        ...read(['ls-files', '--others', '--exclude-standard']),
      ];
    } catch {
      trackedCache = false;
    }
  }
  return trackedCache === false ? null : trackedCache;
}

/** Test files that define a suite, i.e. everything but the shared TestKit. */
function suiteFiles() {
  const dir = join(root, 'godot/tests');
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((n) => n.startsWith('test_') && n.endsWith('.gd'))
    .filter((n) => readFileSync(join(dir, n), 'utf8').includes('func run('))
    .map((n) => `godot/tests/${n}`);
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

/**
 * Which scopes a set of files makes worth testing, and which files belong to
 * nobody's test scope at all.
 *
 * `check` answers "may this scope commit these files", and it is told which
 * scopes to judge against. This answers the question an agent actually has
 * afterwards — "I changed these, which suites do I run?" — and the manifest had
 * no answer to it, only `testArgs` and the memory of whoever wrote the change.
 * Without it the reflex was the full run: 39 s on this tree to learn what six
 * Tetris suites say in 6.
 *
 * Only `own` yields a scope. A merely `shared` file belongs to no suite in
 * particular — `game_registry.gd` is covered by the `Screens` sweep, which only
 * the full run has — so it is reported as shared and the full run stays the gate.
 * A variant scope owns byte-identical globs to its base, so the base answers for
 * both and `--scope crystal3d,crystal3d-christmas` is never printed.
 */
export function scopesForFiles(files, scopes = buildScopes()) {
  const own = new Map();
  const shared = [];
  const unowned = [];
  for (const file of files) {
    const owners = [];
    let isShared = false;
    for (const [name, scope] of scopes) {
      if (scope.aliasOf) continue;
      const kind = matchScope(file, scope);
      if (kind === 'own') owners.push(name);
      else if (kind === 'shared') isShared = true;
    }
    if (!owners.length) {
      (isShared ? shared : unowned).push(file);
      continue;
    }
    for (const name of owners) {
      const list = own.get(name);
      if (list) list.push(file);
      else own.set(name, [file]);
    }
  }
  return { own, shared, unowned };
}

/**
 * The `npm run test:game` line for a set of scopes, plus what it will run.
 *
 * `null` when the scopes map to no suite and no screen at all — the same
 * condition `test-game.mjs` refuses to start on, reported here so the agent finds
 * out from a name it recognises rather than from exit code 2.
 */
export function testCommand(names, scopes = buildScopes()) {
  if (!names.length) return null;
  const { suites, screens } = testArgs(names, scopes);
  if (!suites.length && !screens.length) return null;
  return {
    command: `npm run test:game -- --scope ${names.join(',')}`,
    suites: suites.length,
    screens: screens.length,
  };
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
} else if (cmd === 'scope-for') {
  const explicit = argv.slice(1).filter((a) => !a.startsWith('--'));
  const staged = argv.includes('--staged');
  const source = explicit.length ? 'angegeben' : staged ? 'im Index' : 'geändert';
  const files = explicit.length ? explicit : staged ? gitStaged() : gitChanged();
  if (!files.length) { console.log(`Keine Dateien ${source} — nichts zu prüfen.`); process.exit(0); }
  const { own, shared, unowned } = scopesForFiles(files, scopes);
  const names = [...own.keys()];
  console.log(`${files.length} Datei(en) ${source}\n`);
  const pad = Math.max(...names.map((n) => n.length), 0);
  for (const name of names) {
    console.log(`${name.padEnd(pad)}  ${scopes.get(name).label}`);
    for (const file of own.get(name)) console.log(`${' '.repeat(pad)}    ${file}`);
  }
  if (shared.length) {
    console.log('\nGeteilte Dateien — kein eigener Testumfang, der volle Lauf ist das Gate:');
    for (const file of shared) console.log(`  ~ ${file}`);
  }
  if (unowned.length) {
    console.log('\nKein Scope beansprucht diese Dateien — sie gehören niemandem, `git add -A` nimmt sie mit:');
    for (const file of unowned) console.log(`  ✗ ${file}`);
  }
  const plan = testCommand(names, scopes);
  if (plan) {
    console.log(`\n  ${plan.command}`);
    console.log(`  → ${plan.suites} Suite(n), ${plan.screens} Screen(s)`);
  }
  // A scope without suites is normal — `tooling` and `tests` have none, and
  // `scopes.mjs list` is where a *manifest* problem is reported. This command
  // only says which suites the change reaches, so it names the gap and stops.
  const withoutTests = names.filter((n) => !testCommand([n], scopes));
  if (withoutTests.length) {
    console.log(`\nOhne Suite im Manifest, nur der volle Lauf deckt sie ab: ${withoutTests.join(', ')}`);
  } else if (!plan) {
    console.log('\nKein eigener Testumfang — nur der volle Lauf sagt etwas.');
  }
  process.exit(unowned.length ? 1 : 0);
} else {
  console.error(`Unbekanntes Kommando '${cmd}'. Erlaubt: list | check | explain | scope-for`);
  process.exit(2);
}
}
