import { describe, expect, it } from 'vitest';
import {
  attemptLabel,
  BROAD_SCOPE_IDS,
  describeLaneRisks,
  describePolicy,
  describeQueue,
  formatCountdown,
  groupScopes,
  laneLabel,
  laneRisks,
  manifestHeadline,
  outcomeBadge,
  scopeLabel,
  scopeWarning,
} from '../src/dashboard/queueControls';
import type { QueueState, RunRecord, RunnerPolicy, ScopeAudit, ScopeManifest } from '../src/shared/types';

function run(overrides: Partial<RunRecord> = {}): RunRecord {
  return {
    id: 'run_1',
    suggestionId: 7,
    status: 'failed',
    sessionId: null,
    resumesSession: null,
    lane: null,
    worktreePath: null,
    worktreeBranch: null,
    prompt: '',
    exitCode: 1,
    cost: null,
    tokensInput: null,
    tokensOutput: null,
    commitHash: null,
    resultSummary: '',
    createdAt: 0,
    startedAt: 0,
    finishedAt: 0,
    logPath: '/tmp/x.jsonl',
    attempt: 1,
    maxAttempts: 1,
    retryOf: null,
    notBefore: null,
    timeoutMs: 0,
    scopes: [],
    scope: null,
    note: 'exit 1',
    scopeIssues: null,
    ...overrides,
  };
}

const policy: RunnerPolicy = {
  timeoutMinutes: 45,
  retryLimit: 1,
  retryBackoffSeconds: 30,
  maxParallelRuns: 3,
};

function queue(overrides: Partial<QueueState> = {}): QueueState {
  return { paused: false, policy, activeRuns: [], activeRun: null, queue: [], blockedRunIds: [], ...overrides };
}

describe('formatCountdown', () => {
  it('bleibt unter einer Minute in Sekunden', () => {
    expect(formatCountdown(25_000)).toBe('25 s');
  });

  it('wechselt zu Minuten', () => {
    expect(formatCountdown(125_000)).toBe('2 min 5 s');
    expect(formatCountdown(120_000)).toBe('2 min');
  });

  it('behandelt Stunden', () => {
    expect(formatCountdown(3_720_000)).toBe('1 h 2 min');
  });
});

describe('laneLabel', () => {
  it('nennt eine einzelne Spur ausdrücklich, statt "0 von 1" zu schreiben', () => {
    // "0 von 1 Spuren belegt" reads like a defect; the wording is the reason this
    // function exists at all.
    expect(laneLabel(1, 0)).toBe('1 Spur (nur nacheinander)');
    expect(laneLabel(1, 1)).toBe('1 Spur, belegt');
  });

  it('zählt bei mehreren Spuren, und eine unmögliche Anzahl wird eine', () => {
    expect(laneLabel(3, 0)).toBe('0 von 3 Spuren belegt');
    expect(laneLabel(3, 2)).toBe('2 von 3 Spuren belegt');
    // 0 lanes would divide by nothing and say "0 von 0"; the queue never runs
    // zero sessions, so the label must not either.
    expect(laneLabel(0, 0)).toBe('1 Spur (nur nacheinander)');
  });
});

describe('laneRisks', () => {
  const busy = (id: string, lane: number, scopes: string[]): RunRecord =>
    run({ id, lane, status: 'running', scopes, scope: scopes[0] ?? null });

  it('meldet zwei Spuren, die auf denselben breiten Scope zeigen', () => {
    // Zwei verschiedene Spiele bekommen beide `core` als Ergänzung — das ist die
    // schwächere der beiden Kollisionen und wird als `broad` markiert.
    expect(laneRisks([busy('a', 1, ['tetris', 'core']), busy('b', 2, ['pang', 'content'])])).toEqual([]);
    expect(laneRisks([busy('a', 1, ['tetris', 'core']), busy('b', 2, ['pang', 'core'])])).toEqual([
      { scope: 'core', lanes: [1, 2], broad: true },
    ]);
  });

  it('meldet auch zwei Spuren im selben Spiel — das ist der echte Fall', () => {
    // Seit die Spuren nicht mehr pro Scope reserviert sind, können zwei Tetris-Runs
    // gleichzeitig laufen. Genau das muss das Panel sagen, sonst sieht es aus, als
    // wäre nichts geschehen.
    const risks = laneRisks([busy('a', 1, ['tetris']), busy('b', 2, ['tetris'])]);
    expect(risks).toEqual([{ scope: 'tetris', lanes: [1, 2], broad: false }]);
    expect(describeLaneRisks(risks)).toContain('dieselben Dateien');
  });

  it('nennt die Spuren aufsteigend, unabhängig von der Reihenfolge', () => {
    const risks = laneRisks([busy('a', 3, ['content']), busy('b', 1, ['content'])]);
    expect(risks[0].lanes).toEqual([1, 3]);
  });

  it('schweigt bei verschiedenen Spielen ohne gemeinsamen breiten Scope', () => {
    expect(laneRisks([busy('a', 1, ['tetris']), busy('b', 2, ['pang'])])).toEqual([]);
  });

  it('zählt einen Run ohne Spur nicht als Paar', () => {
    // A queued run has no lane; pairing it with a running one would warn about a
    // collision that cannot happen yet.
    expect(laneRisks([busy('a', 1, ['core']), run({ id: 'b', lane: null, scopes: ['core'] })])).toEqual([]);
  });

  it('kennt nur die beiden breiten Scopes als Supplement', () => {
    expect([...BROAD_SCOPE_IDS].sort()).toEqual(['content', 'core']);
  });
});

