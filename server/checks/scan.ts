/**
 * Minimal GDScript scanner for the deployed-version checks.
 *
 * Why not a parser: the checks answer three narrow questions about source text
 * ("does this button have a callback", "does this per-frame function log",
 * "does this hot loop allocate"). A full grammar would be a large dependency
 * and would still have to survive GDScript's four syntaxes. This reads the
 * shape of the code instead, and every rule below is covered by a test so a
 * wrong answer is a failing test rather than a wrong verdict on a player's
 * phone.
 *
 * GDScript is indentation-scoped, so a function body is simply "the following
 * lines that are indented deeper". That is far more reliable here than trying
 * to track braces, which GDScript does not use.
 *
 * Not a security boundary: it never evaluates anything.
 */

/** One logical line: physical lines joined while brackets stay open. */
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
  /** Top-level arguments, comments and strings already removed. Empty when the call is cut short. */
  args: string[];
  /** True when brackets never balanced — the source is truncated or malformed. */
  unbalanced: boolean;
}

/** Functions whose body runs every frame. `print` or an allocation in one of these is a defect. */
export const PER_FRAME_FUNCTIONS = new Set(['_process', '_physics_process', '_update_world']);

/** Functions that run per input event — hot enough that logging there is still spam. */
export const HOT_FUNCTIONS = new Set([
  ...PER_FRAME_FUNCTIONS,
  '_draw',
  '_input',
  '_unhandled_input',
  '_gui_input',
  '_update_ui',
]);

/**
 * Removes a trailing `#` comment, respecting string literals.
 *
 * `"#1"` is text, `"a # b"` is text, but `x = 1 # weg` is a comment. Getting
 * this wrong would either hide a real `print` or invent one.
 */
export function stripComment(line: string): string {
  let inSingle = false;
  let inDouble = false;
  let inTriple = false;
  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];
    if (inTriple) {
      if (ch === '"' && line.startsWith('"""', i)) {
        inTriple = false;
        i += 2;
      }
      continue;
    }
    if (inSingle) {
      if (ch === "'") inSingle = false;
      continue;
    }
    if (inDouble) {
      if (ch === '"') inDouble = false;
      continue;
    }
    if (ch === '"') {
      if (line.startsWith('"""', i)) {
        inTriple = true;
        i += 2;
      } else {
        inDouble = true;
      }
      continue;
    }
    if (ch === "'") {
      inSingle = true;
      continue;
    }
    if (ch === '#') return line.slice(0, i);
  }
  return line;
}

/** Counts bracket depth of a fragment, ignoring brackets inside strings. */
function bracketDelta(text: string): number {
  let depth = 0;
  let inSingle = false;
  let inDouble = false;
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    if (inSingle) {
      if (ch === "'") inSingle = false;
      continue;
    }
    if (inDouble) {
      if (ch === '"') inDouble = false;
      continue;
    }
    if (ch === "'") inSingle = true;
    else if (ch === '"') inDouble = true;
    else if (ch === '(' || ch === '[' || ch === '{') depth += 1;
    else if (ch === ')' || ch === ']' || ch === '}') depth -= 1;
  }
  return depth;
}

/**
 * Joins physical lines into logical statements.
 *
 * A call spread over three lines is one statement, otherwise a check for "a
 * button without a callback" would fire on every wrapped call in the project.
 */
export function statements(source: string): GdStatement[] {
  const out: GdStatement[] = [];
  const lines = source.split('\n');
  let buffer: string | null = null;
  let startLine = 0;
  let startIndent = 0;

  for (let i = 0; i < lines.length; i += 1) {
    const raw = lines[i];
    const indent = /^\t*/.exec(raw)?.[0].length ?? 0;
    const stripped = stripComment(raw).replace(/\s+$/, '');
    const content = stripped.trim();

    if (buffer === null) {
      if (content === '') continue;
      buffer = content;
      startLine = i + 1;
      startIndent = indent;
    } else {
      buffer += ` ${content}`;
    }

    if (bracketDelta(buffer) <= 0) {
      out.push({ line: startLine, indent: startIndent, text: buffer });
      buffer = null;
    }
  }
  // A trailing fragment with open brackets: keep it, flagged as unbalanced by
  // the call parser. Dropping it silently would hide the very code we inspect.
  if (buffer !== null) out.push({ line: startLine, indent: startIndent, text: buffer });
  return out;
}

