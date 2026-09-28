import { describe, expect, it } from 'vitest';
import { auditScope, extractTouchedFiles, loadManifest, scopeForSuggestion, scopeManifest } from '../server/scopes';
import type { RunEvent, Suggestion } from '../src/shared/types';

function suggestion(overrides: Partial<Suggestion> = {}): Suggestion {
  return {
    id: 1,
    text: '',
    author: 'Test',
    source: 'dashboard',
    category: 'other',
    status: 'approved',
    votes: 0,
    canonicalId: null,
    createdAt: 0,
    updatedAt: 0,
    discordMessageId: null,
    runId: null,
    parentId: null,
    ...overrides,
  };
}

/** A `bash`/`edit` tool event as the run log would contain it. */
function tool(text: string): RunEvent {
  return { t: Date.now(), kind: 'tool', tool: 'bash', text };
}

describe('Manifest-Brücke', () => {
  it('liest das Manifest aus scripts/scopes.mjs', () => {
    expect(loadManifest().status).toBe('ok');
  });

  /**
   * The manifest's own self-check, run as a test.
   *
   * `node scripts/scopes.mjs list` reports these problems and exits 1, but nothing in
   * `npm test` called it — so unregistered suites sat in the tree through a green run.
   * The failure is quiet by nature: a suite nobody registered simply does not run.
   */
  it('ist konsistent — jede Suite hängt an einem Scope, jede Testdatei am Runner', () => {
    const manifest = scopeManifest();
    expect(manifest.status, 'das Manifest ließ sich nicht lesen').toBe('ok');
    expect(manifest.problems).toEqual([]);
  });

  it('liefert jeden Scope mit seinem zuständigen Agenten', () => {
    const manifest = scopeManifest();
    expect(manifest.status).toBe('ok');
    expect(manifest.scopes.length).toBeGreaterThan(15);
    const byId = new Map(manifest.scopes.map((s) => [s.id, s]));
    expect(byId.get('tetris')?.agent).toBe('game');
    expect(byId.get('meshes')?.agent).toBe('meshes');
    expect(byId.get('dashboard')?.agent).toBe('dashboard');
    // The game scope owns its directory exclusively.
    expect(byId.get('tetris')?.own).toContain('godot/src/game/tetris/**');
    expect(byId.get('meshes')?.own).toContain('godot/assets/meshes/**');
    expect(byId.get('dashboard')?.own).toContain('server/**');
  });

  it('reicht Manifest-Problemchen an den Betreiber durch', () => {
    // The content is the manifest's business, not this module's: it is only passed
    // on so the dashboard can show a red state.
    expect(Array.isArray(scopeManifest().problems)).toBe(true);
  });

  it('meldet geteilte Dateien, die jeder Agent anfasst', () => {
    expect(scopeManifest().sharedFiles).toContain('godot/src/core/logic/game_registry.gd');
  });
});

describe('scopeForSuggestion', () => {
  it('erkennt ein im Text genanntes Spiel', () => {
    const prediction = scopeForSuggestion(suggestion({ text: 'Tetris fühlt sich zu langsam an' }));
    expect(prediction.scopes[0]).toBe('tetris');
    expect(prediction.confidence).toBe('explicit');
    expect(prediction.reason).toContain('tetris');
  });

  it('erkennt ein Spiel auch über den Verzeichnisnamen ohne Bindestrich', () => {
    expect(scopeForSuggestion(suggestion({ text: 'Mach candy3d schneller' })).scopes[0]).toBe('candy3d');
  });

  it('ordnet einen Content-Vorschlag dem Content-Scope zu', () => {
    const prediction = scopeForSuggestion(
      suggestion({ text: 'Neuer Gegner: ein Eiswürfel, der sich teilt', category: 'content' }),
    );
    expect(prediction.scopes).toContain('content');
    expect(prediction.confidence).toBe('category');
  });

  it('nennt bei einem Content-Vorschlag mit Spielnennung beide Scopes', () => {
    const prediction = scopeForSuggestion(
      suggestion({ text: 'Tetris braucht einen neuen Gegner im Content', category: 'content' }),
    );
    expect(prediction.scopes[0]).toBe('tetris');
    expect(prediction.scopes).toContain('content');
  });

  it('ordnet eine UI-Kategorie der Kernlogik zu', () => {
    const prediction = scopeForSuggestion(suggestion({ text: 'Der Menü-Knopf ist zu klein', category: 'ui' }));
    expect(prediction.scopes).toEqual(['core']);
    expect(prediction.confidence).toBe('category');
    expect(prediction.reason).toContain('ui');
  });

  it('fällt auf die Kernlogik zurück und sagt das offen', () => {
    const prediction = scopeForSuggestion(suggestion({ text: 'Weiß nicht, passt schon irgendwie', category: 'other' }));
    expect(prediction.scopes).toEqual(['core']);
    expect(prediction.confidence).toBe('fallback');
    expect(prediction.reason).toContain('Annahme');
  });

  it('verwechselt kein Spiel mit einem Wort, das nur ähnlich beginnt', () => {
    const prediction = scopeForSuggestion(suggestion({ text: 'Pangsterion mit 20480er Levels' }));
    expect(prediction.scopes).not.toContain('2048');
    expect(prediction.scopes).not.toContain('pang');
  });

  it('berücksichtigt die Geschwister-Vorschläge desselben Clusters', () => {
    const prediction = scopeForSuggestion(
      suggestion({ text: 'Mehr Speed', category: 'balance' }),
      [suggestion({ id: 2, text: 'Das gilt vor allem im Siedler-Spiel' })],
    );
    expect(prediction.scopes[0]).toBe('siedler');
  });
});

