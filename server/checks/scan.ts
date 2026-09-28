/**
 * Minimal GDScript scanner for the deployed-version checks.
 *
 * Why not a parser: the checks answer three narrow questions about source text
 * ("does this button have a callback", "does this per-frame function log",
 * "does this hot loop allocate"). A full grammar would be a large dependency and
 * would still have to survive GDScript's four syntaxes. This reads the shape of
 * the code instead, and every rule below is covered by a test, so a wrong answer
 * is a failing test rather than a wrong verdict on a player's phone.
 *
 * GDScript is indentation-scoped, so a function body is simply "the following
 * lines that are indented deeper" — far more reliable here than tracking braces,
 * which GDScript does not use.
 *
 * Not a security boundary: it never evaluates anything.
 */

/** One logical line: physical lines joined while brackets or a `"""` block stay open. */
export interface GdStatement {
  /** 1-based line number where the statement starts. */
  line: number;
  /** Indentation of the first physical line, in tabs (one tab = 1). */
  indent: number;
  /** Joined text with comments stripped and trailing whitespace removed. */
  text: string;
}

export interface GdFunction {
  name: string;
  /** 1-based line of the `func` keyword. */
  line: number;
  /** Indentation of the `func` line, in tabs. */
  indent: number;
  /** Statements belonging to the body, including nested lambdas. */
  body: GdStatement[];
}

export interface GdCall {
  /** Callee name, e.g. `Ui.button`. */
  name: string;
  /** 1-based line the call starts on. */
  line: number;
  /** Top-level arguments, comments already removed. Empty when the call is cut short. */
  args: string[];
  /** True when brackets never balanced — the source is truncated or malformed. */
  unbalanced: boolean;
}

/** Functions whose body runs every frame. `print` or an allocation in one of these is a defect. */
export const PER_FRAME_FUNCTIONS = new Set(['_process', '_physics_process', '_update_world']);

/**
 * Functions that run per input event — hot enough that logging there is still spam.
 *
 * Only names this project actually defines. `_update_ui` was in this list for a
 * year and matched no function anywhere, which made every rule phrased as "in a
 * hot function" quietly weaker than it reads.
 */
export const HOT_FUNCTIONS = new Set([
  ...PER_FRAME_FUNCTIONS,
  '_draw',
  '_input',
  '_unhandled_input',
  '_gui_input',
]);

/** String state, carried from one physical line to the next. */
export interface ScanState {
  inSingle: boolean;
  inDouble: boolean;
  inTriple: boolean;
}

/** Result of one pass over a fragment of source. */
export interface Scanned {
  /** Source with the comment tail removed and string contents kept. */
  text: string;
  /**
   * Same text, same length, with string contents blanked to spaces. Index
   * aligned with `text`, so a caller can ask "is this position inside a string?"
   * without a second walk. Brackets and commas inside a string are blanked too,
   * which is what makes the depth counter and the argument split safe.
   */
  mask: string;
  /** Net bracket depth this fragment added. */
  depth: number;
  /** String state after the fragment, for a `"""` block spanning several lines. */
  state: ScanState;
}

export function freshState(): ScanState {
  return { inSingle: false, inDouble: false, inTriple: false };
}

/**
 * The one string/comment state machine in this file.
 *
 * `stripComment`, the bracket counter, the argument split and the parenthesis
 * matcher used to be four loops of their own, each with its own idea of what a
 * string is, and none of them surviving a backslash escape. They all sit on top
 * of this one now: it walks a fragment once and hands back the code, a mask of
 * the same length, the bracket delta and the state for the next line.
 *
 * `"#1"` is text, `"a # b"` is text, but `x = 1 # weg` is a comment. Getting that
 * wrong would either hide a real `print` or invent one.
 */
