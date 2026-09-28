import type {
  ScoreBreakdown,
  Suggestion,
  SuggestionCategory,
  SuggestionStatus,
  SuggestionView,
} from './types';

/**
 * Stop words, in **folded** form.
 *
 * `foldText` spells every umlaut out (`ü` → `ue`) before anything looks at a
 * word, so the entry for "für" is `fuer` — and `für` itself can never match
 * anything. It is not a variant, it is dead code. An earlier version of this
 * list carried both spellings, which reads like a safety net and is nothing of
 * the kind. Write the folded spelling here, and take it from `foldText` rather
 * than from the keyboard: "müssen" folds to `muessen`, not to `muessten`.
 */
const STOPWORDS = new Set([
  'der', 'die', 'das', 'den', 'dem', 'des', 'ein', 'eine', 'einen', 'einem', 'einer', 'eines',
  'und', 'oder', 'aber', 'mit', 'ohne', 'fuer', 'von', 'vom', 'zum', 'zur', 'auf', 'aus',
  'bei', 'nach', 'vor', 'ueber', 'unter', 'durch', 'gegen', 'ist', 'sind', 'war', 'waere',
  'wird', 'werden', 'kann', 'koennen', 'soll', 'sollen', 'sollte', 'muss', 'muessen', 'mussten',
  // 'zu' belongs here: it is half of what makes "Level zu schwer" and "Level zu
  // leicht" look alike, and it carries no meaning of its own.
  'zu', 'ich', 'du', 'er', 'sie', 'es', 'wir', 'ihr', 'man', 'mehr', 'sehr',
  'auch', 'dann', 'noch', 'nur', 'schon', 'bitte', 'mal', 'halt', 'eben', 'dass', 'weil',
  'wenn', 'als', 'wie', 'was', 'wer', 'wo', 'da', 'hier', 'dort', 'so', 'im', 'in', 'an', 'am',
  'es', 'to', 'the', 'a', 'an', 'and', 'or', 'but', 'with', 'without', 'for', 'from', 'of',
  'at', 'by', 'after', 'before', 'over', 'under', 'through', 'against', 'is', 'are', 'was',
  'were', 'will', 'would', 'can', 'could', 'should', 'must', 'i', 'you', 'he', 'she', 'it',
  'we', 'they', 'more', 'very', 'also', 'then', 'still', 'only', 'already', 'please', 'just',
  'that', 'because', 'if', 'than', 'as', 'what', 'who', 'where', 'there', 'here', 'so', 'add',
  'please', 'should', 'would', 'could', 'make', 'made', 'get', 'got',
]);

export function foldText(input: string): string {
  return input
    // NFC first, and the order matters. A decomposed `ü` (a `u` plus U+0308,
    // which is what an Android IME, a PDF or a copy out of a web page produces)
    // has no `ü` left for the replacement below to find, and the NFKD step then
    // throws its combining mark away: `u`. The precomposed spelling of the very
    // same word folds to `ue`. One word, two foldings — and the similarity of
    // the text with itself was 0.609 instead of 1.0.
    .normalize('NFC')
    .toLowerCase()
    .replace(/ä/g, 'ae')
    .replace(/ö/g, 'oe')
    .replace(/ü/g, 'ue')
    .replace(/ß/g, 'ss')
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9\s]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function stemToken(token: string): string {
  const suffixes = ['ern', 'en', 'er', 'es', 'e', 's', 'n', 't'];
  for (const suffix of suffixes) {
    if (token.length - suffix.length >= 4 && token.endsWith(suffix)) {
      return token.slice(0, token.length - suffix.length);
    }
  }
  return token;
}

export function tokenize(input: string): string[] {
  const folded = foldText(input);
  if (!folded) return [];
  return folded
    .split(' ')
    .filter((t) => t.length >= 2 && !STOPWORDS.has(t))
    .map(stemToken);
}

function trigrams(input: string): Set<string> {
  const s = ` ${foldText(input)} `.replace(/\s+/g, ' ');
  const grams = new Set<string>();
  for (let i = 0; i + 2 < s.length; i++) grams.add(s.slice(i, i + 3));
  return grams;
}