describe('describeLaneRisks', () => {
  it('schweigt, wenn es nichts zu sagen gibt', () => {
    expect(describeLaneRisks([])).toBeNull();
  });

  it('nennt Scope und beide Spuren — die Beschriftung, die AGENTS.md verlangt', () => {
    // AGENTS.md: "der Scope-Audit meldet es pro Run, und das Panel beschriftet ein
    // solches Paar". Without this line the pair is silent.
    const text = describeLaneRisks([{ scope: 'core', lanes: [1, 2], broad: true }]);
    expect(text).toContain('core');
    expect(text).toContain('Spur 1 + 2');
    expect(text).toContain('Scope-Audit');
  });

  it('zählt mehrere Paare, statt nur das erste zu zeigen', () => {
    const text = describeLaneRisks([
      { scope: 'core', lanes: [1, 2], broad: true },
      { scope: 'content', lanes: [2, 3], broad: true },
    ]);
    expect(text).toContain('core (Spur 1 + 2)');
    expect(text).toContain('content (Spur 2 + 3)');
  });
});

describe('describePolicy', () => {
  it('nennt Zeitlimit, Wiederholungen und Wartezeit', () => {
    expect(describePolicy(policy)).toBe('Zeitlimit 45 min · 1× Wiederholung · 30 s Wartezeit · 0 von 3 Spuren belegt');
  });

  it('sagt es, wenn etwas aus ist', () => {
    expect(
      describePolicy({ timeoutMinutes: 0, retryLimit: 0, retryBackoffSeconds: 30, maxParallelRuns: 3 }),
    ).toBe('kein Zeitlimit · keine Wiederholung · 0 von 3 Spuren belegt');
  });

  it('nennt bei einer Spur ausdrücklich, dass es nacheinander ist', () => {
    expect(describePolicy({ timeoutMinutes: 0, retryLimit: 0, retryBackoffSeconds: 0, maxParallelRuns: 1 })).toContain(
      '1 Spur (nur nacheinander)',
    );
  });
});

describe('describeQueue', () => {
  it('meldet Pause und Warteschlange', () => {
    const summary = describeQueue(queue({ paused: true, queue: [run(), run()] }), 0);
    expect(summary.paused).toBe(true);
    expect(summary.label).toContain('pausiert');
    expect(summary.waiting).toBe(2);
  });

  it('nennt den Startzeitpunkt eines Backoff', () => {
    const summary = describeQueue(queue({ queue: [run({ notBefore: 130_000 })] }), 100_000);
    expect(summary.startsIn).toBe('nächster Start in 30 s');
  });

  it('schweigt über den Backoff, wenn keiner wartet', () => {
    expect(describeQueue(queue({ queue: [run({ notBefore: 10 })] }), 100).startsIn).toBeNull();
  });

  it('zählt die belegten Spuren', () => {
    const summary = describeQueue(
      queue({ activeRuns: [run({ id: 'a', status: 'running' }), run({ id: 'b', status: 'running' })] }),
      0,
    );
    expect(summary.busyLanes).toBe(2);
    expect(summary.totalLanes).toBe(3);
    expect(summary.lanes).toBe('2 von 3 Spuren belegt');
  });

  it('meldet Runs, die auf eine belegte Spur warten', () => {
    const summary = describeQueue(
      queue({
        activeRuns: [run({ id: 'a', status: 'running' })],
        queue: [run({ id: 'b' })],
        blockedRunIds: ['b'],
      }),
      0,
    );
    expect(summary.blocked).toBe(1);
  });
});

describe('attemptLabel', () => {
  it('zeigt den Versuch nur ab dem zweiten', () => {
    expect(attemptLabel(run())).toBeNull();
    expect(attemptLabel(run({ attempt: 2, maxAttempts: 3 }))).toBe('Versuch 2/3');
  });
});

