import { spawn } from 'node:child_process';
import { findOpencodeBinary } from './runner';

/**
 * The model list the settings dialog offers, with the effort levels each model
 * really accepts.
 *
 * Two sources, because neither one knows what the runner needs:
 *
 *  - **Which models exist** comes from `opencode models`. That is opencode's own
 *    answer on this machine, credentials included, so the list cannot name a model
 *    the owner cannot run.
 *  - **Which effort levels a model accepts** comes from the public catalog at
 *    `https://models.opencode.ai/api.json`, which opencode itself downloads (the
 *    URL is in its binary, next to the code that derives the variants from it).
 *    Per model it carries `reasoning_options[].values` — for
 *    `opencode-go/space-bunny-free` exactly `low, medium, high, xhigh, max`.
 *
 * **Why the split matters, and why effort cannot be a generic list.** Measured on
 * this machine: `opencode run --model 'opencode/nemotron-3.5-lightning-free#low'`
 * exits 1 with `Variant unavailable for opencode/nemotron-3.5-lightning-free: low`,
 * and the same for a level that does not exist (`#nope`) on a model that does
 * have levels. A wrong effort is not ignored — it kills the run before the first
 * token. So the effort list must be the model's own, which is what the catalog
 * provides and what a hand-written table would only ever approximate.
 *
 * Without the catalog the models are still offered, with no effort levels: a
 * network-less server must still be able to run, and the owner must never be
 * offered a combination that is known to fail.
 */

/** Where opencode gets its model catalog. Public, no credentials. */
export const CATALOG_URL = 'https://models.opencode.ai/api.json';

/** How long a model list stays fresh. Providers come and go; hours are enough. */
const MODELS_TTL_MS = 10 * 60_000;

/** The catalog changes far more rarely than the model list. */
const CATALOG_TTL_MS = 6 * 60 * 60_000;

/** How long `opencode models` may take before we answer without it. */
const MODELS_TIMEOUT_MS = 20_000;

/** How long the catalog download may take. */
const CATALOG_TIMEOUT_MS = 20_000;

export interface ModelChoice {
  /** `provider/model`, exactly as opencode spells it. */
  id: string;
  provider: string;
  /** The part after the slash. */
  model: string;
  /** Human name from the catalog; falls back to the id. */
  name: string;
  /** Reasoning levels this exact model accepts. Empty means "no effort selector". */
  efforts: string[];
  /** Context window in tokens, 0 when the catalog does not say. */
  context: number;
  /** USD per million input tokens; 0 for a free model. */
  costIn: number;
  /** USD per million output tokens; 0 for a free model. */
  costOut: number;
  /**
   * False when the catalog has no price for this model. It is the difference
   * between "free" and "unknown", and the two must not be sorted as one: a paid
   * model the catalog does not know would come last in a list of free ones.
   */
  priced: boolean;
}

interface CatalogModel {
  name?: string;
  reasoning_options?: { type?: string; values?: string[] }[];
  limit?: { context?: number };
  cost?: { input?: number; output?: number };
}

type Catalog = Record<string, { models?: Record<string, CatalogModel> }>;

/**
 * `opencode models` prints one `provider/model` per line. Anything else on the
 * output is a warning we do not care about, so a line without a slash is dropped
 * rather than guessed at.
 */
export function parseModelLines(stdout: string): string[] {
  const seen = new Set<string>();
  for (const raw of stdout.split('\n')) {
    const line = raw.trim();
    if (!line || line.includes(' ')) continue;
    if (!line.includes('/')) continue;
    seen.add(line);
  }
  return [...seen];
}

/** The effort levels of one catalog model, in the catalog's own order. */
export function catalogEfforts(entry: CatalogModel | undefined): string[] {
  if (!entry) return [];
  const efforts: string[] = [];
  for (const option of entry.reasoning_options ?? []) {
    if (option?.type !== 'effort') continue;
    for (const value of option.values ?? []) {
      if (typeof value === 'string' && !efforts.includes(value)) efforts.push(value);
    }
  }
  return efforts;
}

/**
 * Joins the two sources. A model opencode can run but the catalog does not know
 * stays in the list — with no effort levels, which is the honest state: we do not
 * know what it supports, and an unsupported level would kill the run.
 */
