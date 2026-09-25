import { readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import type { ContentPack } from '../src/shared/types';

const FILES = ['enemies', 'weapons', 'upgrades', 'modes', 'mechanics'] as const;

const EMPTY: ContentPack = {
  version: 0,
  enemies: [],
  weapons: [],
  upgrades: [],
  modes: [],
  mechanics: [],
};

export class ContentStore {
  readonly dir: string;
  private cache: ContentPack | null = null;
  private stamp = 0;

  constructor(dir: string) {
    this.dir = dir;
  }

  private mtime(): number {
    let max = 0;
    for (const name of FILES) {
      try {
        max = Math.max(max, statSync(join(this.dir, `${name}.json`)).mtimeMs);
      } catch {
        /* missing file is fine */
      }
    }
    return max;
  }

  load(force = false): ContentPack {
    const stamp = this.mtime();
    if (!force && this.cache && stamp === this.stamp) return this.cache;
    const pack: ContentPack = { ...EMPTY, version: 0 };
    for (const name of FILES) {
      try {
        const raw = readFileSync(join(this.dir, `${name}.json`), 'utf8');
        const parsed = JSON.parse(raw);
        if (Array.isArray(parsed)) {
          (pack as unknown as Record<string, unknown>)[name] = parsed;
        } else if (parsed && typeof parsed === 'object') {
          (pack as unknown as Record<string, unknown>)[name] = parsed;
        }
      } catch (err) {
        if ((err as NodeJS.ErrnoException).code !== 'ENOENT') {
          console.warn(`[content] failed to load ${name}.json:`, (err as Error).message);
        }
      }
    }
    pack.version = Math.floor(stamp);
    this.cache = pack;
    this.stamp = stamp;
    return pack;
  }
}
