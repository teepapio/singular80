/**
 * The three check families for the deployed-version queue.
 *
 * Each family answers one player-visible complaint:
 *
 * - `actions`  — "the button does nothing". `Ui.button()` and
 *   `add_action_button()` connect their callback only `if on_press.is_valid()`,
 *   so a button with a missing callback renders perfectly and silently swallows
 *   the tap — invisible in a screenshot and in a review that only reads layout.
 * - `logs`     — "the game is loud". `print` in a per-frame function is ~60
 *   lines a second, and on Android logcat is a real cost: it shows up as
 *   stuttering and it buries the one line that matters.
 * - `performance` — "it lags". The static half catches the causes visible in
 *   source: allocating in a per-frame function, a loop bounded by something
 *   the player can grow, or redrawing a label that did not change.
 *
 * These need no device and no APK. The queue pairs them with a device probe of
 * the same name (see `catalogue.ts`) for the facts only a real phone produces.
 */
import {
  callsInFunction,
  callsInStatement,
  functionsInStatements,
  statements,
  HOT_FUNCTIONS,
  PER_FRAME_FUNCTIONS,
  scanCode,
  type GdCall,
  type GdFunction,
  type GdStatement,
} from './scan.js';
import type { CheckFinding, CheckKind, CheckSeverity } from '../../src/shared/types.js';

export interface CheckInput {
  /** Repo-relative path, used verbatim in findings. */
  file: string;
  source: string;
}

/** Names that are logging in GDScript, including Godot's own warning/error paths. */
const LOG_CALLS = ['print', 'print_rich', 'printerr', 'push_warning', 'push_error'];

/**
 * How serious a log call is on a hot path.
 *
 * A `print` there is noise; `push_error` there is a hard failure path that runs
 * 60 times a second, and it deserves a different verdict than the ternary at
 * the call site used to produce. This table used to exist and was never read.
 */
const LOG_SEVERITY: Record<string, CheckSeverity> = {
  print: 'warn',
  print_rich: 'warn',
  printerr: 'warn',
  push_warning: 'warn',
  push_error: 'fail',
};

/**
 * `Foo.new()` and `new Foo()` — the clearest per-frame allocation.
 *
 * `Foo.new()` is the idiom that actually appears in this project, so matching
 * only `new Foo` would miss nearly every real allocation.
 */
