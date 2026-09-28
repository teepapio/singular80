import { afterEach, describe, expect, it, vi } from 'vitest';
import { mkdtempSync, rmSync, statSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ContentStore } from '../server/content';

/**
 * `ContentStore` is what `GET /api/content` serves and what the runner reads
 * before it hands out a scope. Its only real logic is a cache keyed on the
 * newest mtime of the five files, plus the decision of what to do with a file
 * that is unreadable. Both are invisible in a passing run: a stale cache shows up
 * as a content change that never arrives, and a broken file shows up as a game
 * with no enemies.
 */

const dirs: string[] = [];

function contentDir(files: Record<string, unknown> = {}): string {
  const dir = mkdtempSync(join(tmpdir(), 's80-content-'));
  dirs.push(dir);
  for (const [name, value] of Object.entries(files)) {
    writeFileSync(join(dir, `${name}.json`), JSON.stringify(value), 'utf8');
  }
  return dir;
}

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
  vi.restoreAllMocks();
});

describe('ContentStore.load', () => {
  it('liest die fünf Packdateien als Array', () => {
    const store = new ContentStore(contentDir({ enemies: [{ id: 'slime' }], mechanics: [] }));
    const pack = store.load();
    expect(pack.enemies).toEqual([{ id: 'slime' }]);
    expect(pack.weapons).toEqual([]);
    expect(pack.version).toBeGreaterThan(0);
  });

  it('überlebt ein leeres Verzeichnis', () => {
    // A fresh checkout without `npm run content:sync` must not throw; the dashboard
    // then shows empty lists instead of a 500.
    const pack = new ContentStore(contentDir()).load();
    expect(pack).toMatchObject({ enemies: [], weapons: [], upgrades: [], modes: [], mechanics: [] });
    expect(pack.version).toBe(0);
  });

  it('gibt dasselbe Objekt zurück, solange sich nichts ändert', () => {
    const store = new ContentStore(contentDir({ weapons: [{ id: 'pistol' }] }));
    const first = store.load();
    // Identity, not just equality: a fresh object per request would make the
    // cache pointless and hide the mtime logic behind an accident.
    expect(store.load()).toBe(first);
  });

  it('liest neu, sobald eine Datei wirklich neuer ist', () => {
    const dir = contentDir({ weapons: [{ id: 'pistol' }] });
    const store = new ContentStore(dir);
    expect(store.load().weapons).toHaveLength(1);
    writeFileSync(join(dir, 'weapons.json'), JSON.stringify([{ id: 'pistol' }, { id: 'burst' }]), 'utf8');
    // Explicit mtime: the cache is keyed on it, and a filesystem with a one-second
    // resolution would otherwise hide the change for the length of a second.
    const future = new Date(Date.now() + 5000);
    utimesSync(join(dir, 'weapons.json'), future, future);
    expect(store.load().weapons.map((w) => w.id)).toEqual(['pistol', 'burst']);
  });

  it('sieht auch eine Änderung an einer anderen der fünf Dateien', () => {
    const dir = contentDir({ modes: [{ id: 'classic' }] });
    const store = new ContentStore(dir);
    const before = store.load().version;
    writeFileSync(join(dir, 'modes.json'), JSON.stringify([{ id: 'classic' }, { id: 'hardcore' }]), 'utf8');
    const future = new Date(Date.now() + 5000);
    utimesSync(join(dir, 'modes.json'), future, future);
    const after = store.load();
    expect(after.modes).toHaveLength(2);
    expect(after.version).not.toBe(before);
  });

  it('liest auf `force` auch ohne Änderung neu', () => {
    // The "Neu laden" button of the dashboard goes through this.
    const dir = contentDir({ enemies: [{ id: 'slime' }] });
    const store = new ContentStore(dir);
    const first = store.load();
    expect(store.load(true)).not.toBe(first);
    expect(store.load(true).enemies).toEqual([{ id: 'slime' }]);
  });

  it('meldet kaputtes JSON laut, statt den Server mit einem leeren Paket zu Antworten', () => {
    // The file is edited by hand and by agents. A syntax error used to be logged
    // at most and answered with HTTP 200 and an empty list, which is the worst
    // of both: the device silently ran on no content and nothing said so. A
    // broken pack now throws, and the client keeps the data it already has.
    const dir = contentDir({ weapons: [{ id: 'pistol' }] });
    writeFileSync(join(dir, 'enemies.json'), '{ kaputt', 'utf8');
    const err = vi.spyOn(console, 'error').mockImplementation(() => {});
    expect(() => new ContentStore(dir).load()).toThrow(/enemies\.json/);
    expect(err).toHaveBeenCalled();
  });

  it('schluckt eine Datei, die kein Array ist, ohne zu raten', () => {
    // `load` accepts an object here and hands it on; the consumer is the one that
    // has to cope. What matters is that the store does not invent content.
    const dir = contentDir({ modes: { unexpected: true } });
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const pack = new ContentStore(dir).load();
    expect(pack.modes).toEqual({ unexpected: true });
    expect(warn).not.toHaveBeenCalled();
  });

  it('schweigt über eine fehlende Datei', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    new ContentStore(contentDir({ enemies: [] })).load();
    // ENOENT is normal — `mechanics.json` is optional — and a warning per missing
    // file would fill the log of every start.
    expect(warn).not.toHaveBeenCalled();
  });

  it('ändert die Version bei jeder Byte-Änderung, nicht nur bei der neuesten Datei', () => {
    // The version is what the game compares to decide whether to reload. It used
    // to be the newest mtime, so editing an *older* file changed nothing and the
    // device stayed behind for ever. It is a hash of the content now.
    const dir = contentDir({ enemies: [{ id: 'a' }], weapons: [{ id: 'b' }] });
    const store = new ContentStore(dir);
    const first = store.load().version;
    // A touch in the past, so the newest file is `weapons.json` and the edited
    // one is the older — the case the old key got wrong.
    const older = new Date(Date.now() - 60_000);
    utimesSync(join(dir, 'enemies.json'), older, older);
    writeFileSync(join(dir, 'enemies.json'), JSON.stringify([{ id: 'a2' }]), 'utf8');
    const bumped = store.load();
    expect(bumped.version).not.toBe(first);
    expect(bumped.enemies).toEqual([{ id: 'a2' }]);
  });
});
