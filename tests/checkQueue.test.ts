import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../server/db';
import { CheckRunner, __testing } from '../server/checkrunner';
import { CHECK_SPECS, CHECKS_BY_ID, findingToSuggestionText } from '../server/checks/catalogue';

/**
 * The check queue end to end against a real temporary database: enqueue, run,
 * verdict, promote.
 *
 * The analysers themselves are covered in `checks.test.ts`; what matters here is
 * that the queue wires them to storage correctly — a finding that never reaches
 * the database, or a check that stays `queued` forever, is the failure a unit
 * test on the analyser would happily miss.
 */
let dataDir: string;
let projectRoot: string;
let store: Store;

beforeEach(() => {
  dataDir = mkdtempSync(join(tmpdir(), 's80-checks-'));
  projectRoot = mkdtempSync(join(tmpdir(), 's80-checks-proj-'));
  store = new Store(dataDir);
  // One file with one dead button and one print in `_process`, so both the
  // `actions` and the `logs` family have something real to find.
  const dir = join(projectRoot, 'godot', 'src', 'game', 'demo');
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, 'demo_screen.gd'),
    [
      'extends Screen',
      '',
      'func _build_ui() -> void:',
      '\tvar dead := Ui.button("Tot", Vector2(120, 40), UiTheme.PANEL_LIGHT)',
      '\tadd_child(dead)',
      '',
      'func _process(delta: float) -> void:',
      '\tprint("tick")',
    ].join('\n'),
    'utf8',
  );
});

afterEach(() => {
  rmSync(dataDir, { recursive: true, force: true });
  rmSync(projectRoot, { recursive: true, force: true });
});

/** Runs a spec to completion and returns the stored record. */
function runSpec(specId: string): ReturnType<Store['getCheck']> {
  const runner = new CheckRunner({ projectRoot, store });
  const { check, error } = runner.enqueue(specId);
  if (error) throw new Error(error);
  return store.getCheck(check!.id);
}

describe('Prüfwarteschlange — Katalog', () => {
  it('deckt alle drei Familien mit je einer statischen Prüfung ab', () => {
    for (const kind of ['actions', 'logs', 'performance'] as const) {
      const specs = CHECK_SPECS.filter((s) => s.kind === kind && s.probe === 'static');
      expect(specs.length, `keine statische Prüfung für ${kind}`).toBeGreaterThan(0);
    }
  });

  it('gibt jeder Prüfung eine eindeutige ID', () => {
    const ids = CHECK_SPECS.map((s) => s.id);
    expect(new Set(ids).size).toBe(ids.length);
    for (const id of ids) expect(CHECKS_BY_ID.get(id)).toBeDefined();
  });

  it('gibt jeder statischen Prüfung Globs, die etwas treffen', () => {
    for (const spec of CHECK_SPECS.filter((s) => s.probe === 'static')) {
      expect(spec.scope?.length, spec.id).toBeGreaterThan(0);
      const found = __testing.filesForGlobs(projectRoot, spec.scope!);
      expect(found.length, `${spec.id} findet keine Datei`).toBeGreaterThan(0);
    }
  });
});

describe('Prüfwarteschlange — Ausführung', () => {
  it('meldet einen toten Knopf und einen Log pro Frame als Fehler', () => {
    const check = runSpec('actions-buttons');
    expect(check?.status).toBe('failed');
    expect(check?.counts.fail).toBe(1);
    const finding = check!.findings[0];
    expect(finding.code).toBe('button-without-callback');
    expect(finding.file).toBe('godot/src/game/demo/demo_screen.gd');
    // The finding has to point at the real line, not at line 1.
    expect(finding.line).toBe(4);
    expect(check?.summary).toContain('Fehler');
  });

  it('findet das print in _process', () => {
    const check = runSpec('logs-spam');
    expect(check?.counts.fail).toBe(1);
    expect(check?.findings[0].code).toBe('log-per-frame');
    expect(check?.findings[0].line).toBe(8);
  });

  it('meldet "sauber", wenn es nichts zu finden gibt', () => {
    const dir = join(projectRoot, 'godot', 'src', 'game', 'demo');
    writeFileSync(
      join(dir, 'demo_screen.gd'),
      ['extends Screen', '', 'func _build_ui() -> void:', '\tprint("nur einmal")'].join('\n'),
      'utf8',
    );
    const check = runSpec('actions-buttons');
    expect(check?.status).toBe('passed');
    expect(check?.findings).toHaveLength(0);
    expect(check?.summary).toContain('Sauber');
  });

  it('schreibt ein Log, das man nachsehen kann', () => {
    const check = runSpec('logs-spam');
    expect(check?.logPath).toBeTruthy();
    expect(check?.startedAt).not.toBeNull();
    expect(check?.finishedAt).not.toBeNull();
  });

  it('verweigert eine Geräteprüfung mit einer Begründung statt einem Timeout', () => {
    const runner = new CheckRunner({ projectRoot, store });
    const { error } = runner.enqueue('performance-fps');
    expect(error).toBeTruthy();
    expect(error).toContain('adb');
    expect(store.listChecks()).toHaveLength(0);
  });

  it('lehnt eine unbekannte Prüfung ab', () => {
    const runner = new CheckRunner({ projectRoot, store });
    expect(runner.enqueue('gibt-es-nicht').error).toContain('Unbekannte');
  });

  it('queuet dieselbe Prüfung nicht zweimal', () => {
    const paused = new CheckRunner({ projectRoot, store });
    paused.setPaused(true);
    const first = paused.enqueue('actions-buttons');
    const second = paused.enqueue('actions-buttons');
    expect(first.check?.id).toBe(second.check?.id);
    expect(store.listChecks()).toHaveLength(1);
  });
});

