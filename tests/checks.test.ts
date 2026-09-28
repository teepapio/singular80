import { describe, expect, it } from 'vitest';
import {
  callsOf,
  functionsOf,
  statements,
  stripComment,
} from '../server/checks/scan.js';
import { checkActions, checkLogs, checkPerformance } from '../server/checks/analysers.js';

const file = 'godot/src/game/demo/demo_screen.gd';
const src = (text: string) => ({ file, source: text });

describe('GDScript-Scanner', () => {
  it('behält ein # innerhalb von Strings', () => {
    expect(stripComment('var a := "#1"')).toBe('var a := "#1"');
    expect(stripComment("var a := '#1'")).toBe("var a := '#1'");
    expect(stripComment('var a := 1 # weg')).toBe('var a := 1 ');
  });

  it('verbindet einen über mehrere Zeilen umbrochenen Aufruf zu einer Zeile', () => {
    const stmts = statements('Ui.button("A", Vector2(1, 2),\n\tUiTheme.PANEL,\n\t_cb)\nvar x = 1');
    expect(stmts).toHaveLength(2);
    expect(stmts[0].text).toContain('_cb)');
    expect(stmts[0].line).toBe(1);
    expect(stmts[1].text).toBe('var x = 1');
  });

  it('findet Funktionen mit ihrem Leib über die Einrückung', () => {
    const fns = functionsOf(
      ['func _process(delta):', '\tvar a := 1', '\tif a:', '\t\tprint(a)', 'func other():', '\tpass'].join(
        '\n',
      ),
    );
    expect(fns.map((f) => f.name)).toEqual(['_process', 'other']);
    expect(fns[0].body.map((s) => s.text)).toContain('print(a)');
    expect(fns[0].body.map((s) => s.text)).toContain('var a := 1');
  });

  it('zählt Lambda-Kommas nicht als Argumenttrenner', () => {
    const calls = callsOf('Ui.button("A", Vector2(1,2), UiTheme.X, func() -> void: return [1, 2])', 'Ui.button');
    expect(calls).toHaveLength(1);
    expect(calls[0].args).toHaveLength(4);
    expect(calls[0].args[3]).toContain('[1, 2]');
  });

  it('trifft keinen gleichnamigen Aufruf mit anderem Präfix', () => {
    expect(callsOf('MyUi.buttonish(1)', 'Ui.button')).toHaveLength(0);
    expect(callsOf('Ui.button(1)', 'Ui.button')).toHaveLength(1);
  });

  it('meldet den echten Zeilenumbruch eines umbrochenen Aufrufs', () => {
    const calls = callsOf('var a = 1\nUi.button(\n\t"T",\n\tV)', 'Ui.button');
    expect(calls[0].line).toBe(2);
  });
});

describe('Check: actions — tote Knöpfe', () => {
  it('meldet Ui.button ohne Callback', () => {
    const found = checkActions(
      src('var b := Ui.button("Speichern", Vector2(120, 40), UiTheme.PANEL_LIGHT)'),
    );
    expect(found).toHaveLength(1);
    expect(found[0].code).toBe('button-without-callback');
    expect(found[0].severity).toBe('fail');
    expect(found[0].message).toContain('Speichern');
  });

  it('lässt einen verdrahteten Knopf in Ruhe', () => {
    const found = checkActions(
      src('var b := Ui.button("Speichern", Vector2(120, 40), UiTheme.PANEL_LIGHT, func() -> void: save())'),
    );
    expect(found).toHaveLength(0);
  });

  it('meldet add_action_button ohne Action und ohne Callback', () => {
    const found = checkActions(src('var b := add_action_button("Feuer", 62.0)'));
    expect(found).toHaveLength(1);
    expect(found[0].code).toBe('button-without-callback');
  });

  it('akzeptiert add_action_button mit Action, auch ohne Callback', () => {
    // The action feeds the InputMap, hence keyboard and gamepad: the button works,
    // it is just not additionally bound to a callback.
    const found = checkActions(src('var b := add_action_button("Feuer", 62.0, &"fire")'));
    expect(found).toHaveLength(0);
  });

  it('warnt, wenn ein verdrahteter 3D-Knopf keine Action hat', () => {
    const found = checkActions(
      src('var b := add_action_button("Feuer", 62.0, &"", func() -> void: shoot())'),
    );
    expect(found).toHaveLength(1);
    expect(found[0].code).toBe('button-without-action');
    expect(found[0].severity).toBe('warn');
  });

  it('lässt einen vollständig verdrahteten 3D-Knopf in Ruhe', () => {
    const found = checkActions(
      src('var b := add_action_button("Feuer", 62.0, &"fire", func() -> void: shoot(), Vector2(4, 4))'),
    );
    expect(found).toHaveLength(0);
  });

  it('erkennt den Knopf, der erst danach verbunden wird', () => {
    // The shape from `suggest_dialog.gd`: build the node, attach the handler a few
    // lines later. Without that resolution the check calls the button dead.
    const real = [
      'var send := Ui.button("Absenden", Vector2(160, 48), UiTheme.ACCENT)',
      'actions.add_child(send)',
      'send.pressed.connect(func() -> void:',
      '\t_submit())',
    ].join('\n');
    expect(checkActions(src(real))).toHaveLength(0);
  });

  it('meldet weiterhin einen Knopf, der weder Callback noch connect bekommt', () => {
    const dead = [
      'var send := Ui.button("Absenden", Vector2(160, 48), UiTheme.ACCENT)',
      'actions.add_child(send)',
    ].join('\n');
    const found = checkActions(src(dead));
    expect(found).toHaveLength(1);
    expect(found[0].code).toBe('button-without-callback');
  });

  it('verwechselt zwei gleichnamige Variablen nicht', () => {
    // `send` is wired, `other` is not — both are buttons.
    const source = [
      'var send := Ui.button("Senden", Vector2(160, 48), UiTheme.ACCENT)',
      'var other := Ui.button("Verwerfen", Vector2(160, 48), UiTheme.PANEL_LIGHT)',
      'send.pressed.connect(func() -> void: _submit())',
    ].join('\n');
    const found = checkActions(src(source));
    expect(found).toHaveLength(1);
    expect(found[0].message).toContain('Verwerfen');
  });

  it('meldet zwei Knöpfe auf derselben Datei mit verschiedenen Zeilen', () => {
    // One finding per line: if both landed on line 1, `dedupe` would swallow one.
    const source = [
      'var a := add_action_button("◀", 56.0, &"", func() -> void: _shift(-1))', // Zeile 1
      'var b := add_action_button("▶", 56.0, &"", func() -> void: _shift(1))', // Zeile 2
    ].join('\n');
    const found = checkActions(src(source));
    expect(found).toHaveLength(2);
    expect(found.map((f) => f.line)).toEqual([1, 2]);
  });
});