const FUNC_RE = /^(?:static\s+)?func\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/;

/**
 * Every function in the file with its body.
 *
 * Nested `func` keywords are lambdas; they stay part of the enclosing body,
 * which is what we want — a `print` inside a lambda called per frame is still a
 * `print` per frame.
 */
export function functionsOf(source: string): GdFunction[] {
  const stmts = statements(source);
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

/**
 * Splits a call's argument list at top-level commas, respecting nesting,
 * strings and lambdas. A lambda body may contain commas of its own
 * (`func(): return [1, 2]`), so depth tracking is the only safe split.
 */
export function splitArgs(argText: string): string[] {
  const args: string[] = [];
  let depth = 0;
  let current = '';
  let inSingle = false;
  let inDouble = false;
  for (let i = 0; i < argText.length; i += 1) {
    const ch = argText[i];
    if (inSingle) {
      if (ch === "'") inSingle = false;
      current += ch;
      continue;
    }
    if (inDouble) {
      if (ch === '"') inDouble = false;
      current += ch;
      continue;
    }
    if (ch === "'") inSingle = true;
    else if (ch === '"') inDouble = true;
    else if (ch === '(' || ch === '[' || ch === '{') depth += 1;
    else if (ch === ')' || ch === ']' || ch === '}') depth -= 1;

    if (ch === ',' && depth === 0) {
      args.push(current.trim());
      current = '';
      continue;
    }
    current += ch;
  }
  if (current.trim() !== '') args.push(current.trim());
  return args;
}

/** Finds the index of the `)` that closes the `(` at `open`. -1 when unbalanced. */
function matchingParen(text: string, open: number): number {
  let depth = 0;
  let inSingle = false;
  let inDouble = false;
  for (let i = open; i < text.length; i += 1) {
    const ch = text[i];
    if (inSingle) {
      if (ch === "'") inSingle = false;
      continue;
    }
    if (inDouble) {
      if (ch === '"') inDouble = false;
      continue;
    }
    if (ch === "'") inSingle = true;
    else if (ch === '"') inDouble = true;
    else if (ch === '(') depth += 1;
    else if (ch === ')') {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

/**
 * Every call of `callee` in the source, with its arguments.
 *
 * The name must be followed by `(`, which is what keeps `MyUi.buttonish(` from
 * matching `Ui.button`. A leading `.` is explicitly allowed so a qualified name
 * matches on its leaf — `Ui.button(` has to be found.
 */
export function callsOf(source: string, callee: string): GdCall[] {
  const out: GdCall[] = [];
  const leaf = callee.split('.').pop() as string;
  const stmts = statements(source);
  for (const stmt of stmts) {
    const re = new RegExp(`(?:^|[^A-Za-z0-9_])${leaf}\\s*\\(`, 'g');
    let match: RegExpExecArray | null;
    while ((match = re.exec(stmt.text)) !== null) {
      const open = match.index + match[0].length - 1;
      const close = matchingParen(stmt.text, open);
      // Recompute the physical line: the call may start on a later line of the
      // joined statement, and the finding should point at the real line.
      const before = stmt.text.slice(0, open);
      const newlines = (before.match(/\n/g) ?? []).length;
      if (close < 0) {
        out.push({ name: callee, line: stmt.line + newlines, args: [], unbalanced: true });
        continue;
      }
      const inner = stmt.text.slice(open + 1, close);
      out.push({
        name: callee,
        line: stmt.line + newlines,
        args: splitArgs(inner),
        unbalanced: false,
      });
      re.lastIndex = close;
    }
  }
  return out;
}

/**
 * Calls of `callee` inside the body of a function, with line numbers corrected
 * to the file.
 *
 * `callsOf` numbers from 1 because it is handed a fragment. Scanning a
 * function body means the fragment starts at some real line, so every hit is
 * shifted by that offset — otherwise a finding on the third line of a body
 * would point at line 3 of the file.
 */
export function callsInFunction(fn: GdFunction, callee: string): GdCall[] {
  if (fn.body.length === 0) return [];
  const first = fn.body[0].line;
  const text = fn.body
    .map((s) => ' '.repeat(Math.max(0, s.indent - fn.indent - 1) * 4) + s.text)
    .join('\n');
  return callsOf(text, callee).map((call) => ({ ...call, line: first + call.line - 1 }));
}