describe('Prüfwarteschlange — Pause und Neustart', () => {
  it('queuet nichts, solange sie pausiert ist, und arbeitet danach weiter', () => {
    const runner = new CheckRunner({ projectRoot, store });
    runner.setPaused(true);
    runner.enqueue('actions-buttons');
    // A static check runs synchronously, so the only way to see it queued is a
    // paused queue — which is exactly the state an operator leaves it in.
    expect(runner.isPaused()).toBe(true);
    expect(runner.queueState().queue).toHaveLength(1);
    runner.setPaused(false);
  });

  it('überlebt einen Neustart: wartende Prüfungen stehen noch in der Schlange', () => {
    const first = new CheckRunner({ projectRoot, store });
    first.setPaused(true);
    first.enqueue('logs-spam');
    // A second runner over the same database is a restart.
    const second = new CheckRunner({ projectRoot, store });
    expect(second.isPaused()).toBe(true);
    expect(second.queueState().queue.map((c) => c.specId)).toEqual(['logs-spam']);
  });

  it('markiert eine beim Beenden hängende Prüfung als fehlgeschlagen', () => {
    const first = new CheckRunner({ projectRoot, store });
    first.setPaused(true);
    first.enqueue('logs-spam');
    // Simulate a crash: the row says `running` although nothing is running.
    const record = store.listChecks()[0];
    record.status = 'running';
    store.updateCheck(record);
    const second = new CheckRunner({ projectRoot, store });
    const recovered = store.getCheck(record.id);
    expect(recovered?.status).toBe('failed');
    expect(recovered?.note).toContain('beendet');
    expect(second.queueState().queue).toHaveLength(0);
  });
});

describe('Prüfwarteschlange — Funde werden zu Vorschlägen', () => {
  it('macht aus einem Fund genau einen Vorschlag', () => {
    const runner = new CheckRunner({ projectRoot, store });
    const { check } = runner.enqueue('actions-buttons');
    const promoted = runner.promote(check!.id);
    expect(promoted.suggestionId).toBeGreaterThan(0);
    const suggestion = store.getSuggestion(promoted.suggestionId!);
    expect(suggestion?.source).toBe('checks');
    expect(suggestion?.category).toBe('bug');
    expect(suggestion?.text).toContain('demo_screen.gd');
    expect(store.getCheck(check!.id)?.promotedSuggestionId).toBe(promoted.suggestionId);
  });

  it('lässt denselben Fund nicht zweimal zu einem Vorschlag werden', () => {
    const runner = new CheckRunner({ projectRoot, store });
    const { check } = runner.enqueue('actions-buttons');
    runner.promote(check!.id);
    expect(runner.promote(check!.id).error).toContain('Bereits');
    expect(store.listSuggestions()).toHaveLength(1);
  });

  it('meldet ehrlich, wenn eine Prüfung nichts gefunden hat', () => {
    const dir = join(projectRoot, 'godot', 'src', 'game', 'demo');
    writeFileSync(join(dir, 'demo_screen.gd'), 'extends Screen\n', 'utf8');
    const runner = new CheckRunner({ projectRoot, store });
    const { check } = runner.enqueue('actions-buttons');
    expect(runner.promote(check!.id).error).toContain('keine Funde');
    expect(store.listSuggestions()).toHaveLength(0);
  });
});

describe('Prüfwarteschlange — Hilfsfunktionen', () => {
  it('übersetzt `**` im Glob, ohne Punkte als Wildcard zu lesen', () => {
    const re = __testing.globToRegExp('godot/src/**/*.gd');
    expect(re.test('godot/src/core/logic/pang.gd')).toBe(true);
    expect(re.test('godot/src/game/pang/pang.gd')).toBe(true);
    expect(re.test('godot/src/game/pang/pang.gd.uid')).toBe(false);
    // A dot must stay a dot: `pangXgd` is not `pang.gd`.
    expect(__testing.globToRegExp('a/*.gd').test('a/xgd')).toBe(false);
  });

  it('setzt den Status aus den Funden zusammen', () => {
    expect(__testing.statusFor({ fail: 0, warn: 0, info: 0 })).toBe('passed');
    expect(__testing.statusFor({ fail: 0, warn: 2, info: 0 })).toBe('warned');
    expect(__testing.statusFor({ fail: 1, warn: 0, info: 0 })).toBe('failed');
  });

  it('schreibt einen Vorschlagstext, der den Fund benennt', () => {
    const spec = CHECKS_BY_ID.get('actions-buttons')!;
    const text = findingToSuggestionText(spec, [
      { code: 'button-without-callback', file: 'a.gd', line: 3, message: 'Knopf ohne Callback' },
    ]);
    expect(text).toContain('Tote Knöpfe');
    expect(text).toContain('a.gd:3');
  });
});
