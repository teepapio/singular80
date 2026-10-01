import { describe, expect, it } from 'vitest';
import {
  CLUSTER_THRESHOLD,
  classify,
  decorate,
  decorateAll,
  diceTrigram,
  findCanonical,
  overlapCoefficient,
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
    // `jaccard` was removed: it was exported and tested but `similarity` never
    // called it, and blending it in would push the duplicate-detection case
    // below the clustering threshold. Dice still carries this test.
    expect(overlapCoefficient(a, b)).toBeGreaterThan(0.3);
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
    const view = decorate(all[0], all);
    expect(view.clusterSize).toBe(2);
    expect(view.clusterIds.sort()).toEqual([1, 2]);
  });
});

describe('Reihenfolge ohne Score', () => {
  /**
   * There is no priority score any more. What is left has to rest on something
   * the owner can see and argue with: the players' votes, then the cluster size,
   * then the newest.
   */
  const all = [
    makeSuggestion(1, 'Füge einen Slime Gegner hinzu', { votes: 1 }),
    makeSuggestion(2, 'Neue Waffe: Railgun', { votes: 9 }),
    makeSuggestion(3, 'Bitte die Musik leiser machen', { votes: 3 }),
  ];
  const views = decorateAll(all);

  it('sortiert nach Stimmen, dann nach neu', () => {
    expect(sortSuggestions(views, 'top').map((v) => v.id)).toEqual([2, 3, 1]);
  });

  it('eine unbekannte Sortierung fällt auf Stimmen zurück, nicht auf eine Zahl', () => {
    // `sort=score` kann noch in einem alten Bookmark oder Tab stehen. Es gibt
    // keinen Score mehr, und ein toter Parameter darf nicht die Liste leeren.
    const sorted = sortSuggestions(views, 'score' as never);
    expect(sorted.map((v) => v.id)).toEqual([2, 3, 1]);
  });

  it('"new" ist die neueste zuerst', () => {
    const now = Date.now();
    const fresh = decorateAll([
      makeSuggestion(1, 'Älterer Vorschlag', { createdAt: now - 60_000 }),
      makeSuggestion(2, 'Neuerer Vorschlag', { createdAt: now }),
    ]);
    expect(sortSuggestions(fresh, 'new').map((v) => v.id)).toEqual([2, 1]);
  });

  it('"cluster" nimmt die größte Gruppe zuerst', () => {
    const clustered = decorateAll([
      makeSuggestion(1, 'Füge einen Slime Gegner hinzu'),
      makeSuggestion(2, 'Neuer Slime Gegner', { canonicalId: 1 }),
      makeSuggestion(3, 'Ganz andere Idee'),
    ]);
    expect(sortSuggestions(clustered, 'cluster')[0].clusterSize).toBe(2);
  });
});
