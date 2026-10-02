/**
 * `scripts/test-affected.mjs`: the plan, not the run.
 *
 * Every test here is about *which* commands a change produces. Nothing spawns
 * Godot or vitest — the tool's whole claim is that it does not run what a change
 * cannot reach, and a test that ran the suites would be 42 seconds long and
 * would only prove that the suites still pass.
 *
 * The numbers the tool is built on, measured on this tree on 2026-10-02:
 * `typecheck` 3 s, `npm test` 24 s, the full Godot catalogue 42 s, and the nine
 * Tetris suites 6 s. The plan below is the difference between 69 s and 6 s for
 * a game change, and that difference is the whole reason this file exists.
 */
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { affectedSteps, changedFiles, fullSteps } from '../scripts/test-affected.mjs';

const stepsFor = (files: string[], options = {}) => affectedSteps(files, options);
const names = (files: string[], options = {}) => stepsFor(files, options).map((s) => s.name);
const binned = (files: string[], options = {}) => stepsFor(files, options).filter((s) => s.bin);
/** The Godot step, however many other steps also run `node`. */
const gameStep = (files: string[], options = {}) => stepsFor(files, options)
  .find((s) => s.args?.includes('scripts/test-game.mjs'));

describe('test:affected — ein Spiel', () => {
  it('fährt die Suiten dieses Spiels und sonst nichts', () => {
    const steps = stepsFor(['godot/src/game/tetris/tetris_screen.gd']);
    const game = steps.find((s) => s.bin === 'node' && s.args?.[0] === 'scripts/test-game.mjs');
    expect(game?.args).toEqual(['scripts/test-game.mjs', '--scope', 'tetris']);
    expect(game?.suites).toBe(9);
    // No TypeScript was touched, so neither the typechecker nor the Node suite
    // has anything to say about a GDScript file.
    expect(names(['godot/src/game/tetris/tetris_screen.gd'])).not.toContain('npm test');
    expect(names(['godot/src/game/tetris/tetris_screen.gd'])).not.toContain('typecheck');
  });

  it('nennt eine Variante als ihren Basis-Scope', () => {
    const game = gameStep(['godot/src/game/crystal3d/crystal_screen.gd']);
    expect(game?.args).toEqual(['scripts/test-game.mjs', '--scope', 'crystal3d']);
  });

  it('sagt, warum es diese Suiten fährt', () => {
    // "Why was this run?" is the question the tool answers; a plan without a
    // reason is a plan nobody can check against `git status`.
    const game = gameStep(['godot/src/game/tetris/tetris_screen.gd']);
    expect(game?.reasons?.length).toBeGreaterThan(0);
  });
});

describe('test:affected — geteilte Fläche', () => {
  /**
   * The three cases that legitimately cost the whole 42 s, and each of them has
   * been a real bug report rather than a precaution: `game_registry.gd` is read
   * by every screen, `core/ui/` holds the base class every 3D screen extends,
   * and a file no scope claims is a file nobody proved anything about.
   */
  it('fährt den vollen Katalog, wenn eine geteilte Datei geändert wurde', () => {
    const game = gameStep(['godot/src/core/logic/game_registry.gd']);
    expect(game?.args).toEqual(['scripts/test-game.mjs']);
    expect(game?.reasons?.join(' ')).toContain('game_registry.gd');
  });

  it('fährt den vollen Katalog, wenn das Fundament geändert wurde', () => {
    const game = gameStep(['godot/src/core/ui/widgets.gd']);
    expect(game?.args).toEqual(['scripts/test-game.mjs']);
    expect(game?.reasons?.join(' ')).toContain('Fundament');
  });

  it('fährt den vollen Katalog, wenn niemand die Datei besitzt', () => {
    const game = gameStep(['godot/src/game/erfunden/x.gd']);
    expect(game?.args).toEqual(['scripts/test-game.mjs']);
  });

  /**
   * A `.uid` sibling of a file nobody edited, an imported asset, the scene
   * shell: no scope claims them, and none of them can change what a game does.
   * Running the catalogue for them would train the agent to ignore the tool.
   */
  it('blendet die harmlosen herrenlosen Dateien aus', () => {
    // Nothing but the two mirror checks, which run in every plan anyway.
    expect(binned(['godot/src/main.gd.uid']).map((s) => s.name)).toEqual(['content:check', 'locale:check']);
    expect(names(['godot/assets/fonts/DejaVuSans.ttf'])).toHaveLength(2);
  });
});

describe('test:affected — TypeScript', () => {
  it('fährt typecheck und den Node-Teil', () => {
    expect(names(['server/scopes.ts'])).toEqual(expect.arrayContaining(['typecheck', 'npm test']));
  });

  it('fährt bei einer Konfigurationsdatei den ganzen Node-Teil', () => {
    // `tsconfig.json` decides what every other TypeScript change means, so
    // there is nothing on that side to narrow down to. It still says nothing
    // about a GDScript file, so no Godot test runs for it.
    expect(names(['tsconfig.json'])).toEqual(expect.arrayContaining(['typecheck', 'npm test']));
    expect(gameStep(['tsconfig.json'])).toBeUndefined();
  });

  it('nennt den Grund, warum der Node-Teil nicht eingegrenzt wird', () => {
    // The honest reason, in the report: `vitest related` follows static imports
    // and this tree reaches its own scripts through `createRequire`.
    const step = stepsFor(['server/scopes.ts']).find((s) => s.name === 'npm test');
    expect(step?.reasons?.join(' ')).toContain('createRequire');
  });
});