export function diceTrigram(a: string, b: string): number {
  const ga = trigrams(a);
  const gb = trigrams(b);
  if (ga.size === 0 || gb.size === 0) return 0;
  let inter = 0;
  for (const g of ga) if (gb.has(g)) inter++;
  return (2 * inter) / (ga.size + gb.size);
}

/**
 * Share of the **shorter** text that the longer one repeats.
 *
 * The denominator is `min`, not the union, on purpose: a three-word "Neuer
 * Slime Gegner" has to be able to join the cluster of the long paragraph about
 * the same slime, and a union-based coefficient would score that 0.29. The
 * price is that two short texts sharing two of three tokens reach 0.67 on this
 * half alone, which is what let opposite-meaning pairs through — `CONTRAST_PAIRS`
 * is the answer to that, not a bigger denominator.
 */
export function overlapCoefficient(a: string[], b: string[]): number {
  if (a.length === 0 || b.length === 0) return 0;
  const sa = new Set(a);
  const sb = new Set(b);
  let inter = 0;
  for (const t of sa) if (sb.has(t)) inter++;
  return inter / Math.min(sa.size, sb.size);
}

/**
 * One word, in every form a text can spell it: the folded word itself and its
 * stem. `schwerer` and "schwer" have to land on the same key, and the plain
 * folded word is kept beside the stem because the token list drops stop words
 * and with them the direction: "mehr Bälle" and "weniger Bälle" reach the
 * score as `ball` and `wenig ball` — one word apart, and exactly opposite.
 */
function wordForms(input: string): ReadonlySet<string> {
  const folded = foldText(input);
  const forms = new Set<string>();
  if (!folded) return forms;
  for (const word of folded.split(' ')) {
    forms.add(word);
    forms.add(stemToken(word));
  }
  return forms;
}

function contrast(words: string[]): ReadonlySet<string> {
  const forms = new Set<string>();
  for (const word of words) {
    const folded = foldText(word);
    forms.add(folded);
    forms.add(stemToken(folded));
  }
  return forms;
}

/**
 * Words that cancel each other out, in the same plain spelling the category
 * rules use — both sides are folded and stemmed once, at module load, so
 * "schwer" and "schwierig" do not have to be written twice and "groß" does not
 * have to be pre-folded by hand.
 */
const CONTRAST_PAIRS: ReadonlyArray<readonly [ReadonlySet<string>, ReadonlySet<string>]> = [
  [contrast(['schwer', 'schwierig', 'hard']), contrast(['leicht', 'einfach', 'easy'])],
  [contrast(['stark', 'overpower']), contrast(['schwach', 'underpower'])],
  [contrast(['viel', 'viele', 'mehr', 'mehrere']), contrast(['wenig', 'wenige', 'weniger'])],
  [contrast(['groß', 'grosse', 'grossen']), contrast(['klein', 'kleine', 'kleinen'])],
  [contrast(['schnell', 'schneller']), contrast(['langsam', 'langsamer'])],
  [contrast(['laut', 'lauter']), contrast(['leise', 'leiser'])],
  [contrast(['hoch', 'höher']), contrast(['tief', 'tiefen'])],
  [contrast(['vorne']), contrast(['hinten'])],
];

function hasAny(words: ReadonlySet<string>, group: ReadonlySet<string>): boolean {
  for (const word of group) if (words.has(word)) return true;
  return false;
}

/**
 * True when one text asks for the opposite of what the other asks for.
 *
 * "Level zu schwer" and "Level zu leicht" share a topic, a game and a sentence
 * shape; only the direction differs, and clustering them hands the runner one
 * job that quietly contradicts the other. No amount of shared vocabulary makes
 * them the same request, so this runs before the threshold and before the dice.
 */
function contradicts(a: string, b: string): boolean {
  const left = wordForms(a);
  const right = wordForms(b);
  for (const [first, second] of CONTRAST_PAIRS) {
    if (hasAny(left, first) && hasAny(right, second)) return true;
    if (hasAny(left, second) && hasAny(right, first)) return true;
  }
  return false;
}

