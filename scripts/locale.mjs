#!/usr/bin/env node
/**
 * Language catalogues: extraction, merging and the drift check.
 *
 * The game carries two kinds of key in one file. `keys` are hand-written
 * identifiers (`ui.back_to_lobby`) used as `Loc.t("ui.…")`. `text` are the
 * German source strings themselves, so every existing caption gets a
 * translation without rewriting 650 call sites; a missing translation shows
 * the German original, never a key and never an empty line.
 *
 * The `text` half of `de.json` is therefore generated and a run of this script
 * is the source of truth. `en.json` and `fr.json` are hand-written; `sync` tops
 * them up without touching existing translations.
 *
 *   node scripts/locale.mjs list      catalogues and their coverage
 *   node scripts/locale.mjs sync      write de.json, top up the others, mirror
 *   node scripts/locale.mjs check     drift and structure (npm test)
 */
import {
  readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync, copyFileSync,
} from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const godotRoot = join(root, 'godot');
const sourceDir = join(root, 'locale');
const mirrorDir = join(godotRoot, 'assets', 'locale');
const excludeFile = join(sourceDir, 'exclude.json');
const content = join(root, 'content');

/**
 * The language the source is written in — and it is the language of the *code*,
 * not the language of the game. `godot/src` holds English literals, `sync`
 * derives `en.json` from them, and `de.json` and `fr.json` translate that.
 *
 * The direction is deliberate. A gettext catalogue is a list of msgids that
 * everyone on the project can read, and a msgid nobody can read is one nobody
 * can fix. German was the wrong pivot for a codebase whose comments, its
 * identifiers and its git history are English: a translator working from a
 * German key had to guess what the sentence meant before they could translate
 * it, and the source of truth was a file the rest of the repository cannot
 * read.
 */
export const SOURCE = 'en';
/** Catalogues `sync` creates when a translation does not exist yet. */
const TARGETS = ['de', 'fr'];

/**
 * Call sites whose string literal a player reads.
 *
 * `first` means the literal is the first argument — the text itself. With `any`
 * a later position counts too (`notify("…", 3.0)`).
 */
const SOURCES = [
  { call: 'Loc.t', first: true, kind: 'key' },
  { call: 'Loc.tn', first: true, kind: 'key' },
  // `Loc.f` carries a German template with `%` placeholders, not an identifier.
  // Someone passing `ui.something` meant `Loc.t`, so `check` says so out loud
  // instead of filing the identifier under `text`.
  { call: 'Loc.f', first: true, kind: 'text' },
  { call: 'Ui.label', first: true, kind: 'text' },
  { call: 'Ui.title', first: true, kind: 'text' },
  { call: 'Ui.button', first: true, kind: 'text' },
  { call: 'Ui.value_label', first: true, kind: 'text' },
  { call: 'show_toast', first: true, kind: 'text' },
  { call: 'notify', any: true, kind: 'text' },
  { call: 'set_hint', any: true, kind: 'text' },
  { call: 'add_item', any: true, kind: 'text' },
  { call: 'set_item_text', any: true, kind: 'text' },
];

/** Assignments whose right-hand side is visible text. */
const ASSIGNMENTS = [
  { key: 'placeholder_text', kind: 'text' },
  { key: 'tooltip_text', kind: 'text' },
  { key: 'text', kind: 'text' },
  { key: 'title', kind: 'text' },
  { key: 'window_title', kind: 'text' },
  { key: 'dialog_text', kind: 'text' },
];

/**
 * Dictionary keys in the data modules: the text most visible in the game and
 * least of it at a call site.
 */
const DICT_KEYS = new Set([
  'name', 'names', 'description', 'desc', 'tagline', 'title', 'label', 'hint', 'reason',
  'text', 'flavour', 'flavor', 'objective', 'summary', 'tip',
]);

/** Directories that hold no translatable text. */
const SKIP_DIRS = new Set(['tests', '.godot', 'android', 'build', 'node_modules', 'dist']);

/**
 * A `const NAME: Array[String] = [ … ]` whose name ends in `_LOC_KEYS` holds
 * translation keys and no sentences.
 *
 * `AppLegal.REASON_LOC_KEYS` is such a list: six strings that run through
 * `Loc.t` elsewhere. The suffix is deliberately that long — `asset_registry.gd`
 * has a dozen `const …_KEYS` lists full of asset names, and a short name would
 * have reported `crystal`, `tree` and `pumpkin` as translatable identifiers.
 */
const KEY_ARRAY = /const\s+\w*_LOC_KEYS\s*(?::\s*Array\[String\]\s*)?=\s*\[[^\]]*$/;