export function scanCode(fragment: string, state: ScanState = freshState()): Scanned {
  const s: ScanState = { ...state };
  let text = '';
  let mask = '';
  let depth = 0;

  for (let i = 0; i < fragment.length; i += 1) {
    const ch = fragment[i];

    if (s.inTriple) {
      if (ch === '"' && fragment.startsWith('"""', i)) {
        s.inTriple = false;
        text += '"""';
        mask += '"""';
        i += 2;
      } else {
        mask += ' ';
      }
      continue;
    }

    if (s.inSingle || s.inDouble) {
      if (ch === '\\' && i + 1 < fragment.length) {
        const pair = fragment.slice(i, i + 2);
        text += pair;
        mask += '  ';
        i += 1;
        continue;
      }
      if (ch === (s.inSingle ? "'" : '"')) {
        s.inSingle = false;
        s.inDouble = false;
        text += ch;
        mask += ch;
        continue;
      }
      text += ch;
      mask += ' ';
      continue;
    }

    if (ch === '#') break;
    if (ch === '"' && fragment.startsWith('"""', i)) {
      s.inTriple = true;
      text += '"""';
      mask += '"""';
      i += 2;
      continue;
    }
    if (ch === '"' || ch === "'") {
      if (ch === '"') s.inDouble = true;
      else s.inSingle = true;
      text += ch;
      mask += ch;
      continue;
    }
    if (ch === '(' || ch === '[' || ch === '{') depth += 1;
    else if (ch === ')' || ch === ']' || ch === '}') depth -= 1;
    text += ch;
    mask += ch;
  }

  return { text, mask, depth, state: s };
}

/**
 * Removes a trailing `#` comment, respecting string literals.
 *
 * A thin wrapper over `scanCode` for callers that only want the text; a full
 * scan is the one place that knows what a string is.
 */
export function stripComment(line: string): string {
  return scanCode(line).text;
}

/**
 * Joins physical lines into logical statements.
 *
 * A call spread over three lines is one statement, otherwise a check for "a
 * button without a callback" would fire on every wrapped call in the project. A
 * `"""` block counts as part of the statement it sits in: a docstring inside a
 * function used to end the statement on its opening line, and its closing line —
 * indented zero — then terminated the enclosing function, so every check that
 * walks bodies reported on code below a docstring.
 */
export function statements(source: string): GdStatement[] {
  const out: GdStatement[] = [];
  const lines = source.split('\n');
  let buffer: string | null = null;
  let startLine = 0;
  let startIndent = 0;
  let depth = 0;
  let state = freshState();

  for (let i = 0; i < lines.length; i += 1) {
    const raw = lines[i];
    const indent = /^\t*/.exec(raw)?.[0].length ?? 0;
    const scanned = scanCode(raw, state);
    state = scanned.state;
    const content = scanned.text.replace(/\s+$/, '').trim();

    if (buffer === null) {
      // Blank line, comment, or the interior of a `"""` block: not a statement.
      if (content === '') continue;
      buffer = content;
      startLine = i + 1;
      startIndent = indent;
    } else {
      buffer += ` ${content}`;
    }
    depth += scanned.depth;

    if (depth <= 0 && !state.inTriple) {
      out.push({ line: startLine, indent: startIndent, text: buffer });
      buffer = null;
      depth = 0;
    }
  }
  // A trailing fragment with open brackets: keep it, flagged as unbalanced by
  // the call parser. Dropping it silently would hide the very code we inspect.
  if (buffer !== null) out.push({ line: startLine, indent: startIndent, text: buffer });
  return out;
}

const FUNC_RE = /^(?:static\s+)?func\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/;

/**
 * Every function in the already-parsed statements, with its body.
 *
 * Nested `func` keywords are lambdas and stay part of the enclosing body: a
 * `print` inside a lambda called per frame is still a `print` per frame. A
 * lambda does get its own entry in the result, which is how a caller can tell
 * an outer body from an inner one.
 */
export function functionsInStatements(stmts: GdStatement[]): GdFunction[] {
  const out: GdFunction[] = [];
  for (let i = 0; i < stmts.length; i += 1) {
    const match = FUNC_RE.exec(stmts[i].text);
    if (!match) continue;
    const indent = stmts[i].indent;
    const body: GdStatement[] = [];
    for (let j = i + 1; j < stmts.length; j += 1) {
      // A sibling or shallower statement ends the body.
      if (stmts[j].indent <= indent) break;
      body.push(stmts[j]);
    }
    out.push({ name: match[1], line: stmts[i].line, indent, body });
  }
  return out;
}

/** `functionsOf` for callers that only have the source. */
export function functionsOf(source: string): GdFunction[] {
  return functionsInStatements(statements(source));
}

/**
 * Splits a call's argument list at top-level commas, respecting nesting,
 * strings and lambdas. A lambda body may contain commas of its own
 * (`func(): return [1, 2]`), so depth tracking is the only safe split.
 */