/**
 * How much two suggestions say the same thing, 0 … 1.
 *
 * Half token coverage, half character trigrams: the tokens find the same
 * request written with different words, the trigrams forgive the typos and the
 * "mehr Bälle bitte!" against "mehr baelle" of an Android keyboard. Opposite
 * requests are 0 by definition — see `CONTRAST_PAIRS`.
 */
export function similarity(a: string, b: string): number {
  if (contradicts(a, b)) return 0;
  const overlap = overlapCoefficient(tokenize(a), tokenize(b));
  const dice = diceTrigram(a, b);
  return 0.55 * overlap + 0.45 * dice;
}

/**
 * Two suggestions are the same request from this score on.
 *
 * The score is `0.55 * coverage + 0.45 * dice` (see `similarity`), and
 * `CLUSTER_THRESHOLD` stays at 0.35. That is a decision, not an oversight:
 * "Level zu schwer" against "Level zu leicht" measures 0.615, while the pair
 * this whole mechanism exists for — "Neuer Gegner: Slime der sich teilt"
 * against "Füge einen Slime Gegner hinzu, der in kleine Slimes zerfällt" —
 * sits barely above 0.35, and `tests/sorting.test.ts` pins exactly that.
 * Every threshold that separates the two also drops the duplicate, so the
 * opposite pair is caught by `CONTRAST_PAIRS` instead: it asks the question a
 * single number cannot, which is whether the two texts want opposite things.
 * Raising the constant means strengthening the duplicate case first — more
 * weight on the trigrams, or a fixture that says what "the same request" is
 * worth — not typing a bigger number here.
 */
export const CLUSTER_THRESHOLD = 0.35;

interface CategoryRule {
  category: SuggestionCategory;
  /** Stems, pre-folded and pre-stemmed: see `CATEGORY_RULES`. */
  words: ReadonlySet<string>;
  /** Folded phrases, matched as substrings of the folded text. */
  phrases: readonly string[];
}

/** Rule words are written plain and stemmed once, here. */
function stems(words: readonly string[]): ReadonlySet<string> {
  return new Set(words.map((w) => stemToken(foldText(w))));
}

function foldPhrases(list: readonly string[]): readonly string[] {
  return list.map((p) => foldText(p)).filter((p) => p.length > 0);
}

/**
 * The word lists, in the spelling a player would type.
 *
 * Two rules keep this table honest, and both were broken before:
 *
 * 1. **One tokenizer.** `classify` used to split the folded text on spaces while
 *    clustering stemmed and dropped stop words, so every rule had to be
 *    written unstemmed to match it — and a rule copied from `tokenize()` output
 *    ("Boss-Gegner Spawner" → `boss/gegn/spawn`) never matched anything, with
 *    no error anywhere. Both sides now go through `tokenize` and `stems`.
 * 2. **One category per word.** A word in two lists is a tie, and ties were
 *    broken by array order, which put "Die Musik ist zu laut" in `content` and
 *    "Neue Musik bitte" in `audio` — and the category is what `CATEGORY_SCOPES`
 *    turns into the agent that runs the job. `musik`, `music` and `soundtrack`
 *    live in `audio`, and `karte` lives in `content` (a new map is content, a
 *    minimap is `ui`).
 *
 * Multi-word entries belong in `phrases`; `words` is matched token by token.
 */
