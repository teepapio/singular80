import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * `content/*.json` is the single source of the game's data and has no other
 * safety net: `npm run content:sync` copies it, it does not check it, and a typo
 * in a stat name produces a card that quietly does nothing. The game reads these
 * files by string, so a mistake here is invisible in every other layer.
 *
 * Two kinds of assertion, and the difference matters. The data side is checked
 * against the data: a `splitInto` target that does not exist, a `shape` the
 * screen has no `match` arm for, a stat that does not survive the bridge. The
 * GDScript side is read as text for the *sets of allowed values*, because those
 * sets live in a `match` statement in another language — hardcoding them here
 * would be a second truth that goes stale silently.
 */

const ROOT = join(import.meta.dirname, '..');
const CONTENT = join(ROOT, 'content');

type Row = Record<string, unknown>;

function pack(name: string): Row[] {
  return JSON.parse(readFileSync(join(CONTENT, `${name}.json`), 'utf8')) as Row[];
}

function godot(relativePath: string): string {
  return readFileSync(join(ROOT, 'godot', relativePath), 'utf8');
}

/** Every `.gd` file under `godot/src`, for the "nothing reads this" claims. */
function godotSources(dir = join(ROOT, 'godot', 'src')): { file: string; source: string }[] {
  const out: { file: string; source: string }[] = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) out.push(...godotSources(full));
    else if (name.endsWith('.gd')) {
      out.push({ file: relative(join(ROOT, 'godot', 'src'), full), source: readFileSync(full, 'utf8') });
    }
  }
  return out;
}

/** Godot's `String.to_snake_case`, which is what `arena_runs.gd:stat_key` uses. */
function toSnakeCase(value: string): string {
  return value.replace(/([a-z0-9])([A-Z])/g, '$1_$2').toLowerCase();
}

/**
 * The shapes the screen can draw, gathered from the quoted names it branches on
 * rather than from a hand-written list: a list here would be a second truth that
 * goes stale the next time the drawing code is reorganised — and the drawing code
 * is reorganised more often than the data.
 *
 * The set fails **open**: an unrecognised name adds to it rather than removing
 * from it, so a refactor can make this test weaker but never make it lie about a
 * shape the content actually uses.
 */
function shapesOf(screen: string): Set<string> {
  const out = new Set<string>();
  for (const m of screen.matchAll(/^\s*"(\w+)":\s*$/gm)) out.add(m[1]);
  for (const m of screen.matchAll(/enemy\.shape == "(\w+)"/g)) out.add(m[1]);
  out.add(/get\("shape", "(\w+)"\)/.exec(screen)?.[1] ?? 'circle');
  expect(out.size, 'keine Formen im Arena-Screen gefunden').toBeGreaterThan(1);
  return out;
}

/** The behaviours the movement switch knows, plus its default. */
function behaviorsOf(screen: string): Set<string> {
  const out = new Set([...screen.matchAll(/behavior == "(\w+)"/g)].map((m) => m[1]));
  out.add(/get\("behavior", "(\w+)"\)/.exec(screen)?.[1] ?? 'chase');
  return out;
}

/** `PlayerStats.NUMERIC_FIELDS` — the fields `apply_upgrade` can actually change. */
function numericFieldsOf(stats: string): Set<string> {
  const from = stats.indexOf('const NUMERIC_FIELDS := [');
  expect(from, 'NUMERIC_FIELDS fehlt in player_stats.gd').toBeGreaterThan(-1);
  const to = stats.indexOf(']', from);
  expect(to, 'NUMERIC_FIELDS wird nicht geschlossen').toBeGreaterThan(from);
  // Every quoted name, not one per line: the list is written several to a line,
  // and a single `exec` per line would silently drop most of it.
  return new Set(stats.slice(from, to).match(/"([\w_]+)"/g)?.map((m) => m.slice(1, -1)) ?? []);
}

const ARENA = godot('src/game/arena/arena_screen.gd');
const STATS = godot('src/core/logic/player_stats.gd');
const MENU = godot('src/game/arena/main_menu_screen.gd');

