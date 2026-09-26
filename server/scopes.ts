/**
 * Bridge between the API and the scope manifest in `scripts/scopes.mjs`.
 *
 * The manifest is the single source of truth for "which file belongs to which
 * agent" and "which test suites a game owns". This module only *reads* it — it
 * never re-implements the globs, otherwise the dashboard would show a second,
 * drifting version of the ownership rules.
 *
 * Three jobs:
 *  1. expose the layout to the operator (which agent owns what),
 *  2. map a suggestion to the scope(s) its run will work on, and
 *  3. audit the files a finished run actually touched against that scope.
 */
import { createRequire } from 'node:module';
import { join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { RunEvent, ScopeAudit, ScopeInfo, ScopeManifest, ScopePrediction, Suggestion } from '../src/shared/types';

type ScopeKind = 'own' | 'shared';

interface RawScope {
  agent: string;
  label: string;
  own: string[];
  shared: string[];
  /** Set for scopes derived from `game_registry.gd`; static scopes have none. */
  dir?: string;
  suites?: string[];
  screens?: string[];
  aliasOf?: string;
}

type ScopeMap = Map<string, RawScope>;

interface Manifest {
  status: 'ok' | 'unavailable';
  error: string | null;
  sharedFiles: string[];
  buildScopes: () => ScopeMap;
  matchScope: (file: string, scope: RawScope) => ScopeKind | null;
  ownerOf: (file: string, scopes: ScopeMap) => string[];
  validate: (scopes?: ScopeMap) => string[];
}

/** Repository root as seen from `server/scopes.ts`. */
const projectRoot = fileURLToPath(new URL('..', import.meta.url));
const manifestPath = join(projectRoot, 'scripts', 'scopes.mjs');

let cached: Manifest | null = null;

/**
 * Loads the manifest synchronously.
 *
 * `scripts/scopes.mjs` is plain ESM without type declarations, so it cannot be
 * type-checked from here, and it cannot be awaited either: the runner needs the
 * ownership rules while it finalizes a run, inside a `child.on('close')` handler.
 * `createRequire` is the only synchronous ESM loader, and it is available on
 * every Node version this project can run on (it needs `node:sqlite`, i.e. ≥ 22).
 * A failure must never take the server down, so the caller gets a degraded
 * manifest that reports its own state through the API.
 */
export function loadManifest(): Manifest {
  if (cached) return cached;
  try {
    const require = createRequire(import.meta.url);
    const mod = require(manifestPath) as {
      SHARED_FILES?: string[];
      buildScopes?: Manifest['buildScopes'];
      matchScope?: Manifest['matchScope'];
      ownerOf?: Manifest['ownerOf'];
      validate?: Manifest['validate'];
    };
    if (typeof mod.buildScopes !== 'function') throw new Error('buildScopes() fehlt im Manifest');
    cached = {
      status: 'ok',
      error: null,
      sharedFiles: mod.SHARED_FILES ?? [],
      buildScopes: mod.buildScopes,
      matchScope: mod.matchScope ?? (() => null),
      ownerOf: mod.ownerOf ?? (() => []),
      validate: mod.validate ?? (() => []),
    };
  } catch (err) {
    cached = {
      status: 'unavailable',
      error: (err as Error).message,
      sharedFiles: [],
      buildScopes: () => new Map(),
      matchScope: () => null,
      ownerOf: () => [],
      validate: () => [],
    };
  }
  return cached;
}

/** Test seam: forget the cached manifest (used after changing the repo layout). */
export function resetManifestCache(): void {
  cached = null;
}

/** The whole layout, as the dashboard shows it. */
export function scopeManifest(): ScopeManifest {
  const manifest = loadManifest();
  let scopes: ScopeInfo[] = [];
  let problems: string[] = [];
  if (manifest.status === 'ok') {
    scopes = [...manifest.buildScopes()].map(([id, scope]) => ({
      id,
      agent: scope.agent,
      label: scope.label,
      own: scope.own,
      shared: scope.shared,
      suites: scope.suites ?? [],
      screens: scope.screens ?? [],
      aliasOf: scope.aliasOf ?? null,
    }));
    problems = manifest.validate();
  }
  return {
    status: manifest.status,
    error: manifest.error,
    scopes,
    sharedFiles: manifest.sharedFiles,
    problems,
  };
}

/**
 * Which categories of work belong to a non-game scope. `other` is deliberately
 * absent: it carries no information, so a suggestion in that category falls
 * through to the honest "assumption" below instead of pretending to be mapped.
 */
const CATEGORY_SCOPES: Record<string, string> = {
  content: 'content',
  mechanics: 'core',
  balance: 'core',
  ui: 'core',
  audio: 'core',
  bug: 'core',
};

/**
 * Maps a suggestion to the scope(s) its run should work on.
 *
 * A suggestion names a game ("mehr Bälle bei Tetris") far more often than it
 * names a file, so the game scopes are searched first — that is the case where
 * the mapping is trustworthy. A suggestion that only says "neuer Gegner" is a
 * content job, and one that says "der Knopf ist zu klein" belongs to the shared
 * core. When nothing matches, `core` is the honest fallback and the reason says
 * so, because a wrong scope should read as a guess and not as a fact.
 */
export function scopeForSuggestion(suggestion: Suggestion, siblings: Suggestion[] = []): ScopePrediction {
  const manifest = loadManifest();
  const empty: ScopePrediction = {
    suggestionId: suggestion.id,
    scopes: [],
    label: null,
    agent: null,
    reason:
      manifest.status === 'unavailable'
        ? 'Manifest nicht lesbar — Scope-Zuordnung nicht möglich'
        : 'Kein passender Scope gefunden',
    confidence: 'fallback',
  };
  if (manifest.status !== 'ok') return empty;

  const scopes = manifest.buildScopes();
  const text = `${suggestion.text} ${siblings.map((s) => s.text).join(' ')}`.toLowerCase();

  const games: string[] = [];
  for (const [id, scope] of scopes) {
    // `agent: game` alone is not enough: the `content` scope belongs to a game
    // agent too. Only a scope derived from the game registry has a `dir`, and
    // only those describe an actual game a suggestion can name.
    if (scope.agent !== 'game' || scope.aliasOf || !scope.dir) continue;
    if (matchesAnyGame(text, id, scope.dir)) games.push(id);
  }
  // Longest id first: "candy3d" must not win over a longer registry id.
  games.sort((a, b) => b.length - a.length);

  const categoryScope = CATEGORY_SCOPES[suggestion.category];
  // A content job on a named game legitimately touches both scopes: the game
  // directory and `content/`. Only the content one is exclusive, so both go in.
  const result = [...games];
  if (categoryScope && !result.includes(categoryScope)) result.push(categoryScope);
  if (result.length === 0) {
    result.push('core');
    return {
      suggestionId: suggestion.id,
      scopes: result,
      label: scopes.get('core')?.label ?? 'Kernlogik',
      agent: scopes.get('core')?.agent ?? 'build',
      reason: 'Kein Spiel und keine passende Kategorie genannt — Annahme: Kernlogik',
      confidence: 'fallback',
    };
  }

  const primary = result[0];
  return {
    suggestionId: suggestion.id,
    scopes: result,
    label: scopes.get(primary)?.label ?? primary,
    agent: scopes.get(primary)?.agent ?? null,
    reason:
      games.length > 0
        ? `Spiel „${games.join('“, „')}“ im Text genannt`
        : `Kategorie „${suggestion.category}“ → ${scopes.get(primary)?.label ?? primary}`,
    confidence: games.length > 0 ? 'explicit' : 'category',
  };
}

/** True when `needle` occurs in `text` as a whole word (no `2048er`, no `pang2`). */
function matchesAnyGame(text: string, id: string, dir?: string): boolean {
  const keywords = new Set<string>([id, id.replace(/-/g, ''), dir ?? '', (dir ?? '').replace(/_/g, '')]);
  for (const keyword of keywords) {
    if (keyword.length < 3) continue;
    if (hasWord(text, keyword.toLowerCase())) return true;
  }
  return false;
}

function hasWord(text: string, word: string): boolean {
  let from = 0;
  for (;;) {
    const at = text.indexOf(word, from);
    if (at < 0) return false;
    const before = at === 0 ? '' : text[at - 1];
    const after = text[at + word.length] ?? '';
    if (!/[\p{L}\p{N}_]/u.test(before) && !/[\p{L}\p{N}_]/u.test(after)) return true;
    from = at + 1;
  }
}

/** File extensions that can belong to a scope. Anything else is prose. */
const FILE_SUFFIXES = new Set([
  'gd', 'uid', 'ts', 'tsx', 'js', 'mjs', 'cjs', 'json', 'html', 'css', 'md', 'cfg', 'godot',
  'gdshader', 'gdshaderinc', 'tscn', 'tres', 'import', 'glb', 'gltf', 'fbx', 'obj', 'png', 'jpg',
  'svg', 'py', 'wasm', 'txt', 'csv', 'ttf', 'otf', 'wav', 'ogg', 'mp3', 'apk', 'yml', 'yaml', 'sh',
]);

/**
 * Files in the repository root. They have no `/`, so the generic path pattern
 * misses them — and two of them (`package.json`, `AGENTS.md`) are exactly the
 * shared files every agent has to treat with care.
 */
const ROOT_FILES = new Set([
  'package.json', 'package-lock.json', 'AGENTS.md', 'README.md', 'opencode.json', 'tsconfig.json',
  'vitest.config.ts', 'vite.config.ts', 'dashboard.html', 'index.html',
]);

/** Max entries kept per audit bucket; the dashboard shows a warning, not a diff. */
const AUDIT_LIMIT = 20;

/**
 * Pulls repository-relative file paths out of the run log.
 *
 * The log holds the agent's tool calls (`edit`/`write` with a `filePath`, `bash`
 * with a whole command line), so the paths are in there as plain text. This is
 * deliberately a heuristic: a scope violation is a warning for a human, and a
 * false negative costs nothing while a false positive only costs trust.
 */
export function extractTouchedFiles(events: readonly RunEvent[]): string[] {
  const found = new Set<string>();
  for (const event of events) {
    for (const source of [event.text, event.detail]) {
      if (!source) continue;
      for (const token of pathTokens(source)) {
        const normalized = normalizePath(token);
        if (normalized) found.add(normalized);
      }
    }
  }
  return [...found].sort();
}

/** All `a/b` style tokens plus known root files, stripped of trailing punctuation. */
function pathTokens(text: string): string[] {
  const out: string[] = [];
  for (const match of text.matchAll(/(^|[\s"'`([,=:])((?:[A-Za-z0-9_@.+-]+\/)+[A-Za-z0-9_@.+-]+)/g)) {
    out.push(match[2]);
  }
  for (const match of text.matchAll(/(?<![\w/.\-@])([A-Za-z0-9_@.-]+\.[A-Za-z0-9]{1,6})(?![A-Za-z0-9_/])/g)) {
    if (ROOT_FILES.has(match[1])) out.push(match[1]);
  }
  return out;
}

function normalizePath(raw: string): string | null {
  let file = raw.replace(/[.,;:)\]}'"]+$/, '');
  if (ROOT_FILES.has(file) && !file.includes('/')) return file;
  if (!file.includes('/') || file.startsWith('/') || file.startsWith('./') || file.startsWith('../')) {
    return null;
  }
  if (/^(?:https?|node_modules|proc|sys|dev|usr|etc|var|home)\//.test(file)) return null;
  const suffix = file.slice(file.lastIndexOf('.') + 1).toLowerCase();
  if (!FILE_SUFFIXES.has(suffix)) return null;
  // An absolute path inside the repository is rewritten, not dropped.
  const abs = resolve(projectRoot, file);
  const rel = relative(projectRoot, abs);
  if (!rel.startsWith('..')) file = rel.split(sep).join('/');
  return file;
}

/** Flags a `git add` without a file list, which is what the framework forbids. */
function hasCatchAllAdd(events: readonly RunEvent[]): boolean {
  return events.some((event) => {
    if (event.kind !== 'tool') return false;
    for (const match of event.text.matchAll(/\bgit\s+add\s+([^\n]*)/g)) {
      // Stop at the first shell separator: `git add -A && git commit` is one
      // catch-all add, not two commands.
      const rest = (match[1] ?? '').split(/&&|\|\||[;\n|]/)[0] ?? '';
      const args = rest.trim().split(/\s+/).filter(Boolean);
      if (args.length === 0) return true;
      if (args.every((arg) => arg === '.' || arg === '-A' || arg === '--all')) return true;
    }
    return false;
  });
}

export interface AuditInput {
  runId: string;
  /** Declared scopes of the run, most specific first. */
  scopes: string[];
  events: readonly RunEvent[];
  /** Manifest problems, so the dashboard can explain an empty audit. */
  manifestError?: string | null;
}

/**
 * Compares the files a run touched with the scope it declared. Same verdict the
 * pre-commit guard gives, so a green dashboard and a green `scopes.mjs check`
 * mean the same thing.
 */
export function auditScope(input: AuditInput): ScopeAudit {
  const manifest = loadManifest();
  const base: ScopeAudit = {
    runId: input.runId,
    scopes: input.scopes,
    agent: null,
    ok: true,
    violations: [],
    shared: [],
    unclaimed: [],
    notes: [],
    checked: 0,
  };
  if (manifest.status !== 'ok') {
    return {
      ...base,
      ok: false,
      notes: [
        manifest.error
          ? `Scope-Manifest nicht lesbar: ${manifest.error}`
          : 'Scope-Manifest nicht lesbar',
      ],
    };
  }
  const scopes = manifest.buildScopes();
  const declared = input.scopes.map((id) => scopes.get(id)).filter((s): s is RawScope => Boolean(s));
  const agent = declared[0]?.agent ?? null;
  const files = extractTouchedFiles(input.events);
  const violations: string[] = [];
  const shared: string[] = [];
  const unclaimed: string[] = [];
  for (const file of files) {
    const mine = declared.map((scope) => manifest.matchScope(file, scope));
    // `own` always wins: a variant scope shares the base screen directory with
    // its base scope, so a file can be own for one and shared for the other.
    if (mine.includes('own')) continue;
    // A file that another scope owns *exclusively* is a violation even when the
    // manifest also lists it as shared here. That combination is exactly the
    // registry-file case: `asset_registry.gd` is "shared" for a game scope and
    // "own" for the mesh agent, and touching it is a conflict, not a
    // collaboration. `scopes.mjs check` reports the softer word; the dashboard
    // has to be the louder one, because nobody reads a diff after the fact.
    const others = manifest.ownerOf(file, scopes);
    if (others.length) {
      violations.push(cap(`${file} → gehört ${others.map((o) => `„${o}“`).join(', ')}`));
      continue;
    }
    if (mine.includes('shared')) { shared.push(cap(file)); continue; }
    unclaimed.push(cap(file));
  }
  const notes: string[] = [];
  if (hasCatchAllAdd(input.events)) {
    notes.push('`git add` ohne Dateiliste — kann fremde Arbeit einsammeln, der Scope-Check umgeht das');
  }
  if (input.scopes.length > 0 && declared.length !== input.scopes.length) {
    const missing = input.scopes.filter((id) => !scopes.has(id));
    if (missing.length) notes.push(`Unbekannter Scope: ${missing.join(', ')}`);
  }
  if (input.manifestError) notes.push(input.manifestError);
  return {
    runId: input.runId,
    scopes: input.scopes,
    agent,
    ok: violations.length === 0,
    violations,
    shared: capAll(shared),
    unclaimed: capAll(unclaimed),
    notes,
    checked: files.length,
  };
}

function cap(text: string): string {
  return text.length > 160 ? `${text.slice(0, 157)}…` : text;
}

function capAll(list: string[]): string[] {
  if (list.length <= AUDIT_LIMIT) return list;
  return [...list.slice(0, AUDIT_LIMIT), `… und ${list.length - AUDIT_LIMIT} weitere`];
}