describe('outcomeBadge', () => {
  it('macht eine Zeitüberschreitung zum Fehler, auch wenn der Agent noch etwas sagte', () => {
    const badge = outcomeBadge(
      run({ status: 'failed', note: 'Zeitüberschreitung nach 45 min — Prozess beendet', timeoutMs: 2_700_000 }),
    );
    expect(badge?.icon).toBe('⏱');
    expect(badge?.label).toBe('Zeitüberschreitung');
    expect(badge?.kind).toBe('error');
    expect(badge?.title).toContain('45 min');
  });

  it('zeigt Erfolg und Abbruch', () => {
    expect(outcomeBadge(run({ status: 'succeeded', note: 'ok' }))?.kind).toBe('ok');
    expect(outcomeBadge(run({ status: 'cancelled' }))?.icon).toBe('⏹');
  });

  it('schweigt über einen laufenden Run', () => {
    expect(outcomeBadge(run({ status: 'running', note: null }))).toBeNull();
    expect(outcomeBadge(run({ status: 'queued', note: null }))).toBeNull();
  });
});

describe('scopeWarning', () => {
  const audit = (overrides: Partial<ScopeAudit>): ScopeAudit => ({
    runId: 'run_1',
    scopes: ['tetris'],
    agent: 'agent-game',
    ok: true,
    violations: [],
    shared: [],
    unclaimed: [],
    notes: [],
    checked: 0,
    ...overrides,
  });

  it('nennt zuerst einen Verstoß', () => {
    const text = scopeWarning(
      audit({ ok: false, violations: ['godot/src/core/logic/asset_registry.gd → gehört „meshes“', 'zweite.md'] }),
    );
    expect(text).toContain('Außerhalb des Scopes');
    expect(text).toContain('asset_registry.gd');
    expect(text).toContain('(+1)');
  });

  it('meldet geteilte Dateien und Hinweise', () => {
    expect(scopeWarning(audit({ shared: ['godot/src/core/logic/game_registry.gd'] }))).toContain('Geteilte Datei');
    expect(scopeWarning(audit({ notes: ['`git add` ohne Dateiliste'] }))).toContain('git add');
    expect(scopeWarning(audit({ unclaimed: ['notizen.md'] }))).toContain('außerhalb jedes Scopes');
  });

  it('schweigt bei einem sauberen Run', () => {
    expect(scopeWarning(audit({ checked: 4 }))).toBeNull();
    expect(scopeWarning(null)).toBeNull();
  });
});

describe('groupScopes', () => {
  it('gruppiert nach Agent und sortiert die Gruppen', () => {
    const scope = (id: string, agent: string) => ({
      id,
      agent,
      label: id,
      own: [],
      shared: [],
      suites: [],
      screens: [],
      aliasOf: null,
    });
    const groups = groupScopes([scope('tetris', 'game'), scope('dashboard', 'dashboard'), scope('pang', 'game')]);
    expect(groups.map((g) => g.agent)).toEqual(['dashboard', 'game']);
    expect(groups[1].scopes.map((s) => s.id)).toEqual(['tetris', 'pang']);
  });
});

describe('scopeLabel', () => {
  const manifest = {
    status: 'ok',
    error: null,
    sharedFiles: [],
    problems: [],
    scopes: [{ id: 'tetris', agent: 'agent-game', label: 'Spiel tetris', own: [], shared: [], suites: [], screens: [], aliasOf: null }],
  } as ScopeManifest;

  it('nutzt das Label aus dem Manifest', () => {
    expect(scopeLabel(run({ scopes: ['tetris'], scope: 'tetris' }), manifest)).toBe('Spiel tetris');
  });

  it('fällt auf die ID zurück und sagt es ohne Scope', () => {
    expect(scopeLabel(run({ scopes: ['tetris'] }), null)).toBe('tetris');
    expect(scopeLabel(run(), manifest)).toBe('kein Scope bekannt');
  });
});

describe('manifestHeadline', () => {
  it('meldet ein konsistentes Manifest', () => {
    const manifest = {
      status: 'ok',
      error: null,
      sharedFiles: [],
      problems: [],
      scopes: Array.from({ length: 4 }, (_, i) => ({ id: `s${i}`, agent: i === 0 ? 'agent-game' : 'build' })),
    } as unknown as ScopeManifest;
    expect(manifestHeadline(manifest)).toBe('4 Scopes, davon 1 Spiel-Scopes · Manifest ist konsistent.');
  });

  it('meldet Probleme und einen fehlenden Zugriff', () => {
    const broken = { status: 'ok', error: null, sharedFiles: [], problems: ['Suite X gehört zu keinem Scope'] } as unknown as ScopeManifest;
    expect(manifestHeadline(broken)).toContain('1 Manifest-Problem(e)');
    const missing = { status: 'unavailable', error: 'ENOENT', sharedFiles: [], problems: [], scopes: [] } as ScopeManifest;
    expect(manifestHeadline(missing)).toContain('nicht lesbar');
  });
});
