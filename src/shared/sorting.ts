import type { ScoreBreakdown, Suggestion, SuggestionCategory, SuggestionView } from './types';

const STOPWORDS = new Set([
  'der', 'die', 'das', 'den', 'dem', 'des', 'ein', 'eine', 'einen', 'einem', 'einer', 'eines',
  'und', 'oder', 'aber', 'mit', 'ohne', 'fuer', 'für', 'von', 'vom', 'zum', 'zur', 'auf', 'aus',
  'bei', 'nach', 'vor', 'ueber', 'über', 'unter', 'durch', 'gegen', 'ist', 'sind', 'war', 'waere',
  'wäre', 'wird', 'werden', 'kann', 'koennen', 'können', 'soll', 'sollen', 'sollte', 'muss',
  'müssen', 'muessten', 'ich', 'du', 'er', 'sie', 'es', 'wir', 'ihr', 'man', 'mehr', 'sehr',
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

export function jaccard(a: string[], b: string[]): number {
  if (a.length === 0 || b.length === 0) return 0;
  const sa = new Set(a);
  const sb = new Set(b);
  let inter = 0;
  for (const t of sa) if (sb.has(t)) inter++;
  const union = sa.size + sb.size - inter;
  return union === 0 ? 0 : inter / union;
}

export function diceTrigram(a: string, b: string): number {
  const ga = trigrams(a);
  const gb = trigrams(b);
  if (ga.size === 0 || gb.size === 0) return 0;
  let inter = 0;
  for (const g of ga) if (gb.has(g)) inter++;
  return (2 * inter) / (ga.size + gb.size);
}

export function overlapCoefficient(a: string[], b: string[]): number {
  if (a.length === 0 || b.length === 0) return 0;
  const sa = new Set(a);
  const sb = new Set(b);
  let inter = 0;
  for (const t of sa) if (sb.has(t)) inter++;
  return inter / Math.min(sa.size, sb.size);
}

export function similarity(a: string, b: string): number {
  const overlap = overlapCoefficient(tokenize(a), tokenize(b));
  const dice = diceTrigram(a, b);
  return 0.55 * overlap + 0.45 * dice;
}

export const CLUSTER_THRESHOLD = 0.35;

interface CategoryRule {
  category: SuggestionCategory;
  words: string[];
  phrases: string[];
}

const CATEGORY_RULES: CategoryRule[] = [
  {
    category: 'bug',
    words: ['bug', 'bugs', 'fehler', 'crash', 'absturz', 'abstuerzt', 'kaputt', 'broken', 'error', 'freeze', 'friere', 'haengt', 'flackert', 'unspielbar', 'glitch', 'desync', 'lag', 'lags', 'performance', 'ruckelt', 'unsichtbar', 'stuck'],
    phrases: ['geht nicht', 'funktioniert nicht', 'stuerzt ab', 'crashes', 'does not work', 'kaputt gegangen'],
  },
  {
    category: 'balance',
    words: ['balance', 'nerf', 'buff', 'buffen', 'nerfen', 'buffs', 'overpowered', 'underpowered', 'schwierigkeit', 'difficulty', 'unfair', 'zu stark', 'zu schwach', 'op', 'dropchance', 'drop', 'kosten', 'preis', 'belohnung', 'reward', 'rewarding', 'progression', 'grind', 'lebenspunkte', 'lebenspunkt', 'leben', 'hp', 'health', 'schaden', 'damage', 'geschwindigkeit', 'tempo', 'schneller', 'langsamer', 'staerker', 'schwaecher', 'erhoehen', 'erhoeht', 'reduzieren', 'verringern', 'senken', 'anpassen', 'tune'],
    phrases: ['zu stark', 'zu schwach', 'zu einfach', 'zu schwer', 'too strong', 'too weak', 'too easy', 'too hard'],
  },
  {
    category: 'mechanics',
    words: ['mechanik', 'mechaniken', 'mechanic', 'mechanics', 'dash', 'doppelsprung', 'springen', 'jump', 'doublejump', 'angriff', 'attack', 'faehigkeit', 'faehigkeiten', 'ability', 'abilities', 'skill', 'skills', 'combo', 'combos', 'block', 'parry', 'ausweichen', 'dodge', 'schild', 'shield', 'dashroll', 'sprint', 'grappling', 'hook', 'zeitlupe', 'slowmo', 'bullet', 'bullettime', 'kombosystem', 'crafting', 'bauen', 'build', 'summon', 'beschwoeren', 'revive', 'wiederbeleben', 'stealth', 'tarnung'],
    phrases: ['neue mechanik', 'new mechanic', 'zeit anhalten', 'slow motion'],
  },
  {
    category: 'content',
    words: ['level', 'levels', 'map', 'maps', 'karte', 'karten', 'gegner', 'gegnertyp', 'enemy', 'enemies', 'boss', 'bosstyp', 'item', 'items', 'waffe', 'waffen', 'weapon', 'weapons', 'skin', 'skins', 'charakter', 'charaktere', 'character', 'characters', 'story', 'quest', 'quests', 'mission', 'missionen', 'modus', 'modes', 'mode', 'biom', 'biome', 'welt', 'world', 'shop', 'shopitem', 'haendler', 'npc', 'npcs', 'pet', 'pets', 'begleiter', 'soundtrack', 'musik', 'music'],
    phrases: ['neuer gegner', 'neue waffe', 'new enemy', 'new weapon', 'neues level', 'new level', 'neue map', 'neue waffe', 'neuer boss', 'new boss'],
  },
  {
    category: 'ui',
    words: ['ui', 'hud', 'menue', 'menu', 'interface', 'anzeige', 'button', 'buttons', 'inventar', 'inventory', 'tutorial', 'tooltip', 'tooltips', 'karte', 'minimap', 'skilltree', 'skillbaum', 'shopui', 'einstellungen', 'settings', 'optionen', 'scoreboard', 'leaderboard', 'chat', 'marker'],
    phrases: ['user interface', 'bessere anzeige'],
  },
  {
    category: 'audio',
    words: ['audio', 'sound', 'sounds', 'sfx', 'musik', 'music', 'soundtrack', 'ton', 'toene', 'lautstaerke', 'volume', 'echo', 'reverb'],
    phrases: ['neue musik', 'new music', 'sound effekt'],
  },
];

export function classify(input: string): SuggestionCategory {
  const folded = foldText(input);
  if (!folded) return 'other';
  const tokens = new Set(folded.split(' '));
  let best: SuggestionCategory = 'other';
  let bestScore = 0;
  for (const rule of CATEGORY_RULES) {
    let score = 0;
    for (const w of rule.words) {
      const fw = foldText(w);
      if (fw.includes(' ')) {
        if (folded.includes(fw)) score += 2;
      } else if (tokens.has(fw)) {
        score += 2;
      }
    }
    for (const p of rule.phrases) {
      if (folded.includes(foldText(p))) score += 3;
    }
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

export function findCanonical(
  text: string,
  existing: Pick<Suggestion, 'id' | 'text' | 'canonicalId'>[],
): ClusterInfo | null {
  let best: { id: number; sim: number } | null = null;
  for (const other of existing) {
    if (other.canonicalId !== null) continue;
    const sim = similarity(text, other.text);
    if (sim >= CLUSTER_THRESHOLD && (!best || sim > best.sim)) {
      best = { id: other.id, sim };
    }
  }
  if (!best) return null;
  const clusterIds = existing
    .filter((s) => s.id === best.id || s.canonicalId === best.id)
    .map((s) => s.id);
  return { canonicalId: best.id, clusterIds, similarity: best.sim };
}

export function decorate(
  suggestion: Suggestion,
  all: Suggestion[],
  now: number,
): SuggestionView {
  const canonical = suggestion.canonicalId ?? suggestion.id;
  const clusterIds = all
    .filter((s) => (s.canonicalId ?? s.id) === canonical)
    .map((s) => s.id);
  const { score, breakdown } = scoreSuggestion(suggestion, now, clusterIds.length);
  return { ...suggestion, score, breakdown, clusterIds, clusterSize: clusterIds.length, run: null };
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
