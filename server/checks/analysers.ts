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
 *   source: allocating in a per-frame function, or a loop bounded by something
 *   the player can grow.
 *
 * These need no device and no APK. The queue pairs them with a device probe of
 * the same name (see `catalogue.ts`) for the facts only a real phone produces.
 */
import {
  callsInFunction,
  callsOf,
  functionsOf,
  statements,
  HOT_FUNCTIONS,
  PER_FRAME_FUNCTIONS,
  type GdCall,
  type GdFunction,
} from './scan.js';
import type { CheckFinding, CheckKind } from '../../src/shared/types.js';

export interface CheckInput {
  /** Repo-relative path, used verbatim in findings. */
  file: string;
  source: string;
}

/** Names that are logging in GDScript, including Godot's own warning/error paths. */
const LOG_CALLS = ['print', 'print_rich', 'printerr', 'push_warning', 'push_error'];

const LOG_SEVERITY: Record<string, CheckFinding['severity']> = {
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
/** `var a := []` / `var d = {}` — a fresh container every frame. */
const ARRAY_LITERAL_ASSIGN_RE = /(?:^|[^A-Za-z0-9_])(?:var|const)\s+[A-Za-z_][A-Za-z0-9_]*\s*:?=\s*[[{]/;
const APPEND_RE = /\.append\(/;
/** Something in the body that empties a container again. */
const DRAINS_RE = /\.clear\(\)|\.erase\(|\.pop_|\.pop_front\(|queue_free/;

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
 * the log is unusable". Logging in a per-event function is a `warn`.
 */
export function checkLogs(input: CheckInput): CheckFinding[] {
  const findings: CheckFinding[] = [];
  for (const fn of functionsOf(input.source)) {
    if (!isHot(fn)) continue;
    const perFrame = isPerFrame(fn);
    for (const callee of LOG_CALLS) {
      for (const hit of callsInFunction(fn, callee)) {
        if (hit.unbalanced) continue;
        findings.push({
          kind: 'logs',
          code: perFrame ? 'log-per-frame' : 'log-in-hot-path',
          severity: perFrame ? 'fail' : 'warn',
          file: input.file,
          line: hit.line,
          function: fn.name,
          message: perFrame
            ? `${fn.name}() schreibt "${callee}" — das sind rund 60 Zeilen pro Sekunde.`
            : `${fn.name}() schreibt "${callee}" auf einem heißen Pfad.`,
          hint: perFrame
            ? 'Nur bei Zustandswechseln loggen, nicht pro Frame. Im Zweifel ganz entfernen.'
            : 'Auf Rate begrenzen oder in einen Ringpuffer schreiben.',
        });
      }
    }
  }
  return dedupe(findings);
}

/** Rough frame rate used only in the message text. */
function perFrameRate(): number {
  return 60;
}

/**
 * `performance` — allocations and unbounded work on a per-frame path.
 *
 * A `new` in `_process` runs 60 times a second and is the classic source of
 * GC hitches on Android. An `.append(` on a container that is never cleared is
 * the other classic: it does not lag at first and then lags forever.
 */
export function checkPerformance(input: CheckInput): CheckFinding[] {
  const findings: CheckFinding[] = [];
  for (const fn of functionsOf(input.source)) {
    if (!isPerFrame(fn)) continue;
    // A container that is emptied again somewhere in the same function is not
    // a leak. Judging per statement would report the append and miss the clear
    // on the next line, which is the normal shape of correct pooling code.
    const drains = fn.body.some((s) => DRAINS_RE.test(s.text));
    for (const stmt of fn.body) {
      if (ALLOC_RE.test(stmt.text)) {
        findings.push({
          kind: 'performance',
          code: 'alloc-per-frame',
          severity: 'fail',
          file: input.file,
          line: stmt.line,
          function: fn.name,
          message: `${fn.name}() erzeugt pro Frame ein neues Objekt.`,
          hint: 'Pool oder Member-Variable vorbelegen und wiederverwenden.',
        });
      }
      if (ARRAY_LITERAL_ASSIGN_RE.test(stmt.text)) {
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
      if (APPEND_RE.test(stmt.text) && !drains) {
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
  }
  return dedupe(findings);
}

/** Argument index of the `on_press` callback for each button helper. */
const BUTTON_LAYOUT: Record<string, { callbackIndex: number; actionIndex: number | null; label: string }> = {
  // Ui.button(text, size, accent, on_press)
  'Ui.button': { callbackIndex: 3, actionIndex: null, label: 'Ui.button' },
  // WorldScreen.add_action_button(text, radius, action, on_press, offset)
  'add_action_button': { callbackIndex: 3, actionIndex: 2, label: 'add_action_button' },
};

/** Callbacks that are syntactically present but do nothing. */
const NOOP_CALLBACKS = new Set(['Callable()', 'null', 'func():pass']);

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
  // `&""`, `""`, `''`, `StringName()`, `StringName("")`
  const literal = /^&?(['"])\1$/.exec(compact);
  if (literal) return true;
  if (/^StringName\((['"])?\1?\)$/.test(compact)) return true;
  if (/^StringName\((['"])\1\)$/.test(compact)) return true;
  return false;
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
  for (const stmt of stmts) {
    // One statement can hold several buttons (`add_child(Ui.button(…))`), so
    // every helper is looked up in it and the statement text decides whether a
    // later `connect` makes the button live.
    for (const [callee, layout] of Object.entries(BUTTON_LAYOUT)) {
      for (const call of callsOf(stmt.text, callee)) {
        if (call.unbalanced) continue;
        const { args } = call;
        const callback = args[layout.callbackIndex];
        const label = buttonLabel(args);
        const variable = assignedName(stmt.text);
        const connectedLater = variable !== null && isConnectedLater(variable, input.source);
        // `callsOf` numbers from 1 because it is handed a fragment; the
        // statement starts at `stmt.line`, so the hit has to be shifted. Without
        // this every finding points at line 1 and `dedupe` then collapses all
        // findings of one file into one.
        const line = stmt.line + call.line - 1;

        if (isEmptyish(callback)) {
          if (connectedLater) continue;
          // add_action_button may still be wired through its InputMap action.
          const action = layout.actionIndex === null ? undefined : args[layout.actionIndex];
          const hasAction = !isEmptyish(action);
          if (callee === 'add_action_button' && hasAction) continue;
          findings.push({
            kind: 'actions',
            code: 'button-without-callback',
            severity: 'fail',
            file: input.file,
            line,
            message: `${layout.label}(${label}) hat keinen Callback — der Knopf rendert und tut nichts.`,
            hint: 'Ui.button verbindet nur `if on_press.is_valid()`. Entweder den Callback mitgeben oder die Node-Variable danach mit `pressed.connect(…)` verdrahten.',
          });
          continue;
        }
        if (layout.actionIndex !== null && isEmptyish(args[layout.actionIndex])) {
          findings.push({
            kind: 'actions',
            code: 'button-without-action',
            severity: 'warn',
            file: input.file,
            line,
            message: `${layout.label}(${label}) hat keine Input-Action.`,
            hint: 'Ohne Action reagiert der Knopf nur auf den Callback, nicht auf Tastatur/Gamepad.',
          });
        }
      }
    }
  }
  return dedupe(findings);
}

/** Best-effort human label for a button call, for the finding text. */
function buttonLabel(args: GdCall['args']): string {
  const first = args[0];
  if (!first) return '…';
  const quoted = /^(['"])(.*)\1$/.exec(first.trim());
  if (quoted) return `"${quoted[2]}"`;
  return first.trim();
}

/** `var send := Ui.button(…)` — the name the node is reachable under. */
const ASSIGNED_BUTTON_RE =
  /(?:var|const)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:?=\s*(?:Ui\.button|add_action_button)\s*\(/;

/**
 * A variable a button is bound to, if the statement assigns one.
 *
 * A button does not have to receive its callback at construction. The idiomatic
 * split form builds the node first and connects it a few lines later, because the
 * handler is long and inlining a lambda would bury it. Flagging the first line as
 * a dead button would be a false positive on the project's own suggest dialog, so
 * the variable is resolved and the file is searched for a later connection to it.
 */
function assignedName(statement: string): string | null {
  const match = ASSIGNED_BUTTON_RE.exec(statement);
  return match ? match[1] : null;
}

/** `send.pressed.connect(…)` and friends, anywhere later in the file. */
function isConnectedLater(variable: string, source: string): boolean {
  const re = new RegExp(`\\b${variable}\\s*\\.\\s*(?:pressed|button_down|button_up|gui_input|focus_entered|item_selected|value_changed|toggled|timeout)\\s*\\.\\s*connect\\s*\\(`);
  return re.test(source);
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