/** Key sets per file: what every row must have, and the optional extras. */
const PACKS: { name: string; required: string[]; optional: string[] }[] = [
  {
    name: 'enemies',
    required: ['id', 'name', 'hp', 'speed', 'damage', 'radius', 'color', 'xp', 'minWave', 'weight'],
    optional: ['shape', 'behavior', 'boss', 'splitInto', 'splitCount'],
  },
  {
    name: 'weapons',
    required: [
      'id', 'name', 'description', 'damage', 'cooldown', 'projectileSpeed', 'projectileCount',
      'spread', 'pierce', 'size', 'color', 'unlockWave',
    ],
    optional: [],
  },
  {
    name: 'upgrades',
    required: ['id', 'name', 'description', 'stat', 'amount', 'maxStacks', 'rarity', 'minLevel'],
    optional: [],
  },
  {
    name: 'modes',
    required: ['id', 'name', 'description', 'enemyHpMult', 'enemySpeedMult', 'spawnRateMult', 'duration'],
    optional: [],
  },
  { name: 'mechanics', required: ['id', 'name', 'description', 'enabled'], optional: [] },
];

describe('content/*.json — Form', () => {
  it.each(PACKS)('$name: jede Zeile hat genau die erwarteten Schlüssel', ({ name, required, optional }) => {
    const rows = pack(name);
    expect(rows.length, `${name}.json ist leer`).toBeGreaterThan(0);
    for (const row of rows) {
      const keys = Object.keys(row).sort();
      const id = String(row.id);
      const missing = required.filter((key) => !keys.includes(key));
      const unknown = keys.filter((key) => !required.includes(key) && !optional.includes(key));
      expect(missing, `${name}.json #${id} fehlt: ${missing.join(', ')}`).toEqual([]);
      // A key nobody declared is a key the game will never read — the failure this
      // catches is a field that was renamed on one side only.
      expect(unknown, `${name}.json #${id} hat unbekannte Schlüssel: ${unknown.join(', ')}`).toEqual([]);
    }
  });

  it.each(PACKS)('$name: keine id doppelt', ({ name }) => {
    const ids = pack(name).map((row) => String(row.id));
    expect(new Set(ids).size, `${name}.json: ${ids.length - new Set(ids).size} doppelte id`).toBe(ids.length);
  });

  it('keine id kommt in zwei Dateien vor', () => {
    // The packs are separate namespaces, so a collision is a lookup that finds the
    // wrong row — `enemies.json` and `weapons.json` are read by different code.
    const seen = new Map<string, string>();
    for (const { name } of PACKS) {
      for (const row of pack(name)) {
        const id = String(row.id);
        expect(seen.has(id), `id "${id}" steht in ${seen.get(id)} und ${name}.json`).toBe(false);
        seen.set(id, name);
      }
    }
  });
});

describe('content/enemies.json — was der Arena-Screen kennt', () => {
  it('nennt für jeden Gegner eine Form, die `_draw_enemy` zeichnen kann', () => {
    const known = shapesOf(ARENA);
    for (const enemy of pack('enemies')) {
      const shape = String(enemy.shape ?? 'circle');
      expect(known.has(shape), `Form "${shape}" (#${enemy.id}) hat keinen match-Arm`).toBe(true);
    }
  });

  it('nennt für jeden Gegner ein Verhalten, das die Bewegung kennt', () => {
    const known = behaviorsOf(ARENA);
    for (const enemy of pack('enemies')) {
      const behavior = String(enemy.behavior ?? 'chase');
      expect(known.has(behavior), `Verhalten "${behavior}" (#${enemy.id}) wird nicht behandelt`).toBe(true);
    }
  });

  it('verweist mit splitInto nur auf einen Gegner, den es gibt', () => {
    const ids = new Set(pack('enemies').map((row) => String(row.id)));
    for (const enemy of pack('enemies')) {
      if (enemy.splitInto === undefined) continue;
      const target = String(enemy.splitInto);
      expect(ids.has(target), `${enemy.id} teilt sich in "${target}", den es nicht gibt`).toBe(true);
      // A splitter without a count spawns two — fine, but the field has to be a
      // number, or the loop that creates the children gets a string.
      if (enemy.splitCount !== undefined) expect(typeof enemy.splitCount).toBe('number');
    }
  });

  it('gibt jedem Splitter ein Ziel mit eigener Gewichtung', () => {
    // `weight <= 0` means "never spawned by the wave picker", which is what a
    // child needs; a child that can also spawn on its own appears twice as often
    // as intended.
    const byId = new Map(pack('enemies').map((row) => [String(row.id), row]));
    for (const enemy of pack('enemies')) {
      if (enemy.splitInto === undefined) continue;
      const child = byId.get(String(enemy.splitInto));
      expect(child, `${enemy.id} zeigt auf einen unbekannten Gegner`).toBeDefined();
      expect(Number(child?.weight), `${enemy.id} → ${child?.id} kann selbst spawnen`).toBe(0);
    }
  });
});