// --- reading the source ------------------------------------------------------

/** Every `.gd` file under `godot/src`, stably sorted. */
function sourceFiles(dir = join(godotRoot, 'src'), out = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      sourceFiles(join(dir, entry.name), out);
    } else if (entry.name.endsWith('.gd')) {
      out.push(join(dir, entry.name));
    }
  }
  return out;
}

/**
 * Splits GDScript roughly into literals and the text in front of them.
 *
 * A real parser would be overkill, but comments have to go: the `##`
 * documentation is almost entirely German sentences and would flood the
 * catalogue with thousands of entries nobody ever sees.
 */
function scan(text) {
  const found = [];
  const n = text.length;
  let i = 0;
  while (i < n) {
    const ch = text[i];
    if (ch === '#') {
      while (i < n && text[i] !== '\n') i += 1;
      continue;
    }
    if (ch !== '"' && ch !== "'") {
      i += 1;
      continue;
    }
    const quote = ch;
    const start = i;
    i += 1;
    let value = '';
    let closed = false;
    while (i < n) {
      const c = text[i];
      if (c === '\\') {
        value += unescape(text[i + 1]);
        i += 2;
        continue;
      }
      if (c === quote) {
        closed = true;
        i += 1;
        break;
      }
      if (c === '\n') break; // unterminated: not a literal
      value += c;
      i += 1;
    }
    if (closed) found.push({ value, before: text.slice(0, start) });
  }
  return found;
}

function unescape(c) {
  switch (c) {
    case 'n': return '\n';
    case 't': return '\t';
    case 'r': return '\r';
    case '0': return '\0';
    case undefined: return '';
    default: return c;
  }
}