const CATEGORY_RULES: readonly CategoryRule[] = [
  {
    category: 'bug',
    words: stems(['bug', 'bugs', 'fehler', 'crash', 'absturz', 'abstuerzt', 'kaputt', 'broken', 'error', 'freeze', 'friere', 'haengt', 'flackert', 'unspielbar', 'glitch', 'desync', 'lag', 'lags', 'performance', 'ruckelt', 'unsichtbar', 'stuck']),
    phrases: foldPhrases(['geht nicht', 'funktioniert nicht', 'stuerzt ab', 'crashes', 'does not work', 'kaputt gegangen']),
  },
  {
    category: 'balance',
    words: stems(['balance', 'nerf', 'buff', 'buffen', 'nerfen', 'buffs', 'overpowered', 'underpowered', 'schwierigkeit', 'difficulty', 'unfair', 'op', 'dropchance', 'drop', 'kosten', 'preis', 'belohnung', 'reward', 'rewarding', 'progression', 'grind', 'lebenspunkte', 'lebenspunkt', 'leben', 'hp', 'health', 'schaden', 'damage', 'geschwindigkeit', 'tempo', 'schneller', 'langsamer', 'staerker', 'schwaecher', 'erhoehen', 'erhoeht', 'reduzieren', 'verringern', 'senken', 'anpassen', 'tune']),
    phrases: foldPhrases(['zu stark', 'zu schwach', 'zu einfach', 'zu schwer', 'too strong', 'too weak', 'too easy', 'too hard']),
  },
  {
    category: 'mechanics',
    words: stems(['mechanik', 'mechaniken', 'mechanic', 'mechanics', 'dash', 'doppelsprung', 'springen', 'jump', 'doublejump', 'angriff', 'attack', 'faehigkeit', 'faehigkeiten', 'ability', 'abilities', 'skill', 'skills', 'combo', 'combos', 'block', 'parry', 'ausweichen', 'dodge', 'schild', 'shield', 'dashroll', 'sprint', 'grappling', 'hook', 'zeitlupe', 'slowmo', 'bullet', 'bullettime', 'kombosystem', 'crafting', 'bauen', 'build', 'summon', 'beschwoeren', 'revive', 'wiederbeleben', 'stealth', 'tarnung']),
    phrases: foldPhrases(['neue mechanik', 'new mechanic', 'zeit anhalten', 'slow motion']),
  },
  {
    category: 'content',
    words: stems(['level', 'levels', 'map', 'maps', 'karte', 'karten', 'gegner', 'gegnertyp', 'enemy', 'enemies', 'boss', 'bosstyp', 'item', 'items', 'waffe', 'waffen', 'weapon', 'weapons', 'skin', 'skins', 'charakter', 'charaktere', 'character', 'characters', 'story', 'quest', 'quests', 'mission', 'missionen', 'modus', 'modes', 'mode', 'biom', 'biome', 'welt', 'world', 'shop', 'shopitem', 'haendler', 'npc', 'npcs', 'pet', 'pets', 'begleiter']),
    phrases: foldPhrases(['neuer gegner', 'neue waffe', 'new enemy', 'new weapon', 'neues level', 'new level', 'neue map', 'neuer boss', 'new boss']),
  },
  {
    category: 'ui',
    words: stems(['ui', 'hud', 'menue', 'menu', 'interface', 'anzeige', 'button', 'buttons', 'inventar', 'inventory', 'tutorial', 'tooltip', 'tooltips', 'minimap', 'skilltree', 'skillbaum', 'shopui', 'einstellungen', 'settings', 'optionen', 'scoreboard', 'leaderboard', 'chat', 'marker']),
    phrases: foldPhrases(['user interface', 'bessere anzeige']),
  },
  {
    category: 'audio',
    words: stems(['audio', 'sound', 'sounds', 'sfx', 'musik', 'music', 'soundtrack', 'ton', 'toene', 'lautstaerke', 'volume', 'echo', 'reverb']),
    phrases: foldPhrases(['neue musik', 'new music', 'sound effekt']),
  },
];

/**
 * Which category a suggestion belongs to — and through `CATEGORY_SCOPES` which
 * agent runs the resulting job, so this is a routing decision and not a label.
 *
 * The tokens are the ones `similarity` clusters on (`tokenize`), which is the
 * whole point: a rule that matches what the clustering sees cannot rot.
 */
