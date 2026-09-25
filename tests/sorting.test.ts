import { describe, expect, it } from 'vitest';
import {
  CLUSTER_THRESHOLD,
  classify,
  decorate,
  diceTrigram,
  findCanonical,
  jaccard,
  qualityScore,
  scoreSuggestion,
  similarity,
  sortSuggestions,
  tokenize,
} from '../src/shared/sorting';
import type { Suggestion } from '../src/shared/types';

function makeSuggestion(id: number, text: string, overrides: Partial<Suggestion> = {}): Suggestion {
  return {
    id,
    text,
    author: 'Tester',
    source: 'game',
    category: classify(text),
    status: 'new',
    votes: 0,
    canonicalId: null,
    createdAt: Date.now(),
    updatedAt: Date.now(),
    discordMessageId: null,
    runId: null,
    ...overrides,
  };
}

describe('classify', () => {
  it('erkennt Content-Vorschläge', () => {
    expect(classify('Füge einen neuen Gegner hinzu, der Slimes spawnt')).toBe('content');
    expect(classify('Bitte eine neue Waffe einbauen')).toBe('content');
  });

  it('erkennt Mechanik-Vorschläge', () => {
    expect(classify('Eine Dash-Mechanik mit Doppelsprung wäre cool')).toBe('mechanics');
  });

  it('erkennt Bugs', () => {
    expect(classify('Das Spiel stürzt ab wenn ich das Menü öffne')).toBe('bug');
    expect(classify('Der Gegner bleibt unsichtbar hängen')).toBe('bug');
  });

  it('erkennt Balance-Themen', () => {
    expect(classify('Der Boss ist zu stark, bitte nerfen')).toBe('balance');
    expect(classify('Erhöhe die Basis-Lebenspunkte des Spielers von 100 auf 120.')).toBe('balance');
  });

  it('erkennt UI-Themen', () => {
    expect(classify('Die HUD-Anzeige ist unübersichtlich')).toBe('ui');
  });

  it('fällt auf other zurück', () => {
    expect(classify('Hmm')).toBe('other');
    expect(classify('')).toBe('other');
  });
});

describe('Ähnlichkeit & Cluster', () => {
  it('berechnet Jaccard und Trigram-Dice', () => {
    const a = tokenize('Füge einen Slime Gegner hinzu');
    const b = tokenize('Neuer Gegner: Slime');
    expect(jaccard(a, b)).toBeGreaterThan(0.3);
    expect(diceTrigram('Füge einen Slime Gegner hinzu', 'Neuer Gegner: Slime')).toBeGreaterThan(0.4);
  });

  it('erkennt ähnliche Vorschläge als Cluster', () => {
    const existing = [
      makeSuggestion(1, 'Füge einen Slime Gegner hinzu, der in kleine Slimes zerfällt'),
      makeSuggestion(2, 'Neue Waffe: Railgun mit Durchschlag'),
    ];
    const sim = similarity('Neuer Gegner: Slime der sich teilt', existing[0].text);
    expect(sim).toBeGreaterThanOrEqual(CLUSTER_THRESHOLD);
    const canon = findCanonical('Neuer Gegner: Slime der sich teilt', existing);
    expect(canon?.canonicalId).toBe(1);
    expect(canon?.clusterIds).toEqual([1]);
  });

  it('clustert nicht bei unrelated Texten', () => {
    const existing = [makeSuggestion(1, 'Füge einen Slime Gegner hinzu')];
    const canon = findCanonical('Bitte die Lautstärke der Musik senken', existing);
    expect(canon).toBeNull();
  });

  it('decorate zählt Cluster-Größe inklusive Duplikate', () => {
    const all = [
      makeSuggestion(1, 'Füge einen Slime Gegner hinzu'),
      makeSuggestion(2, 'Neuer Slime Gegner', { canonicalId: 1 }),
      makeSuggestion(3, 'Andere Idee', { canonicalId: null }),
    ];
    const view = decorate(all[0], all, Date.now());
    expect(view.clusterSize).toBe(2);
    expect(view.clusterIds.sort()).toEqual([1, 2]);
    expect(view.breakdown.cluster).toBe(2);
  });
});

describe('Scoring ohne Tokens', () => {
  it('belohnt Stimmen', () => {
    const now = Date.now();
    const base = scoreSuggestion(makeSuggestion(1, 'Füge einen neuen Gegner hinzu, der Blitze wirft'), now, 1);
    const voted = scoreSuggestion(
      makeSuggestion(1, 'Füge einen neuen Gegner hinzu, der Blitze wirft', { votes: 5 }),
      now,
      1,
    );
    expect(voted.score).toBeGreaterThan(base.score);
  });

  it('belohnt frische Vorschläge', () => {
    const now = Date.now();
    const fresh = scoreSuggestion(makeSuggestion(1, 'Ein neues Level mit Lava'), now, 1);
    const old = scoreSuggestion(
      makeSuggestion(2, 'Ein neues Level mit Lava', { createdAt: now - 1000 * 60 * 60 * 24 * 14 }),
      now,
      1,
    );
    expect(fresh.breakdown.recency).toBeGreaterThan(old.breakdown.recency);
    expect(fresh.score).toBeGreaterThan(old.score);
  });

  it('bestraft Spam', () => {
    const spam = qualityScore('!!!!!');
    const good = qualityScore('Füge bitte einen neuen Gegner mit einer besonderen Fähigkeit hinzu');
    expect(spam.penalty).toBeGreaterThan(0);
    expect(good.quality).toBeGreaterThan(spam.quality);
  });

  it('sortiert deterministisch nach Score', () => {
    const now = Date.now();
    const all = [
      makeSuggestion(1, 'Füge einen Slime Gegner hinzu', { votes: 1 }),
      makeSuggestion(2, 'Neue Waffe: Railgun', { votes: 9 }),
      makeSuggestion(3, 'Bitte die Musik leiser machen', { votes: 3 }),
    ];
    const views = all.map((s) => decorate(s, all, now));
    const sorted = sortSuggestions(views, 'score');
    expect(sorted[0].id).toBe(2);
    expect(sortSuggestions(views, 'top')[0].votes).toBe(9);
    expect(sortSuggestions(views, 'new')[0].id).toBe(3);
  });
});