describe('content/upgrades.json — jede Karte verändert wirklich etwas', () => {
  it('bringt jeden Stat durch to_snake_case in ein Feld, das PlayerStats kennt', () => {
    // The bridge is `arena_runs.gd:stat_key`, which does `to_snake_case()` on the
    // pack's spelling; `PlayerStats.apply_upgrade` drops anything it does not
    // recognise **silently**. A typo here is a card that does nothing at all.
    const known = numericFieldsOf(STATS);
    for (const upgrade of pack('upgrades')) {
      const stat = toSnakeCase(String(upgrade.stat));
      expect(
        known.has(stat),
        `${upgrade.id}: "${upgrade.stat}" → "${stat}" ist kein Feld von PlayerStats (NUMERIC_FIELDS)`,
      ).toBe(true);
    }
  });

  it('nennt für jede Karte einen Betrag, der nicht null ist', () => {
    for (const upgrade of pack('upgrades')) {
      expect(Number(upgrade.amount), `${upgrade.id} hat amount ${upgrade.amount}`).not.toBe(0);
      expect(Number(upgrade.maxStacks), `${upgrade.id} hat maxStacks ${upgrade.maxStacks}`).toBeGreaterThan(0);
      expect(Number(upgrade.minLevel), `${upgrade.id} hat minLevel ${upgrade.minLevel}`).toBeGreaterThan(0);
    }
  });

  it('kennt für jede Seltenheit einen Wert, den der Entwurf anbietet', () => {
    // `arena_runs.gd` draws a number of cards per rarity; an unknown one is a card
    // that is never offered.
    const rarities = new Set(['common', 'uncommon', 'rare']);
    for (const upgrade of pack('upgrades')) {
      expect(rarities.has(String(upgrade.rarity)), `${upgrade.id}: Seltenheit "${upgrade.rarity}"`).toBe(true);
    }
  });
});

describe('Toter Content, der nicht still verrotten darf', () => {
  it('zeigt: eine Waffe mit unlockWave > 0 ist unerreichbar', () => {
    // `main_menu_screen.gd` filters on `unlockWave <= 0`, in both the build and
    // the refresh of the weapon row. There is no in-run unlock and exactly one
    // call site of `Game.set_arena_weapon`, so a weapon behind that filter can
    // never be selected. Not a bug — a decision, and it is only safe while it is
    // true. The moment someone adds an in-run unlock, this fails and says so.
    const sources = godotSources();
    const unlockFilters = sources.filter((f) => /unlockWave/.test(f.source));
    expect(unlockFilters.map((f) => f.file)).toEqual(['game/arena/main_menu_screen.gd']);
    for (const file of unlockFilters) {
      for (const match of file.source.matchAll(/unlockWave/g)) {
        const at = match.index ?? 0;
        expect(file.source.slice(at, at + 40)).toMatch(/unlockWave",\s*0\)\)\s*<=\s*0/);
      }
    }
    const setters = sources.filter((f) => /set_arena_weapon/.test(f.source));
    // The definition in the state autoload and one call in the menu. A second
    // caller would be the in-run unlock this test is waiting for.
    expect(setters.map((f) => f.file).sort()).toEqual([
      'core/autoload/game_state.gd',
      'game/arena/main_menu_screen.gd',
    ]);

    const unreachable = pack('weapons')
      .filter((w) => Number(w.unlockWave) > 0)
      .map((w) => String(w.id));
    // Named, so the failure of this test says which weapons became reachable.
    expect(unreachable).toEqual(['railgun', 'burst']);
    // The other way round: the menu is not empty.
    expect(pack('weapons').filter((w) => Number(w.unlockWave) <= 0).length).toBeGreaterThan(0);
  });

  it('zeigt: die Dauer eines Modus wird von nichts gelesen', () => {
    // Every mode carries `duration: 0`, and no file that knows about
    // `Content.modes` reads a `duration`. The field is in the type, so it looks
    // finished; a mode with a real duration would change nothing at all.
    for (const mode of pack('modes')) {
      expect(Number(mode.duration), `${mode.id} hat duration ${mode.duration}`).toBe(0);
    }
    const modeReaders = godotSources().filter((f) => /Content\.modes|\bmodes\b\s*\[/.test(f.source));
    expect(modeReaders.length, 'die Modus-Leser haben sich geändert').toBeGreaterThan(0);
    for (const file of modeReaders) {
      expect(file.source, `${file.file} liest eine Modus-Dauer`).not.toMatch(/["']duration["']/);
    }
  });
});