export function classify(input: string): SuggestionCategory {
  const folded = foldText(input);
  if (!folded) return 'other';
  const tokens = new Set(tokenize(input));
  let best: SuggestionCategory = 'other';
  let bestScore = 0;
  for (const rule of CATEGORY_RULES) {
    let score = 0;
    for (const w of rule.words) {
      if (tokens.has(w)) score += 2;
    }
    for (const p of rule.phrases) {
      if (folded.includes(p)) score += 3;
    }
    // Strictly greater: a category that scores nothing never takes the lead, and
    // a word belongs to exactly one list, so the order of `CATEGORY_RULES` no
    // longer decides anything (see the note above the table).
    if (score > bestScore) {
      bestScore = score;
      best = rule.category;
    }
  }
  return best;
}

const CATEGORY_WEIGHT: Record<SuggestionCategory, number> = {
  bug: 6,
  mechanics: 5,
  content: 4,
  balance: 3,
  ui: 2.5,
  audio: 2,
  other: 1,
};

export function recencyBonus(createdAt: number, now: number): number {
  const ageHours = Math.max(0, (now - createdAt) / 3_600_000);
  return 12 * Math.pow(0.5, ageHours / 48);
}

export function qualityScore(text: string): { quality: number; penalty: number } {
  let quality = 0;
  let penalty = 0;
  const trimmed = text.trim();
  const len = trimmed.length;
  if (len >= 40 && len <= 600) quality += 4;
  else if (len >= 20) quality += 2;
  const words = tokenize(trimmed);
  if (words.length >= 5) quality += 1;
  if (/\d/.test(trimmed)) quality += 1;
  if (/\n/.test(trimmed)) quality += 1;
  const concrete = ['sollte', 'should', 'koennte', 'could', 'fuege', 'add', 'baue', 'build', 'implementiere', 'implement', 'waere', 'would'];
  const folded = foldText(trimmed);
  if (concrete.some((c) => folded.includes(c))) quality += 2;
  if (len < 15) penalty += 4;
  if (len > 1500) penalty += 2;
  const letters = trimmed.replace(/[^a-zA-ZäöüÄÖÜß]/g, '');
  if (letters.length > 8 && letters === letters.toUpperCase()) penalty += 2;
  if (letters.length === 0) penalty += 6;
  const urlOnly = trimmed.replace(/https?:\/\/\S+/g, '').trim().length < 5;
  if (urlOnly) penalty += 6;
  const repeats = /(.)\1{4,}/.test(trimmed);
  if (repeats) penalty += 2;
  return { quality, penalty };
}

export function scoreSuggestion(
  suggestion: Pick<Suggestion, 'text' | 'votes' | 'createdAt' | 'category'>,
  now: number,
  clusterSize: number,
): { score: number; breakdown: ScoreBreakdown } {
  const votesScore = 3 * Math.min(suggestion.votes, 40);
  const clusterScore = 2 * Math.min(Math.max(clusterSize - 1, 0), 12);
  const recency = recencyBonus(suggestion.createdAt, now);
  const category = CATEGORY_WEIGHT[suggestion.category] ?? 1;
  const { quality, penalty } = qualityScore(suggestion.text);
  const raw = votesScore + clusterScore + recency + category + quality - penalty;
  return {
    score: Math.max(0, Math.round(raw * 10) / 10),
    breakdown: { votes: votesScore, cluster: clusterScore, recency, category, quality, penalty },
  };
}

export interface ClusterInfo {
  canonicalId: number;
  clusterIds: number[];
  similarity: number;
}

/**
 * The statuses whose rows do not count as "somebody else said it too".
 *
 * `rejected` is the only one, and it is excluded on purpose. A rejected row is
 * a request the operator turned down, so counting it as support for the
 * surviving row inflates the very score that decides whether a job starts by
 * itself. `findCanonical` never let a rejected row be canonical, and the
 * auto-approve gate in `app.ts` filtered them out of its candidates — while the
 * dashboard grouped by `(canonicalId ?? id)` with no status filter at all. Two
 * rejected duplicates then made the gate see a cluster of 3 and the screen
 * announce 4: two score points per rejected row, up to 24, and an operator
 * reading a number the decision never used.
 *
 * The rule lives here, once. `app.ts` must call it (`existing.filter(...)`) so
 * the displayed size and the gated size cannot drift apart again.
 */