describe('test:affected — Katalog und Content', () => {
  it('fährt für ein Content-Paket die Content-Suiten und nicht den Rest', () => {
    const steps = stepsFor(['content/enemies.json']);
    const vitest = steps.find((s) => s.bin === 'npx' && s.args?.[0] === 'vitest');
    expect(vitest?.args).toEqual(['vitest', 'run', 'tests/content.test.ts', 'tests/contentStore.test.ts']);
    const game = gameStep(['content/enemies.json']);
    expect(game?.args).toEqual(['scripts/test-game.mjs', '--scope', 'content']);
  });

  it('fährt für einen Sprachkatalog die Sprachsuiten von core', () => {
    // Sixteen language suites live in `core` and in no other scope: a catalogue
    // change that only ran `locale:check` would prove the catalogue parses.
    const game = gameStep(['locale/de.json']);
    expect(game?.args).toEqual(['scripts/test-game.mjs', '--scope', 'core']);
  });

  it('nennt den Sprachextraktor beim Node-Teil', () => {
    const vitest = stepsFor(['scripts/locale.mjs']).find((s) => s.bin === 'npx');
    expect(vitest?.args).toEqual(['vitest', 'run', 'tests/locale.test.ts']);
  });

  it('prüft beide Spiegel in jedem Plan, sie kosten zusammen 0,4 s', () => {
    // The one thing that is never narrowed: a mirror that drifted from its
    // source is invisible to every other check in the tree.
    for (const files of [[], ['README.md'], ['godot/src/game/tetris/tetris_screen.gd']]) {
      const steps = stepsFor(files);
      expect(steps.find((s) => s.name === 'content:check')?.args).toEqual(['scripts/sync-content.mjs', '--check']);
      expect(steps.find((s) => s.name === 'locale:check')?.args).toEqual(['scripts/locale.mjs', 'check']);
    }
  });
});

describe('test:affected — der volle Lauf', () => {
  it('ist der Katalog, den ein Release braucht', () => {
    expect(names(['README.md'], { full: true })).toEqual([
      'content:check', 'locale:check', 'typecheck', 'npm test', 'Spieltests',
    ]);
  });

  it('kommt ohne node_modules aus, ohne es zu überspringen', () => {
    // Skipping the two JavaScript steps silently would report a green plan that
    // checked nothing — the same objection the gate had about its own list.
    expect(names(['README.md'], { full: true, hasNodeModules: false })).toEqual([
      'content:check', 'locale:check', 'Spieltests',
    ]);
  });

  it('ist derselbe Katalog, den der Merge-Gate fährt, wenn er vollständig will', () => {
    expect(fullSteps(true).map((s) => s.name)).toEqual(names(['README.md'], { full: true }));
  });
});

describe('changedFiles', () => {
  const temps: string[] = [];
  const repo = () => {
    const dir = mkdtempSync(join(tmpdir(), 's80-affected-'));
    temps.push(dir);
    const git = (...args: string[]) => spawnSync('git', ['-C', dir, ...args], { encoding: 'utf8' });
    git('init', '-q', '-b', 'main');
    git('config', 'user.email', 't@example.com');
    git('config', 'user.name', 'Test');
    writeFileSync(join(dir, 'a.gd'), 'a\n');
    git('add', 'a.gd');
    git('commit', '-qm', 'erster');
    return dir;
  };

  it('sieht eine uncommittete Änderung und eine neue Datei', () => {
    const dir = repo();
    writeFileSync(join(dir, 'a.gd'), 'a2\n');
    writeFileSync(join(dir, 'b.gd'), 'b\n');
    expect(changedFiles({ cwd: dir })).toEqual(['a.gd', 'b.gd']);
  });

  it('sieht eine Änderung seit einem Commit, auch eine bereits committete', () => {
    // The case the gate depends on: the work is committed, so `git status` is
    // empty and only the difference against the base shows it.
    const dir = repo();
    writeFileSync(join(dir, 'a.gd'), 'a2\n');
    spawnSync('git', ['-C', dir, 'commit', '-aqm', 'zweiter']);
    expect(changedFiles({ cwd: dir })).toEqual([]);
    expect(changedFiles({ cwd: dir, base: 'HEAD~1' })).toEqual(['a.gd']);
  });

  it('findet ohne Repository nichts, statt zu raten', () => {
    const dir = mkdtempSync(join(tmpdir(), 's80-plain-'));
    temps.push(dir);
    mkdirSync(join(dir, 'godot', 'src'), { recursive: true });
    expect(changedFiles({ cwd: dir })).toEqual([]);
    rmSync(dir, { recursive: true, force: true });
  });

  it('nimmt die genannten Dateien, wenn welche genannt sind', () => {
    expect(changedFiles({ files: ['godot/src/game/tetris/tetris_screen.gd'], cwd: '/tmp' }))
      .toEqual(['godot/src/game/tetris/tetris_screen.gd']);
  });
});