export function buildModelChoices(ids: string[], catalog: Catalog | null): ModelChoice[] {
  const choices: ModelChoice[] = [];
  for (const id of ids) {
    const slash = id.indexOf('/');
    const provider = id.slice(0, slash);
    const model = id.slice(slash + 1);
    const entry = catalog?.[provider]?.models?.[model];
    choices.push({
      id,
      provider,
      model,
      name: entry?.name || id,
      efforts: catalogEfforts(entry),
      context: entry?.limit?.context ?? 0,
      costIn: entry?.cost?.input ?? 0,
      costOut: entry?.cost?.output ?? 0,
      priced: entry?.cost != null,
    });
  }
  // By provider, then by name: the eye scans for "which provider", not for
  // "alphabetical". Inside a provider the paid models come first and the free
  // ones last — a free tier is the fallback choice, not the deliberate one — and
  // models the catalog has no price for stay with the free ones, because we do
  // not know what they cost.
  return choices.sort((a, b) => {
    if (a.provider !== b.provider) return a.provider.localeCompare(b.provider);
    const rank = (choice: ModelChoice) => (choice.priced && (choice.costIn > 0 || choice.costOut > 0) ? 0 : 1);
    const diff = rank(a) - rank(b);
    if (diff !== 0) return diff;
    return a.name.localeCompare(b.name);
  });
}

/** `provider/model#level` split into its two parts. */
export function splitModelSetting(value: string): { model: string; effort: string } {
  const hash = value.indexOf('#');
  if (hash < 0) return { model: value.trim(), effort: '' };
  return { model: value.slice(0, hash).trim(), effort: value.slice(hash + 1).trim() };
}

/** The inverse. An empty model means "let opencode choose", which is no flag. */
export function joinModelSetting(model: string, effort: string): string {
  const id = model.trim();
  const level = effort.trim();
  if (!id || !level) return id;
  return `${id}#${level}`;
}

/** Runs `opencode models` and returns its lines, or nothing if it does not work. */
export async function readModelIds(bin: string): Promise<string[]> {
  return new Promise((resolve) => {
    let out = '';
    let done = false;
    const finish = (value: string[]) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve(value);
    };
    const timer = setTimeout(() => finish([]), MODELS_TIMEOUT_MS);
    timer.unref?.();
    try {
      const child = spawn(bin, ['models'], { stdio: ['ignore', 'pipe', 'ignore'] });
      child.stdout.setEncoding('utf8');
      child.stdout.on('data', (chunk: string) => {
        out += chunk;
      });
      child.on('error', () => finish([]));
      child.on('close', () => finish(parseModelLines(out)));
    } catch {
      finish([]);
    }
  });
}

interface Cache<T> {
  value: T | null;
  at: number;
  /** Set when the last attempt failed while an older value is still served. */
  stale: boolean;
}

const modelsCache: Cache<string[]> = { value: null, at: 0, stale: false };
const catalogCache: Cache<Catalog> = { value: null, at: 0, stale: false };
let inFlight: Promise<ModelChoice[]> | null = null;

/** Downloads the catalog. `null` means "no idea", never a guessed answer. */
export async function readCatalog(url = CATALOG_URL): Promise<Catalog | null> {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(CATALOG_TIMEOUT_MS) });
    if (!response.ok) return null;
    const parsed = (await response.json()) as Catalog;
    return typeof parsed === 'object' && parsed !== null ? parsed : null;
  } catch {
    return null;
  }
}

/**
 * The list the settings dialog renders, from memory when it is fresh enough.
 *
 * Concurrent callers share one attempt: the dialog asks for the list every time
 * it opens, and two downloads of a 1 MB catalog for one click would be silly.
 */
export async function listModelChoices(options: { bin?: string; now?: number } = {}): Promise<ModelChoice[]> {
  const now = options.now ?? Date.now();
  const bin = options.bin ?? findOpencodeBinary();
  if (modelsCache.value && now - modelsCache.at < MODELS_TTL_MS) {
    return buildModelChoices(modelsCache.value, catalogCache.value);
  }
  if (!inFlight) {
    inFlight = (async () => {
      const [ids, catalog] = await Promise.all([
        readModelIds(bin),
        catalogCache.value && now - catalogCache.at < CATALOG_TTL_MS
          ? Promise.resolve(catalogCache.value)
          : readCatalog(),
      ]);
      if (ids.length > 0) {
        modelsCache.value = ids;
        modelsCache.at = Date.now();
        modelsCache.stale = false;
      } else {
        modelsCache.stale = true;
      }
      if (catalog) {
        catalogCache.value = catalog;
        catalogCache.at = Date.now();
        catalogCache.stale = false;
      } else {
        catalogCache.stale = true;
      }
      return buildModelChoices(modelsCache.value ?? [], catalogCache.value);
    })().finally(() => {
      inFlight = null;
    });
  }
  return inFlight;
}

/** Whether the effort levels came from the catalog, for the dashboard's note. */
export function catalogAvailable(): boolean {
  return catalogCache.value !== null;
}

/** Test seam: forgets what is in memory. */
export function resetModelCaches(): void {
  modelsCache.value = null;
  modelsCache.at = 0;
  modelsCache.stale = false;
  catalogCache.value = null;
  catalogCache.at = 0;
  catalogCache.stale = false;
  inFlight = null;
}