export function splitArgs(argText: string): string[] {
  const { text, mask } = scanCode(argText);
  const args: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < mask.length; i += 1) {
    const ch = mask[i];
    if (ch === '(' || ch === '[' || ch === '{') depth += 1;
    else if (ch === ')' || ch === ']' || ch === '}') depth -= 1;
    else if (ch === ',' && depth === 0) {
      args.push(text.slice(start, i).trim());
      start = i + 1;
    }
  }
  const tail = text.slice(start).trim();
  if (tail !== '') args.push(tail);
  return args;
}

/** Finds the index of the `)` that closes the `(` at `open`. -1 when unbalanced. */
function matchingParen(text: string, open: number): number {
  // The mask is the same length as the text with string interiors blanked, so a
  // paren inside a string cannot be counted and the index stays valid.
  const { mask } = scanCode(text);
  let depth = 0;
  for (let i = open; i < mask.length; i += 1) {
    if (mask[i] === '(') depth += 1;
    else if (mask[i] === ')') {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * The boundary a callee has to start at.
 *
 * A qualified name matches only with its qualifier: `Ui.button(` is found,
 * `SomethingElse.button(` is not — matching on the leaf alone meant any future
 * `foo.button(` was checked as `Ui.button`. A bare name matches bare, so
 * `add_action_button(` is found whether it is written plain or as
 * `WorldScreen.add_action_button(`.
 */
function calleePattern(callee: string): RegExp {
  const name = escapeRegExp(callee);
  const boundary = callee.includes('.') ? '(?:^|[^A-Za-z0-9_.])' : '(?:^|[^A-Za-z0-9_])';
  return new RegExp(`${boundary}${name}\\s*\\(`, 'g');
}

/** `func add_action_button(` is a declaration, and it parses as a call. */
const DECLARATION_END_RE = /(?:^|[^\w])(?:static\s+)?(?:func|signal)\s*$/;

/**
 * Every call of `callee` in one statement, with the statement's own line.
 *
 * A statement is already a logical line, so the hit needs no shifting: the old
 * code re-derived the line from a rebuilt fragment and was wrong for every
 * function with a blank line in it.
 */
export function callsInStatement(stmt: GdStatement, callee: string): GdCall[] {
  const out: GdCall[] = [];
  const scanned = scanCode(stmt.text);
  const re = calleePattern(callee);
  let match: RegExpExecArray | null;

  while ((match = re.exec(scanned.text)) !== null) {
    const open = match.index + match[0].length - 1;
    const nameStart = /[A-Za-z0-9_]/.test(match[0][0]) ? match.index : match.index + 1;
    // `func add_action_button(text: String, …)` is a helper declaration inside a
    // file the check reads. It is not a call, and the typed default that used to
    // keep it out of the findings was luck, not a rule.
    if (DECLARATION_END_RE.test(scanned.text.slice(0, match.index))) continue;
    // A call written inside a string is text.
    if (scanned.mask[nameStart] === ' ') continue;

    const close = matchingParen(scanned.text, open);
    // Recompute the physical line: the call may start on a later line of the
    // joined statement, and the finding should point at the real line.
    const newlines = (scanned.text.slice(0, open).match(/\n/g) ?? []).length;
    if (close < 0) {
      out.push({ name: callee, line: stmt.line + newlines, args: [], unbalanced: true });
      continue;
    }
    out.push({
      name: callee,
      line: stmt.line + newlines,
      args: splitArgs(scanned.text.slice(open + 1, close)),
      unbalanced: false,
    });
    // Resume at the opening parenthesis, not behind it: it is the boundary the
    // nested call needs, so `print(print(x))` is two calls. The old jump went
    // past the closing parenthesis and the inner call was never seen.
    re.lastIndex = open;
  }
  return out;
}

/**
 * Every call of `callee` in the source, with its arguments.
 *
 * The name must be followed by `(`, which is what keeps `MyUi.buttonish(` from
 * matching `Ui.button`.
 */
export function callsOf(source: string, callee: string): GdCall[] {
  const out: GdCall[] = [];
  for (const stmt of statements(source)) out.push(...callsInStatement(stmt, callee));
  return out;
}

/**
 * Calls of `callee` inside a function body, each on the line its statement
 * really starts on.
 *
 * The body is walked statement by statement instead of being rebuilt as one
 * fragment: rebuilding it and re-counting lines was what made a finding in a
 * function with a blank line point at the wrong line.
 */
export function callsInFunction(fn: GdFunction, callee: string): GdCall[] {
  const out: GdCall[] = [];
  for (const stmt of fn.body) out.push(...callsInStatement(stmt, callee));
  return out;
}