export const NON_CLUSTERING_STATUSES: ReadonlySet<SuggestionStatus> = new Set<SuggestionStatus>([
  'rejected',
]);

/** Whether a row counts towards its cluster — see `NON_CLUSTERING_STATUSES`. */
export function countsTowardsCluster(row: Pick<Suggestion, 'status'>): boolean {
  return !NON_CLUSTERING_STATUSES.has(row.status);
}

/**
 * Cluster id → member ids, for the rows that count.
 *
 * Built once per call instead of once per row: the API decorates every
 * suggestion on every 8 s poll, and each `decorate` used to walk the whole list
 * again. `decorateAll` is the entry point for that.
 */
export function clusterIndex(list: readonly Suggestion[]): Map<number, number[]> {
  const index = new Map<number, number[]>();
  for (const row of list) {
    if (!countsTowardsCluster(row)) continue;
    const key = row.canonicalId ?? row.id;
    const bucket = index.get(key);
    if (bucket) bucket.push(row.id);
    else index.set(key, [row.id]);
  }
  return index;
}

/**
 * The existing suggestion this text is a repeat of, and the cluster around it.
 *
 * Rejected rows are skipped twice over: they never become the canonical, and
 * they are not counted in `clusterIds` — so `clusterIds.length + 1` (the new
 * row itself) is exactly the number `decorate` puts on the screen.
 */
export function findCanonical(
  text: string,
  existing: Pick<Suggestion, 'id' | 'text' | 'canonicalId' | 'status'>[],
): ClusterInfo | null {
  let best: { id: number; sim: number } | null = null;
  for (const other of existing) {
    if (other.canonicalId !== null) continue;
    if (!countsTowardsCluster(other)) continue;
    const sim = similarity(text, other.text);
    if (sim >= CLUSTER_THRESHOLD && (!best || sim > best.sim)) {
      best = { id: other.id, sim };
    }
  }
  if (!best) return null;
  const clusterIds = existing
    .filter((s) => countsTowardsCluster(s) && (s.id === best.id || s.canonicalId === best.id))
    .map((s) => s.id);
  return { canonicalId: best.id, clusterIds, similarity: best.sim };
}

function decorateFromIndex(
  suggestion: Suggestion,
  index: Map<number, number[]>,
  now: number,
): SuggestionView {
  const canonical = suggestion.canonicalId ?? suggestion.id;
  // A rejected row is in no index, so it is a cluster of one — and a duplicate
  // of a rejected canonical still finds its siblings, because they carry its id
  // as their own `canonicalId` and that key is in the index without it.
  const clusterIds = index.get(canonical) ?? [suggestion.id];
  const { score, breakdown } = scoreSuggestion(suggestion, now, clusterIds.length);
  return { ...suggestion, score, breakdown, clusterIds, clusterSize: clusterIds.length, run: null };
}

/** One row, scored against the clusters of the whole list. */
export function decorate(
  suggestion: Suggestion,
  all: readonly Suggestion[],
  now: number,
): SuggestionView {
  return decorateFromIndex(suggestion, clusterIndex(all), now);
}

/** The whole list in one pass — what the routes should call. */
export function decorateAll(list: readonly Suggestion[], now: number): SuggestionView[] {
  const index = clusterIndex(list);
  return list.map((s) => decorateFromIndex(s, index, now));
}

export type SortMode = 'score' | 'new' | 'top' | 'cluster';

export function sortSuggestions(list: SuggestionView[], mode: SortMode): SuggestionView[] {
  const copy = [...list];
  const byNew = (a: SuggestionView, b: SuggestionView) => b.createdAt - a.createdAt || b.id - a.id;
  switch (mode) {
    case 'new':
      return copy.sort(byNew);
    case 'top':
      return copy.sort((a, b) => b.votes - a.votes || b.score - a.score || byNew(a, b));
    case 'cluster':
      return copy.sort((a, b) => b.clusterSize - a.clusterSize || b.score - a.score || byNew(a, b));
    case 'score':
    default:
      return copy.sort((a, b) => b.score - a.score || byNew(a, b));
  }
}