describe('Check: logs — Logspam', () => {
  it('meldet print in einer Per-Frame-Funktion als Fehler', () => {
    const found = checkLogs(
      src(['func _process(delta):', '\tprint("tick")'].join('\n')),
    );
    expect(found).toHaveLength(1);
    expect(found[0].code).toBe('log-per-frame');
    expect(found[0].severity).toBe('fail');
    expect(found[0].line).toBe(2);
  });

  it('meldet push_error strenger als print', () => {
    const found = checkLogs(src(['func _update_world(dt):', '\tpush_error("x")'].join('\n')));
    expect(found[0].severity).toBe('fail');
  });

  it('meldet Logging in einer heißen, aber nicht Per-Frame-Funktion nur als Warnung', () => {
    const found = checkLogs(src(['func _input(event):', '\tprint("tap")'].join('\n')));
    expect(found[0].code).toBe('log-in-hot-path');
    expect(found[0].severity).toBe('warn');
  });

  it('lässt print in einer normalen Funktion in Ruhe', () => {
    expect(checkLogs(src(['func setup():', '\tprint("once")'].join('\n')))).toHaveLength(0);
  });

  it('sieht ein print, das über mehrere Zeilen umbrochen ist', () => {
    const found = checkLogs(
      src(['func _process(delta):', '\tprint("a",', '\t\t"b")'].join('\n')),
    );
    expect(found).toHaveLength(1);
  });
});

describe('Check: performance — Allokationen im Frame', () => {
  it('meldet new in einer Per-Frame-Funktion', () => {
    const found = checkPerformance(
      src(['func _process(delta):', '\tvar b := Bullet.new()'].join('\n')),
    );
    expect(found.some((f) => f.code === 'alloc-per-frame')).toBe(true);
  });

  it('meldet ein Array-Literal pro Frame', () => {
    const found = checkPerformance(src(['func _process(delta):', '\tvar a := []'].join('\n')));
    expect(found.some((f) => f.code === 'array-per-frame')).toBe(true);
  });

  it('meldet ein wachsendes append, aber nicht das clear() daneben', () => {
    const grow = checkPerformance(
      src(['func _process(delta):', '\t_items.append(1)'].join('\n')),
    );
    expect(grow.some((f) => f.code === 'append-per-frame')).toBe(true);
    const cleared = checkPerformance(
      src(['func _process(delta):', '\t_items.append(1)', '\t_items.clear()'].join('\n')),
    );
    expect(cleared.some((f) => f.code === 'append-per-frame')).toBe(false);
  });

  it('lässt new außerhalb des Frame-Pfads in Ruhe', () => {
    expect(checkPerformance(src(['func setup():', '\tvar b := Bullet.new()'].join('\n')))).toHaveLength(
      0,
    );
  });

  it('greift nicht bei new in einem Kommentar', () => {
    expect(
      checkPerformance(src(['func _process(delta):', '\t# var b := Bullet.new()'].join('\n'))),
    ).toHaveLength(0);
  });
});
