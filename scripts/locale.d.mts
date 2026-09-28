/**
 * Types for `scripts/locale.mjs`.
 *
 * The script is plain JavaScript because it is a maintenance tool, not part of
 * the app — but `tests/locale.test.ts` imports it and `tsconfig.json` includes
 * `tests`, so the imports need a shape. Hand-written rather than generated: five
 * exports is a smaller statement than a build step, and the interesting part —
 * what `collect()` found and what `coverage()` counts — is documented here
 * instead of being inferred from a signature nobody reads.
 */

/** One language catalogue, as `locale/<code>.json` holds it. */
export interface LocaleCatalogue {
  code: string;
  /** The language's name in English, for logs and reports. */
  name: string;
  /** The name the language calls itself: "Deutsch", "English", "Français". */
  native: string;
  note?: string;
  numbers: { decimal: string; group: string; percent?: string };
  /** Hand-written identifiers, `ui.back_to_lobby` → German text. */
  keys: Record<string, string | Record<string, string>>;
  /** The German source strings as their own keys. */
  text: Record<string, string>;
}

/** What one half of a catalogue contributes to a coverage figure. */
export interface CoveragePart {
  /** Entries that differ from the German source. */
  done: number;
  /** Entries that can be translated, i.e. excluding the equal-on-purpose ones. */
  total: number;
  /** Entries `identical.json` says stay equal. */
  same: number;
  /** `total - done`: genuinely untranslated. */
  open: number;
}

export interface Coverage extends CoveragePart {
  keys: CoveragePart;
  text: CoveragePart;
  percent: number;
}

/** What the generator found in the code. */
export interface Collected {
  keys: Map<string, string>;
  text: Map<string, string>;
  /** `Loc.f` templates that look like an identifier — almost always a slip. */
  locF: { value: string; rel: string }[];
}

/** The language the source is written in; everything else translates it. */
export const SOURCE: string;

export function isDisplayText(value: string, kind: 'text' | 'key'): boolean;
export function collect(): Collected;
export function formatMismatches(text: string, file: string): string[];
export function formatMismatchesInProject(): string[];
export function readAll(): Map<string, LocaleCatalogue>;
export function coverage(
  catalogue: LocaleCatalogue,
  source: LocaleCatalogue,
  identical?: Set<string>,
): Coverage;
export function identicalSet(all: Map<string, LocaleCatalogue>, code: string): Set<string>;