describe('extractTouchedFiles', () => {
  it('liest Pfade aus Tool-Titeln und Kommandozeilen', () => {
    const files = extractTouchedFiles([
      tool('edit · completed — godot/src/game/tetris/tetris_screen.gd'),
      tool('bash · completed — node scripts/scopes.mjs check tetris --staged'),
      tool('read · completed — package.json'),
    ]);
    expect(files).toContain('godot/src/game/tetris/tetris_screen.gd');
    expect(files).toContain('scripts/scopes.mjs');
    expect(files).toContain('package.json');
  });

  it('ignoriert absolute Pfade außerhalb des Repos und Fließtext', () => {
    const files = extractTouchedFiles([
      tool('bash · completed — cat /usr/share/doc/README.md und /home/x/node_modules/a.js'),
      { t: 1, kind: 'text', text: 'Ich passe die Logik in der Datei an, das dauert etwas.' },
    ]);
    expect(files).toEqual([]);
  });
});

describe('auditScope', () => {
  it('meldet eine Registry-Datei eines anderen Scopes als Verstoß', () => {
    const audit = auditScope({
      runId: 'run_1',
      scopes: ['tetris'],
      events: [
        tool('edit · completed — godot/src/core/logic/asset_registry.gd'),
        tool('edit · completed — godot/src/game/tetris/tetris_screen.gd'),
      ],
    });
    expect(audit.ok).toBe(false);
    expect(audit.violations[0]).toContain('asset_registry.gd');
    expect(audit.violations[0]).toContain('meshes');
    expect(audit.violations.some((v) => v.includes('tetris_screen.gd'))).toBe(false);
    expect(audit.agent).toBe('game');
  });

  it('meldet geteilte Dateien als geteilt, nicht als Verstoß', () => {
    const audit = auditScope({
      runId: 'run_1',
      scopes: ['tetris'],
      events: [tool('edit · completed — godot/src/core/logic/game_registry.gd')],
    });
    expect(audit.ok).toBe(true);
    expect(audit.shared).toEqual(['godot/src/core/logic/game_registry.gd']);
    expect(audit.violations).toEqual([]);
  });

  it('meldet Dateien, die kein Scope beansprucht', () => {
    const audit = auditScope({
      runId: 'run_1',
      scopes: ['tetris'],
      events: [tool('write · completed — notes/gedanken.md')],
    });
    expect(audit.unclaimed).toEqual(['notes/gedanken.md']);
    expect(audit.ok).toBe(true);
  });

  it('warnt vor `git add -A`', () => {
    const audit = auditScope({
      runId: 'run_1',
      scopes: ['tetris'],
      events: [tool('bash · completed — git add -A && git commit -m "feat(suggestion-1): x"')],
    });
    expect(audit.notes.join(' ')).toContain('git add');
  });

  it('akzeptiert eine Datei, die der Basis-Scope und die Variante teilen', () => {
    const audit = auditScope({
      runId: 'run_1',
      scopes: ['crystal3d-christmas', 'crystal3d'],
      events: [tool('edit · completed — godot/src/game/crystal3d/crystal_screen.gd')],
    });
    expect(audit.violations).toEqual([]);
    expect(audit.shared).toEqual([]);
  });

  it('zählt ohne Manifest keine Verletzung, sondern sagt es', () => {
    const audit = auditScope({
      runId: 'run_1',
      scopes: ['tetris'],
      events: [tool('edit · completed — godot/src/game/tetris/tetris_screen.gd')],
    });
    expect(audit.checked).toBe(1);
  });
});
