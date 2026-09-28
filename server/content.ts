import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import type { ContentPack } from '../src/shared/types';

const FILES = ['enemies', 'weapons', 'upgrades', 'modes', 'mechanics'] as const;

type FileName = (typeof FILES)[number];

interface RawPack {
  /** File text per section. A missing file has no entry. */
  text: Partial<Record<FileName, string>>;
  /** Parsed value per section. */
  value: Partial<Record<FileName, unknown>>;
}

/**
 * The identity of a set of sources.
 *
 * Content-hashed rather than timestamped. `version` used to be
 * `Math.floor(max mtime)` over the five files, and that has two defects: editing
 * a file that is not the newest one leaves the version exactly where it was — a
 * client keyed on the version would serve stale content forever — and a
 * restored checkout can land on a stamp a client has already cached. A hash of
 * the bytes changes if and only if the content does, and survives a restart.
 */
function signatureOf(raw: RawPack): string {
  const hash = createHash('sha1');
  for (const name of FILES) hash.update(`${name}\n${raw.text[name] ?? ''}\n`);
  return hash.digest('hex');
}

/**
 * The cache key a client puts in front of the pack.
 *
 * A number, because the client's `version` is an int, and at most 2^32 — well
 * inside a float, so it survives JSON. Zero means "nothing to serve", which is
 * what the client expects for its own bundled content.
 */
function versionOf(signature: string, fileCount: number): number {
  if (fileCount === 0) return 0;
  return parseInt(signature.slice(0, 8), 16);
}

function describe(value: unknown): string {
  if (value === null) return 'null';
  return `${typeof value} (${JSON.stringify(value)?.slice(0, 40) ?? '?'})`;
}

export class ContentStore {
  readonly dir: string;
  private cache: ContentPack | null = null;
  private signature = '';

  constructor(dir: string) {
    this.dir = dir;
  }

  /**
   * The content pack, or a throw.
   *
   * A syntax error or a value that is neither a list nor a record used to leave
   * the shared empty arrays in place: HTTP 200, five empty lists, at most one
   * `console.warn`. The game ignores an empty list and keeps what it shipped
   * with, so a broken `content/*.json` looked exactly like "the server has
   * nothing new" and stayed that way for as long as nobody read the log. Now it
   * is a 500 with the file name in it, and the client falls back to its bundled
   * content, which is the right fallback anyway.
   *
   * A *missing* file stays quiet: a section that does not exist is a section the
   * game does not have, and `mechanics.json` is optional.
   *
   * `force` re-reads the files. They are a few kilobytes in total, so the cache
   * is keyed by their content and a forced reload cannot disagree with the
   * signature.
   */
  load(force = false): ContentPack {
    const raw = this.read();
    const signature = signatureOf(raw);
    if (!force && this.cache && signature === this.signature) return this.cache;
    const pack: ContentPack = {
      version: versionOf(signature, Object.keys(raw.value).length),
      enemies: [],
      weapons: [],
      upgrades: [],
      modes: [],
      mechanics: [],
    };
    for (const name of FILES) {
      const value = raw.value[name];
      if (value === undefined) continue;
      (pack as unknown as Record<string, unknown>)[name] = value;
    }
    this.cache = pack;
    this.signature = signature;
    return pack;
  }

  /** Reads and parses the files that are there, or explains which one is broken. */
  private read(): RawPack {
    const raw: RawPack = { text: {}, value: {} };
    const broken: string[] = [];
    for (const name of FILES) {
      const path = join(this.dir, `${name}.json`);
      let text: string;
      try {
        text = readFileSync(path, 'utf8');
      } catch (err) {
        // A missing section is not a defect; anything else (permissions, a
        // directory in its place) is, and it must not look like "no content".
        if ((err as NodeJS.ErrnoException).code !== 'ENOENT') {
          broken.push(`${path} nicht lesbar (${(err as Error).message})`);
        }
        continue;
      }
      let value: unknown;
      try {
        value = JSON.parse(text);
      } catch (err) {
        broken.push(`${path} kein gültiges JSON (${(err as Error).message})`);
        continue;
      }
      if (value === null || typeof value !== 'object') {
        // A file that parses to `3` or `"x"` is a typo, and it used to be served
        // as an empty section without a word.
        broken.push(`${path} erwartet eine Liste oder ein Objekt, gefunden ${describe(value)}`);
        continue;
      }
      raw.text[name] = text;
      raw.value[name] = value;
    }
    if (broken.length > 0) {
      const message = `[content] kaputtes Content-Paket in ${this.dir}: ${broken.join('; ')}`;
      console.error(message);
      throw new Error(message);
    }
    return raw;
  }
}