const ALLOC_RE = /(?:\.new\s*\(|\bnew\s+[A-Z])/;
/** The same pattern, global, for counting: `test` on a global regex walks `lastIndex`. */
const ALLOC_COUNT_RE = new RegExp(ALLOC_RE.source, 'g');
/** `var a := []` / `var d = {}` — a fresh container every frame. */
const ARRAY_LITERAL_ASSIGN_RE = /(?:^|[^A-Za-z0-9_])(?:var|const)\s+[A-Za-z_][A-Za-z0-9_]*\s*:?=\s*[[{]/;
const APPEND_RE = /\.append\(/;
/** The container an `append` writes to, so a drain can be judged on the same one. */
const APPEND_TARGET_RE = /([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*append\s*\(/;
/** Something that empties a named container again. */
const DRAIN_TARGET_RE =
  /([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*(?:clear|erase|pop_front|pop_back|pop_at|remove_at|assign)\s*\(/g;
/** A node handed back to the engine: its containers die with it. */
const FREE_TARGET_RE = /([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*queue_free\s*\(/g;
/**
 * The project's own rule, stated in AGENTS.md: redraw only on change.
 *
 * `queue_redraw()` and nothing else. `update(` is deliberately not in here: the
 * game calls its own `update(dt)` domain methods per frame, and those are the
 * game working, not the canvas repainting itself.
 */
const REDRAW_RE = /\bqueue_redraw\s*\(/;
/** A label, input or tooltip whose text is written per frame. */
const LABEL_TEXT_ASSIGN_RE =
  /^[A-Za-z_][A-Za-z0-9_.]*\.(?:text|placeholder_text|tooltip_text)\s*(?:=|\+=)/;

function isPerFrame(fn: GdFunction): boolean {
  return PER_FRAME_FUNCTIONS.has(fn.name);
}

function isHot(fn: GdFunction): boolean {
  return HOT_FUNCTIONS.has(fn.name);
}

/**
 * `logs` — logging on a hot path.
 *
 * Reports per-frame logging as `fail`: at 60 Hz a single `print` is ~3,600
 * lines a minute, and the player's symptom is exactly "the game stutters and
 * the log is unusable". Logging in a per-event function takes the severity of
 * the call itself, so a `push_error` there fails and a `print` only warns.
 */
export function checkLogs(input: CheckInput): CheckFinding[] {
  const findings: CheckFinding[] = [];
  for (const fn of functionsInStatements(statements(input.source))) {
    if (!isHot(fn)) continue;
    const perFrame = isPerFrame(fn);
    for (const callee of LOG_CALLS) {
      for (const hit of callsInFunction(fn, callee)) {
        if (hit.unbalanced) continue;
        const severity: CheckSeverity = perFrame ? 'fail' : LOG_SEVERITY[callee] ?? 'warn';
        findings.push({
          kind: 'logs',
          code: perFrame ? 'log-per-frame' : 'log-in-hot-path',
          severity,
          file: input.file,
          line: hit.line,
          function: fn.name,
          message: perFrame
            ? `${fn.name}() schreibt "${callee}" — das sind rund 60 Zeilen pro Sekunde.`
            : `${fn.name}() schreibt "${callee}" auf einem heißen Pfad.`,
          hint: perFrame
            ? 'Nur bei Zustandswechseln loggen, nicht pro Frame. Im Zweifel ganz entfernen.'
            : severity === 'fail'
              ? 'Ein Fehlerpfad in einer heißen Funktion. Auf ein Ereignis legen oder entfernen.'
              : 'Auf Rate begrenzen oder in einen Ringpuffer schreiben.',
        });
      }
    }
  }
  return dedupe(findings);
}

/**
 * `performance` — allocations and unbounded work on a per-frame path.
 *
 * A `new` in `_process` runs 60 times a second and is the classic source of
 * GC hitches on Android. An `.append(` on a container that is never emptied is
 * the other classic: it does not lag at first and then lags forever.
 *
 * A finding is one place to fix — a line — not one occurrence: a line with
 * three `new` in it is one defect, so the count in the summary counts defect
 * sites and reads as such. The count of occurrences is in the message.
 */
export function checkPerformance(input: CheckInput): CheckFinding[] {
  const findings: CheckFinding[] = [];
  for (const fn of functionsInStatements(statements(input.source))) {
    if (!isPerFrame(fn)) continue;
    // The rules below are patterns, not a parser, so they are matched against
    // the mask: a `Bullet.new()` inside a string or a `"""` block is text, and a
    // docstring is part of the statement it sits in — so its content would
    // otherwise be read as code.
    const masks = fn.body.map((s) => scanCode(s.text).mask);
    // Which containers this function empties again. Judged per container, not
    // per function: one unrelated `pop_front()` used to excuse every `append`
    // in the function, including one on a container that grows forever.
    const drained = new Set<string>();
    let anyDrain = false;
    for (const mask of masks) {
      if (/\bqueue_free\s*\(/.test(mask)) anyDrain = true;
      for (const m of mask.matchAll(DRAIN_TARGET_RE)) drained.add(m[1]);
      for (const m of mask.matchAll(FREE_TARGET_RE)) drained.add(m[1]);
    }

    for (let i = 0; i < fn.body.length; i += 1) {
      const stmt = fn.body[i];
      const mask = masks[i];
      if (ALLOC_RE.test(mask)) {
        const times = mask.match(ALLOC_COUNT_RE)?.length ?? 1;
        findings.push({
          kind: 'performance',
          code: 'alloc-per-frame',
          severity: 'fail',
          file: input.file,
          line: stmt.line,
          function: fn.name,
          message: times > 1
            ? `${fn.name}() erzeugt pro Frame ${times} neue Objekte.`
            : `${fn.name}() erzeugt pro Frame ein neues Objekt.`,
          hint: 'Pool oder Member-Variable vorbelegen und wiederverwenden.',
        });
      }
      if (ARRAY_LITERAL_ASSIGN_RE.test(mask)) {
        findings.push({
          kind: 'performance',
          code: 'array-per-frame',
          severity: 'warn',
          file: input.file,
          line: stmt.line,
          function: fn.name,
          message: `${fn.name}() legt pro Frame ein Array oder Dictionary an.`,
          hint: 'Einmal anlegen und leeren statt neu zu erzeugen.',
        });
      }
      if (APPEND_RE.test(mask)) {
        const target = APPEND_TARGET_RE.exec(mask)?.[1] ?? null;
        // An append on a receiver we cannot name keeps the old, forgiving
        // verdict: naming it wrongly would be a false accusation.
        const emptied = target === null ? anyDrain : drained.has(target);
        if (!emptied) {
          findings.push({
            kind: 'performance',
            code: 'append-per-frame',
            severity: 'warn',
            file: input.file,
            line: stmt.line,
            function: fn.name,
            message: `${fn.name}() hängt pro Frame etwas an einen Container an, ohne ihn zu leeren.`,
            hint: 'Pool vorallozieren und wiederverwenden — wächst er, lagt das Spiel mit der Zeit.',
          });
        }
      }
      if (REDRAW_RE.test(mask)) {
        findings.push({
          kind: 'performance',
          code: 'redraw-per-frame',
          severity: 'warn',
          file: input.file,
          line: stmt.line,
          function: fn.name,
          message: `${fn.name}() zeichnet pro Frame neu.`,
          hint: 'Nur bei Änderung `queue_redraw()` — sonst arbeitet der Canvas im Takt für ein Bild, das gleich bleibt.',
        });
      }
      if (LABEL_TEXT_ASSIGN_RE.test(mask)) {
        findings.push({
          kind: 'performance',
          code: 'text-per-frame',
          severity: 'warn',
          file: input.file,
          line: stmt.line,
          function: fn.name,
          message: `${fn.name}() setzt pro Frame einen Text.`,
          hint: 'Nur bei Wertänderung setzen — die Label-Layout-Pipeline rechnet sonst 60-mal pro Sekunde für dasselbe Ergebnis.',
        });
      }
    }
  }
  return dedupe(findings);
}

interface ButtonLayout {
  /**
   * Argument index of the `on_press` callback, or -1 for a form that takes no
   * callback at all and can only be wired by a later `connect`.
   */
  callbackIndex: number;
  actionIndex: number | null;
  label: string;
}

/**
 * The three forms a button takes in this project, with where the callback sits.
 *
 * `Button.new()` and its siblings are the form half the check did not see: a
 * hand-built button is wired exclusively through a later `pressed.connect(…)`,
 * so the callback argument does not exist and the node was invisible to the
 * rule that finds dead buttons — exactly the defect class the check exists for.
 */
const BUTTON_LAYOUT: Record<string, ButtonLayout> = {
  // Ui.button(text, size, accent, on_press)
  'Ui.button': { callbackIndex: 3, actionIndex: null, label: 'Ui.button' },
  // WorldScreen.add_action_button(text, radius, action, on_press, offset)
  'add_action_button': { callbackIndex: 3, actionIndex: 2, label: 'add_action_button' },
  // Button.new() — no callback argument, `pressed.connect(…)` is the only wiring.
  'Button.new': { callbackIndex: -1, actionIndex: null, label: 'Button.new' },
  'CheckButton.new': { callbackIndex: -1, actionIndex: null, label: 'CheckButton.new' },
  'TextureButton.new': { callbackIndex: -1, actionIndex: null, label: 'TextureButton.new' },
  'LinkButton.new': { callbackIndex: -1, actionIndex: null, label: 'LinkButton.new' },
};

/** Callbacks that are syntactically present but do nothing. */
const NOOP_CALLBACKS = new Set(['Callable()', 'null']);
/** A lambda whose whole body is `pass`, in every spelling `splitArgs` hands over. */
const NOOP_LAMBDA_RE = /^func\s*\(\s*\)\s*(?:->\s*[\w.]+\s*)?:\s*(?:pass|return\s+null)\s*$/;

/**
 * Whether an argument means "nothing was passed".
 *
 * GDScript spells an empty StringName five ways and the project uses several:
 * `&""`, `""`, `StringName()`. A check that only looks for a blank argument
 * would call `add_action_button("Feuer", 62.0, &"")` fully wired and miss the
 * button that ignores the keyboard.
 */
function isEmptyish(arg: string | undefined): boolean {
  if (arg === undefined) return true;
  const text = arg.trim();
  if (text === '') return true;
  const compact = text.replace(/\s+/g, '');
  if (NOOP_CALLBACKS.has(compact)) return true;
  if (NOOP_LAMBDA_RE.test(text)) return true;
  // `&""`, `""`, `''`, `StringName()`, `StringName("")`
  const literal = /^&?(['"])\1$/.exec(compact);
  if (literal) return true;
  if (/^StringName\((['"])?\1?\)$/.test(compact)) return true;
  if (/^StringName\((['"])\1\)$/.exec(compact)) return true;
  return false;
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * `actions` — buttons that render but do nothing.
 *
 * `Ui.button` connects only when the callable is valid, so a missing callback is
 * not an error anywhere: the tree builds, the screenshot looks right, the test
 * suite passes. This check turns "the button does nothing" into a failing check.
 */
export function checkActions(input: CheckInput): CheckFinding[] {
  const findings: CheckFinding[] = [];
  const stmts = statements(input.source);

  // Which function each statement belongs to. A button built in one function
  // and wired in another is a dead button: the old check resolved the name
  // against the whole file, so a `var button := Ui.button(…)` in function A was
  // excused by a `button.pressed.connect(…)` in function B. The name `button`
  // appears four times in `siedler_screen.gd` and twice in `poker_screen.gd`,
  // which is exactly the shape that hid them.
  const owner = new Map<number, GdFunction>();
  for (const fn of functionsInStatements(stmts)) {
    for (const stmt of fn.body) {
      if (!owner.has(stmt.line)) owner.set(stmt.line, fn);
    }
  }

  for (const stmt of stmts) {
    const fn = owner.get(stmt.line);
    // Inside a function the search is its own body; a statement at class level
    // has none, so the file is the scope there.
    const scope = fn ? fn.body.map((s) => s.text).join('\n') : input.source;
    findings.push(...buttonsInStatement(stmt, scope, input.file));
  }
  return dedupe(findings);
}

/** Every button in one statement, with the verdict for each. */
function buttonsInStatement(stmt: GdStatement, scope: string, file: string): CheckFinding[] {
  const out: CheckFinding[] = [];
  for (const [callee, layout] of Object.entries(BUTTON_LAYOUT)) {
    for (const call of callsInStatement(stmt, callee)) {
      if (call.unbalanced) continue;
      const { args } = call;
      const variable = assignedName(stmt.text, callee);
      const connectedLater = variable !== null && isConnectedLater(variable, scope);
      // `callsInStatement` numbers from the statement's own line, so the hit
      // needs no shifting. Every finding of one line then points at that line,
      // and `dedupe` collapses duplicates instead of merging different buttons.
      const line = call.line;
      const label = buttonLabel(args);

      if (isEmptyish(args[layout.callbackIndex])) {
        if (connectedLater) continue;
        // add_action_button may still be wired through its InputMap action.
        const action = layout.actionIndex === null ? undefined : args[layout.actionIndex];
        const hasAction = !isEmptyish(action);
        if (callee === 'add_action_button' && hasAction) continue;
        out.push({
          kind: 'actions',
          code: 'button-without-callback',
          severity: 'fail',
          file,
          line,
          message: `${layout.label}(${label}) hat keinen Callback — der Knopf rendert und tut nichts.`,
          hint: layout.callbackIndex < 0
            ? `${layout.label}() nimmt keinen Callback entgegen; der Knopf ist nur mit `
              + '`pressed.connect(…)` verdrahtet. Entweder die Node-Variable danach verbinden '
              + 'oder den Knopf gar nicht erst bauen.'
            : 'Ui.button verbindet nur `if on_press.is_valid()`. Entweder den Callback mitgeben oder die Node-Variable danach mit `pressed.connect(…)` verdrahten.',
        });
        continue;
      }
      if (layout.actionIndex !== null && isEmptyish(args[layout.actionIndex])) {
        out.push({
          kind: 'actions',
          code: 'button-without-action',
          severity: 'warn',
          file,
          line,
          message: `${layout.label}(${label}) hat keine Input-Action.`,
          hint: 'Ohne Action reagiert der Knopf nur auf den Callback, nicht auf Tastatur/Gamepad.',
        });
      }
    }
  }
  return out;
}

/** Best-effort human label for a button call, for the finding text. */
function buttonLabel(args: GdCall['args']): string {
  const first = args[0];
  if (!first) return '';
  const quoted = /^(['"])(.*)\1$/.exec(first.trim());
  if (quoted) return `"${quoted[2]}"`;
  return first.trim();
}

/**
 * A variable a button is bound to, if the statement assigns one.
 *
 * A button does not have to receive its callback at construction. The idiomatic
 * split form builds the node first and connects it a few lines later, because the
 * handler is long and inlining a lambda would bury it. Flagging the first line as
 * a dead button would be a false positive on the project's own suggest dialog, so
 * the variable is resolved and its function is searched for a later connection.
 */
function assignedName(statement: string, callee: string): string | null {
  const re = new RegExp(
    `(?:var|const)\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*:?=\\s*${escapeRegExp(callee)}\\s*\\(`,
  );
  const match = re.exec(statement);
  return match ? match[1] : null;
}

/** `send.pressed.connect(…)` and friends, in the given scope. */
const CONNECT_CHAIN =
  '(?:pressed|button_down|button_up|gui_input|focus_entered|item_selected|value_changed|toggled|timeout)';

function isConnectedLater(variable: string, scope: string): boolean {
  const re = new RegExp(`\\b${escapeRegExp(variable)}\\s*\\.\\s*${CONNECT_CHAIN}\\s*\\.\\s*connect\\s*\\(`);
  // Masked per line, so a connect written in a string or a comment does not
  // count as wiring.
  return scope.split('\n').some((line) => re.test(scanCode(line).mask));
}

/** Findings carry a code, file and line; the same defect can be reached twice. */
function dedupe(findings: CheckFinding[]): CheckFinding[] {
  const seen = new Set<string>();
  const out: CheckFinding[] = [];
  for (const finding of findings) {
    const key = `${finding.code}|${finding.file}|${finding.line}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(finding);
  }
  return out.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line);
}

export const ANALYSERS: Record<CheckKind, (input: CheckInput) => CheckFinding[]> = {
  actions: checkActions,
  logs: checkLogs,
  performance: checkPerformance,
};