/** The trimmed context right before a literal: the call that owns it. */
function contextOf(before) {
  let end = before.length;
  let start = end;
  while (start > 0 && !' \t\n'.includes(before[start - 1])) start -= 1;
  const tail = before.slice(start, end);
  // `"name": ` and `.text = ` both end in a separator, not a name. A directly
  // enclosing call wins: `Ui.title(Loc.t("…"))` is a `Loc.t` site even though a
  // `Ui.title(` sits further out.
  const open = /([A-Za-z_][\w.]*)\s*\($/.exec(before);
  if (open) return { call: open[1], argIndex: 0 };
  // Then a call in which nothing has closed the first argument since the
  // bracket. Without that condition the same expression still matches
  // `Loc.t("ui.x", {` and takes the dictionary key `"mode"` for argument one.
  const first = /([A-Za-z_][\w.]*)\s*\(([^,{}()]*)$/.exec(before);
  if (first) return { call: first[1], argIndex: 0 };
  const afterComma = /,\s*$/.test(before);
  const later = /([A-Za-z_][\w.]*)\s*\(([^()]*)$/.exec(before);
  if (later && afterComma) return { call: later[1], argIndex: 1 };
  const assign = /([A-Za-z_][\w.]*)\s*=\s*$/.exec(before);
  if (assign) return { prop: assign[1], argIndex: 0 };
  const dictKey = /"([\w]+)"\s*:\s*$/.exec(before);
  if (dictKey) return { dictKey: dictKey[1], argIndex: 0 };
  return { argIndex: afterComma ? 1 : -1, tail };
}

const ICON = /^[\u2190-\u2bff\u25a0-\u25ff\u2600-\u27bf\ufe0f\s]+$/u;
const ACCENTED = /[ÄÖÜäöüßÀÉÈÊàéèêÁÍÓÚáíóúÑñÇçÂÊÎÔÛâêîôûÆæŒœŠšŸŽž]/;
const ANY_LETTER = /[A-Za-zÄÖÜäöüßÀÉÈÊàéèêÁÍÓÚáíóúÑñÇçÂÊÎÔÛâêîôûÆæŒœŠšŸŽž]/;

/**
 * Decides whether a literal is text a *player* sees.
 *
 * There are longer lists of reasons to drop a literal than to keep one: ids,
 * paths, colours, asset keys and format strings look exactly like a sentence in
 * the source. A lax filter files ids in the catalogue, and translating them
 * produces nonsense that is visible in the game.
 */
export function isDisplayText(value, kind) {
  if (!value || value.length > 400) return false;
  if (ICON.test(value)) return false;                       // a symbol, not text
  // An identifier *is* the key by definition — it looks like an id in the
  // source, so this check must run before the id filter below.
  if (kind === 'key') return /^[a-z][\w]*(\.[\w]+)+$/.test(value) || /^[a-z][\w]*$/.test(value);
  if (/^[-+]?[\d.,]+$/.test(value)) return false;             // a number
  if (/^(res|user):\/\//.test(value)) return false;          // a path
  if (/^[a-z][\w.:-]*$/.test(value)) return false;            // id, hex, asset key
  if (/^#[0-9a-fA-F]{3,8}$/.test(value)) return false;        // a colour
  if (!ANY_LETTER.test(value)) return false;
  if (/^%\d*\.?\d*[sdfx]$/.test(value)) return false;        // a bare format string
  // Only format characters: "%s · %s" is a pattern, not a sentence.
  const stripped = value.replace(/%[-+ #0-9.]*[sdfx%]/g, '').replace(/[{}]/g, '').trim();
  if (stripped === '') return false;
  // A numbered variant name: "3D Adventures", "2D-Platformer". It begins with a
  // digit, so the rule below reads it as an id and drops it — which is how
  // "3D-Abenteuer" survived the switch to an English source as the one German
  // word left in the lobby. No asset key has this shape: they are lowercase
  // words or `candy/bonbon`, and the only one with a digit is `crystal1`.
  if (/^\d+[A-Za-z]+[-–]/.test(value)) return true;
  // A word with neither a space nor a vowel is usually a proper noun ("Tetris",
  // "2048", "Railgun") — nobody translates those, and a wrong one is visible.
  const isWord = /\s/.test(value) || ACCENTED.test(value);
  return isWord || /^[A-ZÄÖÜÀÁÂÃÅÆÇÉÈÊËÍÎÏÑÓÔÕØŒŠÙÛÝ]/.test(value);
}

/** Display names and descriptions out of the content packs. */
function contentText() {
  const out = [];
  if (!existsSync(content)) return out;
  for (const name of readdirSync(content).sort()) {
    if (!name.endsWith('.json')) continue;
    const parsed = JSON.parse(readFileSync(join(content, name), 'utf8'));
    const walk = (node) => {
      if (Array.isArray(node)) {
        node.forEach(walk);
        return;
      }
      if (!node || typeof node !== 'object') return;
      for (const field of ['name', 'description', 'tagline']) {
        const value = node[field];
        if (typeof value === 'string' && isDisplayText(value, 'text')) out.push(value);
      }
      Object.values(node).forEach(walk);
    };
    walk(parsed);
  }
  return out;
}

/** Every visible literal in the project. */
export function collect() {
  const keys = new Map();
  const text = new Map();
  const locF = [];              // `Loc.f` templates that look like an identifier
  for (const file of sourceFiles()) {
    const rel = file.slice(godotRoot.length + 1);
    for (const { value, before } of scan(readFileSync(file, 'utf8'))) {
      const ctx = contextOf(before);
      let kind = null;
      const source = SOURCES.find((s) => s.call === ctx.call
        && (s.first ? ctx.argIndex === 0 : true));
      if (source) kind = source.kind;
      else if (ctx.prop && ASSIGNMENTS.some((a) => a.key === ctx.prop)) kind = 'text';
      else if (ctx.dictKey && DICT_KEYS.has(ctx.dictKey)) kind = 'text';
      else if (KEY_ARRAY.test(before.slice(-400))) kind = 'key';
      if (!kind) continue;
      if (!isDisplayText(value, kind)) continue;
      // The catalogue maps each entry to *itself*: the German sentence is both
      // the key and, in `de.json`, the value. Mapping to the file it was found
      // in produced catalogues whose values were paths, and the game then showed
      // `src/game/siedler/siedler_screen.gd` instead of a sentence. The key is
      // the search term; `grep` finds the call site.
      if (kind === 'key') keys.set(value, value);
      else {
        text.set(value, value);
        if (ctx.call === 'Loc.f' && /^[a-z][\w]*(\.[\w]+)+$/.test(value)) locF.push({ value, rel });
      }
    }
  }
  for (const value of contentText()) text.set(value, value);
  return { keys, text, locF };
}

// --- the format lint --------------------------------------------------------

/** `Loc.f("…", [ … ])`: a literal template with an argument list right behind it. */
const LOC_F_SITE = /Loc\.f\(\s*("(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*')\s*,/g;

const BRACKET_OPEN = new Map([['(', ')'], ['[', ']'], ['{', '}']]);
const BRACKET_CLOSE = new Set([')', ']', '}']);
const IDENT_CHAR = /[A-Za-z_]/;
/** What may sit between the comma after a template and the list behind it. */
const BLANK = ' \t\n\r';
/** The flags and conversions of `Loc._count_specifiers`, in that order. */
const SPECIFIER_FLAGS = '-+#0123456789.*';
const SPECIFIER_CONVERSIONS = 'sdfxXo';
/** Templates are quoted in full in a problem message until they get silly. */
const LONG_TEMPLATE = 60;

/**
 * How many `%` placeholders a template has — `%%` does not count as one.
 *
 * A copy of `Loc._count_specifiers`, quirks included: a space is not a flag,
 * because `+12 % Feuerrate` is a percent sign in a sentence and not a format
 * string. Two counters that disagree about that would call a template and its
 * own arguments incompatible over nothing but the case of one letter.
 */
function countSpecifiers(text) {
  let count = 0;
  let i = 0;
  while (i < text.length) {
    if (text[i] !== '%') {
      i += 1;
      continue;
    }
    if (text[i + 1] === '%') {
      i += 2;
      continue;
    }
    let j = i + 1;
    while (j < text.length && SPECIFIER_FLAGS.includes(text[j])) j += 1;
    if (j < text.length && SPECIFIER_CONVERSIONS.includes(text[j])) count += 1;
    i = j + 1;
  }
  return count;
}

/** The index of the quote that closes the literal at `start`, or -1. */
function closingQuote(text, start) {
  const quote = text[start];
  for (let i = start + 1; i < text.length; i += 1) {
    if (text[i] === '\\') {
      i += 1;
      continue;
    }
    if (text[i] === '\n') return -1;                     // unterminated
    if (text[i] === quote) return i;
  }
  return -1;
}

/**
 * The elements of the bracket list that opens at `open`, plus the identifiers
 * that stand on its own level.
 *
 * `null` for anything that cannot be counted with certainty: an unbalanced
 * bracket, a `"""` block, a comment that could be hiding a comma. Reporting a
 * site out of doubt costs more than the mistake it was meant to catch, because
 * the false alarm is the one somebody has to go and read.
 */
function listElements(text, open) {
  if (text[open] !== '[') return null;                   // a variable, a call, no list
  const stack = [];
  const parts = [];
  const words = new Set();
  let start = open + 1;
  let word = '';
  const flush = () => {
    if (word !== '') words.add(word);
    word = '';
  };
  for (let i = open + 1; i < text.length; i += 1) {
    const c = text[i];
    if (c === '#') return null;                          // a comment may hold a comma
    if (c === '"' || c === "'") {
      if (text.slice(i, i + 3) === c.repeat(3)) return null;
      flush();
      const end = closingQuote(text, i);
      if (end < 0) return null;
      i = end;
    } else if (BRACKET_OPEN.has(c)) {
      flush();
      stack.push(BRACKET_OPEN.get(c));
    } else if (c === ']' && stack.length === 0) {
      parts.push(text.slice(start, i));
      return { parts, words };
    } else if (BRACKET_CLOSE.has(c)) {
      flush();
      if (stack.pop() !== c) return null;
    } else if (c === ',' && stack.length === 0) {
      flush();
      parts.push(text.slice(start, i));
      start = i + 1;
    } else if (IDENT_CHAR.test(c)) {
      word += c;
    } else {
      flush();
    }
  }
  return null;
}

/**
 * The `Loc.f` call sites whose placeholders and values disagree.
 *
 * The mistake this exists for is silent. In `"TEMP" % n if n > 0 else "OTHER"`
 * the `%` binds tighter than the conditional, so a migration that moves the `%`
 * into the argument list hands a string to a `%d` and Godot answers at runtime
 * with `String formatting error: a number is required` — in a level, in
 * whichever language the player picked. A file that parses is not a file that
 * formats.
 */
export function formatMismatches(text, file) {
  const problems = [];
  LOC_F_SITE.lastIndex = 0;
  for (let m = LOC_F_SITE.exec(text); m; m = LOC_F_SITE.exec(text)) {
    // A commented-out call is not a call. GDScript comments run to the end of
    // the line, so the marker only has to be looked for on the site's own line.
    const lineStart = text.lastIndexOf('\n', m.index - 1) + 1;
    if (text.slice(lineStart, m.index).includes('#')) continue;
    const template = m[1].slice(1, -1).replace(/\\(.)/g, (_, c) => unescape(c));
    // `m[0]` ends on the comma; the list may start a line further down.
    let open = m.index + m[0].length;
    while (BLANK.includes(text[open])) open += 1;
    const list = listElements(text, open);
    if (!list) continue;                                // not countable with certainty
    // A conditional on the top level may feed a different shape per branch,
    // and which branch runs is not a question a linter can answer.
    //
    // This is also where the mistake the check was written for used to hide:
    // `Loc.f("· %d Sterne benötigt", [need if need > 0 else "· Level %d zuerst"
    // % (n - 1)])` has one placeholder and one value, so no count disagrees —
    // what is wrong there is the *type* of one branch, and only the type can
    // say so. A counting lint is blind there on purpose; see the note in
    // `tests/locale.test.ts` before turning this skip into a report.
    if (list.words.has('if')) continue;
    const values = list.parts.filter((part) => part.trim() !== '').length;
    const want = countSpecifiers(template);
    if (want === values) continue;
    const shown = template.length > LONG_TEMPLATE
      ? `${template.slice(0, LONG_TEMPLATE)}…`
      : template;
    const line = text.slice(0, m.index).split('\n').length;
    problems.push(`Loc.f("${shown}") in ${file}:${line} hat ${want} `
      + `${want === 1 ? 'Platzhalter' : 'Platzhaltern'}, bekommt aber ${values} `
      + `${values === 1 ? 'Wert' : 'Werte'}`);
  }
  return problems;
}

/** Every `Loc.f` mismatch in the game code, phrased the way `check` wants it. */
export function formatMismatchesInProject() {
  const problems = [];
  for (const file of sourceFiles()) {
    problems.push(...formatMismatches(readFileSync(file, 'utf8'), file.slice(root.length + 1)));
  }
  return problems;
}

// --- catalogues --------------------------------------------------------------

function readCatalogue(code) {
  const file = join(sourceDir, `${code}.json`);
  if (!existsSync(file)) return null;
  const parsed = JSON.parse(readFileSync(file, 'utf8'));
  if (!parsed || typeof parsed !== 'object') throw new Error(`${code}.json ist kein Objekt`);
  return {
    code,
    name: parsed.name ?? code,
    native: parsed.native ?? parsed.name ?? code,
    note: parsed.note ?? '',
    numbers: { decimal: '.', group: ',', ...(parsed.numbers ?? {}) },
    keys: parsed.keys ?? {},
    text: parsed.text ?? {},
  };
}

/**
 * A file name is a language catalogue when it looks like a language code.
 *
 * `locale/` also holds `exclude.json` and `identical.json`, which are tools for
 * this script and not translations. Deciding by name means `Loc` can read
 * `res://assets/locale` without ever meeting a tool file and calling it a
 * language, and the mirror below copies exactly the catalogues.
 */
const CATALOGUE_FILE = /^[a-z]{2}(-[A-Za-z0-9]+)*\.json$/;
const IDENTICAL_FILE = 'identical.json';

export function readAll() {
  const out = new Map();
  if (!existsSync(sourceDir)) return out;
  for (const name of readdirSync(sourceDir).sort()) {
    if (!CATALOGUE_FILE.test(name)) continue;
    out.set(name.replace(/\.json$/, ''), readCatalogue(name.replace(/\.json$/, '')));
  }
  return out;
}


/**
 * Per language: the entries that stay equal to the German on purpose.
 *
 * The list exists to keep the coverage figure honest, and "honest" is a property
 * of one language, not of all of them. "Bonbonland" *is* the French name of the
 * Candy world while the English one says "Candy Land", so one shared list would
 * either call the French untranslated or excuse the English.
 */
function readIdentical() {
  const file = join(sourceDir, IDENTICAL_FILE);
  if (!existsSync(file)) return new Map();
  return JSON.parse(readFileSync(file, 'utf8'));
}


/** The set for one language, in the shape `coverage` wants. */
export function identicalSet(all, code) {
  const entry = readIdentical()[code] ?? {};
  if (typeof entry !== 'object' || entry === null) return new Set();
  return new Set([
    ...(Array.isArray(entry.keys) ? entry.keys : []),
    ...(Array.isArray(entry.text) ? entry.text : []),
  ]);
}

function readExcludes() {
  if (!existsSync(excludeFile)) return { text: [], keys: [] };
  const parsed = JSON.parse(readFileSync(excludeFile, 'utf8'));
  return { text: parsed.text ?? [], keys: parsed.keys ?? [] };
}

/** A catalogue in the order it is written out. */
function serialise(catalogue) {
  const sorted = (obj) => Object.fromEntries(
    Object.entries(obj).sort(([a], [b]) => a.localeCompare(b, 'en')),
  );
  const out = {
    code: catalogue.code,
    name: catalogue.name,
    native: catalogue.native,
  };
  if (catalogue.note) out.note = catalogue.note;
  out.numbers = catalogue.numbers;
  out.keys = sorted(catalogue.keys);
  out.text = sorted(catalogue.text);
  return `${JSON.stringify(out, null, 2)}\n`;
}

/** How much is translated, split into hand-written and generated. */
export function coverage(catalogue, source, identical = new Set()) {
  const count = (wanted, have) => {
    const keys = Object.keys(wanted);
    // Entries `locale/identical.json` marks as equal in every language on
    // purpose — brand names, symbol patterns, loanwords — leave the denominator.
    // Calling "Tetris" untranslated would turn the number into a complaint about
    // the one thing that is right. The count stays in the report, so the
    // exclusion cannot be used to hide real gaps.
    const open = keys.filter((k) => !identical.has(k));
    // A translation is one that differs from the German source; an entry filled
    // in but left unchanged does not count as finished. The comparison goes
    // through JSON so a plural entry — an object of forms, not a string — counts
    // like any other; a `typeof === 'string'` test would silently exclude every
    // plural in the game and report them as open forever.
    const done = open.filter((k) => have[k] !== undefined
      && JSON.stringify(have[k]) !== JSON.stringify(wanted[k])).length;
    return { done, total: open.length, same: keys.length - open.length, open: open.length - done };
  };
  const k = count(source.keys, catalogue.keys);
  const t = count(source.text, catalogue.text);
  const total = k.total + t.total;
  return {
    keys: k,
    text: t,
    total,
    done: k.done + t.done,
    same: k.same + t.same,
    open: k.open + t.open,
    percent: total ? (k.done + t.done) / total : 1,
  };
}

// --- commands ----------------------------------------------------------------

function sync() {
  const found = collect();
  const excludes = readExcludes();
  for (const value of excludes.text) found.text.delete(value);
  for (const value of excludes.keys) found.keys.delete(value);

  const all = readAll();
  if (!all.has(SOURCE)) throw new Error(`locale/${SOURCE}.json fehlt — die Quellsprache ist Pflicht.`);
  const source = all.get(SOURCE);

  // `keys` stay hand-written: an identifier discovered in the code without a
  // German text is a gap, and the check should say so rather than fall back to
  // the key itself.
  for (const key of found.keys.keys()) {
    if (!(key in source.keys)) {
      console.warn(`[locale] ${key} wird im Code benutzt, fehlt aber in ${SOURCE}.json (keys)`);
    }
  }
  for (const key of Object.keys(source.keys)) {
    if (!found.keys.has(key)) console.warn(`[locale] ${key} steht in ${SOURCE}.json, wird aber nicht mehr benutzt`);
  }
  // `text` is generated: the code is the truth, the catalogue file the mirror.
  source.text = Object.fromEntries([...found.text.entries()].sort(([a], [b]) => a.localeCompare(b, 'en')));

  if (!existsSync(sourceDir)) mkdirSync(sourceDir, { recursive: true });
  writeFileSync(join(sourceDir, `${SOURCE}.json`), serialise(source));

  for (const code of TARGETS) {
    const catalogue = all.get(code) ?? {
      code,
      name: code,
      native: code,
      note: '',
      numbers: { decimal: '.', group: ',' },
      keys: {},
      text: {},
    };
    let added = 0;
    for (const [key, value] of Object.entries(source.keys)) {
      if (!(key in catalogue.keys)) { catalogue.keys[key] = value; added += 1; }
    }
    for (const [key, value] of Object.entries(source.text)) {
      if (!(key in catalogue.text)) { catalogue.text[key] = value; added += 1; }
    }
    // Keys the source no longer has go: a translation without a call site is
    // dead weight and would otherwise count towards coverage.
    let dropped = 0;
    for (const key of Object.keys(catalogue.keys)) {
      if (!(key in source.keys)) { delete catalogue.keys[key]; dropped += 1; }
    }
    for (const key of Object.keys(catalogue.text)) {
      if (!(key in source.text)) { delete catalogue.text[key]; dropped += 1; }
    }
    writeFileSync(join(sourceDir, `${code}.json`), serialise(catalogue));
    if (added || dropped) console.log(`[locale] ${code}.json: ${added} neu, ${dropped} entfernt`);
  }

  // The mirror carries the catalogues and `identical.json`, and nothing else.
  // `identical.json` goes along on purpose: `Loc` reads it to report a truthful
  // coverage figure, and would otherwise call "Tetris" untranslated. `Loc` skips
  // it as a catalogue by name, so it never becomes a language called
  // "identical".
  if (!existsSync(mirrorDir)) mkdirSync(mirrorDir, { recursive: true });
  for (const name of readdirSync(sourceDir)) {
    if (!CATALOGUE_FILE.test(name) && name !== IDENTICAL_FILE) continue;
    copyFileSync(join(sourceDir, name), join(mirrorDir, name));
  }
  console.log(`[locale] ${SOURCE}.json: ${Object.keys(source.text).length} Quellstrings, `
    + `${Object.keys(source.keys).length} Kennungen`);
  return 0;
}

/**
 * Rewrites `identical.json`: every entry a language still spells like the
 * German goes onto that language's list.
 *
 * Running it is how a translator says "this one stays". Running it *after* a
 * translation shrinks the list, which is what keeps it from becoming a place to
 * hide a sentence nobody got round to — `check` fails in both directions.
 */
function lock() {
  const all = readAll();
  const source = all.get(SOURCE);
  if (!source) {
    console.error(`[locale] locale/${SOURCE}.json fehlt.`);
    return 1;
  }
  const out = {};
  for (const [code, catalogue] of all) {
    if (code === SOURCE) continue;
    const entry = { keys: [], text: [] };
    for (const section of ['keys', 'text']) {
      for (const [key, value] of Object.entries(catalogue[section] ?? {})) {
        if (JSON.stringify(value) === JSON.stringify(source[section][key])) entry[section].push(key);
      }
      entry[section].sort((a, b) => a.localeCompare(b, 'en'));
    }
    out[code] = entry;
    console.log(`[locale] ${code}: ${entry.keys.length} Kennungen und ${entry.text.length} Quellstrings bleiben gleich`);
  }
  writeFileSync(join(sourceDir, IDENTICAL_FILE), `${JSON.stringify({
    _comment: [
      'Je Sprache die Einträge, die absichtlich dem Deutschen entsprechen — Markennamen,',
      'Symbolmuster, geliehene Wörter. „Tetris“ und „‖ Pause“ sind nicht unübersetzt,',
      'sondern richtig so; „Bonbonland“ steht nur bei „fr“, weil es auf Deutsch so heißt.',
      'Gilt, solange niemand etwas übersetzt — danach gehört der Eintrag raus, damit',
      '„check“ wieder die Zahl nennt, die etwas bedeutet.',
    ],
    ...out,
  }, null, 2)}\n`);
  return 0;
}


function list() {
  const all = readAll();
  const source = all.get(SOURCE);
  if (!source) {
    console.error(`[locale] locale/${SOURCE}.json fehlt.`);
    return 1;
  }
  for (const [code, catalogue] of all) {
    if (code === SOURCE) {
      console.log(`${code}  Quelle   ${Object.keys(source.text).length + Object.keys(source.keys).length} Einträge`);
      continue;
    }
    const c = coverage(catalogue, source, identicalSet(all, code));
    console.log(`${code}  ${catalogue.native.padEnd(10)} ${(c.percent * 100).toFixed(1).padStart(5)} %  `
      + `${String(c.done).padStart(4)}/${c.total} übersetzt  ·  ${c.same} gleich  ·  ${c.open} offen`
      + `  (keys ${c.keys.done}/${c.keys.total}, text ${c.text.done}/${c.text.total})`);
  }
  return 0;
}

function check() {
  const problems = [];
  const all = readAll();
  const source = all.get(SOURCE);
  if (!source) {
    console.error(`[locale] locale/${SOURCE}.json fehlt — ohne Quellsprache gibt es nichts zu prüfen.`);
    return 1;
  }
  const found = collect();
  const excludes = readExcludes();
  for (const value of excludes.text) found.text.delete(value);
  for (const value of excludes.keys) found.keys.delete(value);

  // 1. Every identifier used in code needs a German text. Otherwise `Loc.t`
  //    returns the identifier itself — "ui.back_to_lobby" ends up on screen.
  for (const key of found.keys.keys()) {
    if (!(key in source.keys)) problems.push(`Kennung '${key}' wird benutzt, fehlt aber in ${SOURCE}.json (keys)`);
  }
  // 2. The generated `text` half has to match the code. Otherwise the catalogue
  //    is a list of sentences that no longer exist.
  for (const key of found.text.keys()) {
    if (!(key in source.text)) problems.push(`Quellstring fehlt in ${SOURCE}.json: "${key}" — "npm run locale:sync"`);
  }
  for (const key of Object.keys(source.text)) {
    if (!found.text.has(key)) problems.push(`${SOURCE}.json enthält "${key}", das im Code nicht mehr vorkommt — "npm run locale:sync"`);
  }
  // 3. A translation catalogue may only know what the source knows.
  for (const [code, catalogue] of all) {
    if (code === SOURCE) continue;
    for (const key of Object.keys(catalogue.keys)) {
      if (!(key in source.keys)) problems.push(`${code}.json kennt die Kennung '${key}', die es in ${SOURCE}.json nicht gibt`);
      // A plural is an object of forms; it is empty when none of them has text.
      const value = catalogue.keys[key];
      const filled = typeof value === 'string'
        ? value
        : Object.values(value ?? {}).filter((v) => typeof v === 'string' && v !== '').join('');
      if (filled === '') problems.push(`${code}.json: '${key}' ist leer`);
    }
    for (const key of Object.keys(catalogue.text)) {
      if (!(key in source.text)) problems.push(`${code}.json kennt "${key}", was es in ${SOURCE}.json nicht gibt`);
    }
    if (!catalogue.native || catalogue.native === code) {
      problems.push(`${code}.json: 'native' fehlt — die Sprachauswahl zeigt sonst nur "${code}"`);
    }
  }
  // 4. The mirror under godot/assets has to match the repository, or the device
  //    translates a different revision than the one that was reviewed.
  for (const name of [...all.keys().map((c) => `${c}.json`), IDENTICAL_FILE]) {
    const from = join(sourceDir, name);
    const to = join(mirrorDir, name);
    if (!existsSync(from)) continue;
    if (!existsSync(to)) {
      problems.push(`godot/assets/locale/${name} fehlt — "npm run locale:sync"`);
      continue;
    }
    if (readFileSync(from, 'utf8') !== readFileSync(to, 'utf8')) {
      problems.push(`godot/assets/locale/${name} weicht von locale/${name} ab — "npm run locale:sync"`);
    }
  }
  // 5. `identical.json` may only name entries that really are equal, and every
  //    entry that is equal has to be named. The first direction stops somebody
  //    translating "Tetris"; the second stops the list from becoming a hiding
  //    place for a sentence nobody got round to.
  const identical = readIdentical();
  for (const [code, catalogue] of all) {
    if (code === SOURCE) continue;
    const locked = identicalSet(all, code);
    for (const section of ['keys', 'text']) {
      for (const [key, value] of Object.entries(catalogue[section] ?? {})) {
        const same = JSON.stringify(value) === JSON.stringify(source[section][key]);
        if (same && !locked.has(key)) {
          problems.push(`${code}.json: "${key}" ist noch unübersetzt — übersetzen oder "npm run locale:lock"`);
        }
        if (!same && locked.has(key)) {
          problems.push(`${code}.json: '${key}' ist in identical.json (${code}) als gleich geführt, ist aber übersetzt — "npm run locale:lock"`);
        }
      }
    }
  }
  for (const [code, locked] of Object.entries(identical)) {
    if (code.startsWith('_')) continue;                 // `_comment` is prose, not a language
    if (!all.has(code)) problems.push(`identical.json kennt die Sprache '${code}', für die es keinen Katalog gibt`);
    const keys = new Set([
      ...(Array.isArray(locked?.keys) ? locked.keys : []),
      ...(Array.isArray(locked?.text) ? locked.text : []),
    ]);
    for (const key of keys) {
      if (!(key in source.keys) && !(key in source.text)) {
        problems.push(`identical.json nennt '${key}', das es in ${SOURCE}.json nicht gibt`);
      }
    }
  }
  // 6. An identifier passed to `Loc.f` is nearly always a slip for `Loc.t`:
  //    `Loc.f` formats with `%`, an identifier has no placeholders.
  for (const { value, rel } of found.locF) {
    problems.push(`Loc.f("${value}") in ${rel} sieht nach einer Kennung aus — dafür ist Loc.t zuständig`);
  }
  // 7. `Loc.f` counts placeholders and arguments apart, and nothing compares
  //    the two while the file compiles: a `%d` that receives a string is a
  //    runtime error in the middle of a run, not a warning on the build.
  problems.push(...formatMismatchesInProject());
  for (const problem of problems) console.error(`[locale] ${problem}`);
  if (problems.length) {
    console.error(`[locale] ${problems.length} Problem(e).`);
    return 1;
  }
  list();
  return 0;
}

/**
 * Only dispatch when this file is the command, not when a test imports it.
 *
 * `tests/locale.test.ts` imports `collect`, `isDisplayText` and `coverage` from
 * here. Without the guard the import ran the default `check` and called
 * `process.exit` in the middle of the test run, which vitest reports as a failed
 * suite with no tests in it.
 */
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const command = process.argv[2] ?? 'check';
  if (command === 'sync') process.exit(sync());
  else if (command === 'lock') process.exit(lock());
  else if (command === 'list') process.exit(list());
  else if (command === 'check') process.exit(check());
  else {
    console.error(`[locale] unbekannter Befehl '${command}' — list, lock, sync oder check`);
    process.exit(2);
  }
}
