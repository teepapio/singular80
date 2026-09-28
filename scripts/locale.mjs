#!/usr/bin/env node
/**
 * Language catalogues: extraction, merging and the drift check.
 *
 * The game carries two kinds of key in one file. `keys` are hand-written
 * identifiers (`ui.back_to_lobby`) used as `Loc.t("ui.…")`. `text` are the
 * English source strings themselves, so every existing caption gets a
 * translation without rewriting 650 call sites; a missing translation shows
 * the English original, never a key and never an empty line.
 *
 * The `text` half of `en.json` is therefore generated and a run of this script
 * is the source of truth. `de.json` and `fr.json` are hand-written; `sync` tops
 * them up without touching existing translations.
 *
 *   node scripts/locale.mjs list      catalogues and their coverage
 *   node scripts/locale.mjs sync      write en.json, top up the others, mirror
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
/**
 * Languages `sync` brings into being when `locale/` has no catalogue for them.
 *
 * A seed list, not the list of languages: `sync` tops up every catalogue it
 * finds next to `en.json`, so leaving a language out here only means `sync`
 * would not be the run that creates it. Anything that is already on disk is
 * kept in step whether it is named here or not.
 */
const TARGET_SEEDS = ['de', 'fr'];

/**
 * Call sites whose string literal a player reads.
 *
 * `first` means the literal is the first argument — the text itself. With `any`
 * a later position counts too (`notify("…", 3.0)`).
 *
 * A name is matched whole first and by its **last segment** second, because the
 * code writes both forms and the second one used to be invisible: `collect()`
 * compared `s.call === ctx.call`, and `contextOf` hands it `host.set_hint` and
 * `_mode_button.text` — a dotted path where a bare name was expected. So
 * `set_hint("…")` on a receiver, `_mode_button.text = "…"` and
 * `edit.placeholder_text = "…"` were in no catalogue at all, which is worse than
 * a missing translation: nothing was untranslated, nothing was checkable, and
 * `sync` reported a clean run over a hole.
 *
 * The whole-name pass comes first so that a qualified `Loc.f` keeps being a
 * `Loc.f` and not a bare `f` that matches nothing.
 */
const SOURCES = [
  { call: 'Loc.t', first: true, kind: 'key' },
  { call: 'Loc.tn', first: true, kind: 'key' },
  // `Loc.f` carries a source template with `%` placeholders, not an identifier.
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
  // A caption painted straight onto the canvas. `draw_string` is Godot's own
  // and takes the text third; no other argument of it is ever a string literal,
  // so `any` cannot pick up a colour hex by accident.
  { call: 'draw_string', any: true, kind: 'text' },
  { call: 'draw_multiline_string', any: true, kind: 'text' },
];

/**
 * The private methods a screen paints its captions through.
 *
 * `freecell_screen.gd` writes `_text("free", …)`, `poker_screen.gd`
 * `_label(pos, "D", …)`, `dragon_flight_screen.gd` `_banner_text("BOSS", …)`,
 * `pang_screen.gd` `_add_label(pos, "+%d" % points, …)`. The text is the first
 * argument in one and the second in the next, so the position does not
 * identify it; the *name* does, because all of them end in the noun of what they
 * paint. `get_text` and `set_hint` deliberately do not match — they read or set
 * a property rather than paint a caption, and a name that ends in `text` because
 * it fetches one is not evidence of anything.
 */
const CAPTION_HELPER = /^_(?:[a-z0-9]+_)*(?:text|label|caption|badge|title|tip|word)$/;

/**
 * Two more, named rather than guessed.
 *
 * `_value(parent, caption, "0", …)` is the HUD row builder and `_wrap(text, …)`
 * the paragraph wrapper, and both take the player's words as their first
 * argument. Neither name says "caption", so they do not belong in the pattern
 * above — and being listed is the point: a maintainer adding a third such helper
 * adds it here, where the reason is written down, instead of loosening a rule
 * that every other screen also goes through.
 */
const CAPTION_NAMED = new Set(['_value', '_wrap']);

/** Assignments whose right-hand side is visible text. */
const ASSIGNMENTS = [
  { key: 'placeholder_text', kind: 'text' },
  { key: 'tooltip_text', kind: 'text' },
  { key: 'text', kind: 'text' },
  { key: 'title', kind: 'text' },
];

/**
 * Dictionary keys in the data modules: the text most visible in the game and
 * least of it at a call site.
 */
const DICT_KEYS = new Set([
  'name', 'names', 'description', 'desc', 'tagline', 'title', 'label', 'hint', 'reason',
  'text', 'flavour', 'flavor', 'objective', 'summary', 'tip',
]);

/**
 * A constant whose name ends in `_LOC_KEY(S)` holds translation keys and no
 * sentences.
 *
 * `AppLegal.REASON_LOC_KEYS` is such a list: six strings that run through
 * `Loc.t` elsewhere. The suffix is deliberately that long — `asset_registry.gd`
 * has a dozen `const …_KEYS` lists full of asset names, and a short name would
 * have reported `crystal`, `tree` and `pumpkin` as translatable identifiers.
 *
 * The pattern takes every shape the project actually uses, not only the plural
 * `Array[String]` one it was written for:
 *
 *   const REASON_LOC_KEYS: Array[String] = [ … ]      a list
 *   const REPAIR_LOC_KEY := ["…", "…", "…"]           an untyped list
 *   const AXIS_LOC_KEY := { … }                        a lookup
 *   const UNKNOWN_LOC_KEY := "ui.origin.unknown"       a single key
 *
 * A lookup is read from its *values* only. Its keys are the ids it is keyed by —
 * "lobby", "med", "angriff" — and a pattern that took both would file a dozen
 * screen ids as translation identifiers, which is what `AXIS_LOC_KEY` and
 * `SCREEN_LOC_KEY` look like from the outside. Hence the `"…": ` the dict branch
 * insists on: the literal has to sit where a value sits.
 *
 * The names are the signal, and matching all four is what lets the eight
 * hand-duplicated `…_LOC_KEYS` lists that exist only to be seen by this lint
 * retire.
 */
const KEY_ARRAY = /const\s+\w*_LOC_KEYS?\s*(?::\s*Array\[String\]\s*)?\s*(?::)?\s*=\s*(?:\[[^\]]*|\{[^}]*"\s*:\s*)$/;

// --- reading the source ------------------------------------------------------

/**
 * Every `.gd` file under `godot/src`, stably sorted.
 *
 * The walk starts at `godot/src`, so there is nothing to skip: the tests, the
 * exported APK and `node_modules` are all outside it. A skip list here used to
 * be a second thing a maintainer had to keep true, and nothing ever did.
 */
function sourceFiles(dir = join(godotRoot, 'src'), out = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    if (entry.isDirectory()) sourceFiles(join(dir, entry.name), out);
    else if (entry.name.endsWith('.gd')) out.push(join(dir, entry.name));
  }
  return out;
}

/**
 * Splits GDScript roughly into literals and the text in front of them.
 *
 * A real parser would be overkill, but comments have to go: the `##`
 * documentation is almost entirely long-form English prose and would flood the
 * catalogue with thousands of entries nobody ever sees.
 */
function scan(text) {
  const found = [];
  const n = text.length;
  let i = 0;
  let line = 1;                 // counted here, not derived per literal: the walk
  while (i < n) {               // is linear and `lineOf` would make it quadratic
    const ch = text[i];
    if (ch === '\n') {
      line += 1;
      i += 1;
      continue;
    }
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
    const at = line;
    i += 1;
    let value = '';
    let closed = false;
    while (i < n) {
      const c = text[i];
      if (c === '\\') {
        const escape = readEscape(text, i);
        value += escape.value;
        i = escape.next;
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
    if (closed) found.push({ value, before: text.slice(0, start), line: at });
  }
  return found;
}

const HEX = /^[0-9a-fA-F]+$/;

/**
 * The escape starting at `i`, and where the literal continues after it.
 *
 * GDScript writes a character above ASCII as a backslash, a `u` and four hex
 * digits (eight for a `U`), and the extractor has to put that character back:
 * dropping the backslash and the letter, which is what the single-character
 * path did for every escape it did not know, filed the four hex digits under a
 * stripped `u` as a catalogue key. A string no translator can read, and one the
 * runtime can never look up, because the game sends the character and the
 * catalogue answers to the spelling of it.
 */
function readEscape(text, i) {
  const lead = text[i + 1];
  if (lead === 'u' || lead === 'U') {
    const width = lead === 'u' ? 4 : 8;
    const hex = text.slice(i + 2, i + 2 + width);
    if (hex.length === width && HEX.test(hex)) {
      const code = parseInt(hex, 16);
      // GDScript rejects a code point outside the valid range rather than
      // producing a lone surrogate, and so does this.
      if (code <= 0x10ffff) {
        return { value: String.fromCodePoint(code), next: i + 2 + width };
      }
    }
  }
  return { value: unescape(lead), next: i + 2 };
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

/**
 * The name of the function a line belongs to, or `null` outside any.
 *
 * The enclosing function is what says a `return "…"` is player text:
 * `candy_match3.special_name()`, `metro.time_of_day_name()` and
 * `pang.wave_label()` all return a caption a player reads, and none of them says
 * so in a way the call-site patterns can see. A `func` runs until the next one
 * starts or the file leaves column 0, which is how this project is written —
 * `func` at the top level, indented `func` only inside an inner `class`.
 */
const FUNC_LINE = /^(\s*)(?:static\s+)?func\s+([A-Za-z_]\w*)\s*\(/;
const TOP_LEVEL_LINE = /^(?:class\b|class_name\b|const\b|enum\b|signal\b|extends\b|var\b|@)/;

/** Per line of `text`: the innermost function declared before it, or `null`. */
function enclosingFunctions(text) {
  const out = [];
  let current = null;
  for (const line of text.split('\n')) {
    const declared = FUNC_LINE.exec(line);
    if (declared) current = declared[2];
    else if (line !== '' && !/^\s/.test(line) && TOP_LEVEL_LINE.test(line)) current = null;
    out.push(current);
  }
  return out;
}

/**
 * The functions whose `return "…"` is a caption.
 *
 * `_name`, `_label` and `_text` are where a translator looks for the display
 * name of a thing, and that is exactly where the project puts them: every
 * combination in the Candy world, every element of a dragon, the time of day in
 * the Metro, the singular and plural of a wave. The hand-rolled plural in
 * `pang.wave_label()` is the sharpest case — a grammar rule the catalogue has
 * no entry for, so the sentence exists in one language only.
 */
const NAME_FUNCTION = /_(?:label|name|text|title|caption|description|summary|hint)$/;

/**
 * The call a literal sits in, found by walking back over open brackets.
 *
 * `contextOf` only reports a call when the text right in front of the literal
 * happens to look like one, which it does not once an argument is itself a call:
 * in `_add_label(Vector3(x, y, ORB_Z + 0.6), "+%d" % points, Pang.ARM_TINT)`
 * the literal is the second argument of a call that starts two brackets back.
 * The name is the only thing that says which call it was.
 */
function innermostCall(before) {
  let depth = 0;
  for (let i = before.length - 1; i >= 0; i -= 1) {
    const c = before[i];
    if (c === ')' || c === ']' || c === '}') {
      depth += 1;
    } else if (c === '(' || c === '[' || c === '{') {
      if (depth > 0) {
        depth -= 1;
      } else {
        const name = /([A-Za-z_][\w.]*)\s*$/.exec(before.slice(0, i));
        return name ? name[1] : null;
      }
    }
  }
  return null;
}

/** The last segment of a dotted path: `host.set_hint` → `set_hint`. */
function leaf(name) {
  return name ? name.split('.').pop() : null;
}

/**
 * The property a statement assigns to, ignoring its own right-hand side.
 *
 * Only the statement is looked at — from the last line break or `;` — so the `=`
 * inside the condition is not mistaken for the assignment: `_button.text =
 * "Check" if int(legal["callAmount"]) <= 0 else ` names `_button.text`, and
 * reading the whole tail would name nothing at all. A `{` is *not* a boundary
 * here: a dictionary in the condition is more common than a block, and cutting
 * at its brace loses the assignment just as surely.
 */
function statementAssignment(before) {
  const start = Math.max(before.lastIndexOf('\n'), before.lastIndexOf(';')) + 1;
  const assign = /([A-Za-z_][\w.]*)\s*=\s*/.exec(before.slice(start));
  return assign ? assign[1] : null;
}

/** The trimmed context right before a literal: the call that owns it. */
function contextOf(before) {
  let end = before.length;
  let start = end;
  while (start > 0 && !' \t\n'.includes(before[start - 1])) start -= 1;
  const tail = before.slice(start, end);
  // The `else` half of a conditional expression is still the assignment the
  // statement started as: `_button.text = "Check" if cheap else "Call %s" % n`
  // assigns both literals to the same property. Read as a `return` instead, the
  // second one loses the one thing that says what it is for — and the first half
  // of that line, the only half anyone noticed, is enough to make a reader
  // believe the line is covered.
  if (/\belse\s+$/.test(before)) {
    const half = statementAssignment(before);
    if (half) return { prop: half, argIndex: 0 };
  }
  // A `return "…"` is the display name of whatever the function is about, and it
  // is the shape a translator looks for when a name is missing. It is recorded
  // rather than returned, because it does not displace the call patterns:
  // `return Loc.t("ui.points", {…})` is a `Loc.t` site, and `pang_menu_screen.gd`
  // has a line like that. `return "%s wins" % Ui.format_number(n)` has no call
  // in front of the literal at all, and this flag is the only thing that says
  // the sentence is a caption.
  const flag = /\breturn\s+$/.test(before) ? { returned: true } : {};
  // `"name": ` and `.text = ` both end in a separator, not a name. A directly
  // enclosing call wins: `Ui.title(Loc.t("…"))` is a `Loc.t` site even though a
  // `Ui.title(` sits further out.
  const open = /([A-Za-z_][\w.]*)\s*\($/.exec(before);
  if (open) return { call: open[1], argIndex: 0, ...flag };
  // Then a call in which nothing has closed the first argument since the
  // bracket. Without that condition the same expression still matches
  // `Loc.t("ui.x", {` and takes the dictionary key `"mode"` for argument one.
  const first = /([A-Za-z_][\w.]*)\s*\(([^,{}()]*)$/.exec(before);
  if (first) return { call: first[1], argIndex: 0, ...flag };
  const afterComma = /,\s*$/.test(before);
  const later = /([A-Za-z_][\w.]*)\s*\(([^()]*)$/.exec(before);
  if (later && afterComma) return { call: later[1], argIndex: 1, ...flag };
  const assign = /([A-Za-z_][\w.]*)\s*=\s*$/.exec(before);
  if (assign) return { prop: assign[1], argIndex: 0, ...flag };
  const dictKey = /"([\w]+)"\s*:\s*$/.exec(before);
  if (dictKey) return { dictKey: dictKey[1], argIndex: 0, ...flag };
  return { argIndex: afterComma ? 1 : -1, tail, ...flag };
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
  // One lowercase word with nothing in it that says "identifier": the gene table
  // in the hatchery says "recessive" and "dominant", a pedigree says "carrier", a
  // gene state says "shows", a FreeCell slot says "free". A rule that dropped
  // every lowercase token dropped those five sentences along with the ids, and
  // the ids it was written for are the ones with a *shape* — `candy/bonbon`,
  // `ui.origin.unknown`, `low-poly`, `free_cells`, `crystal1`. A bare word has
  // none of them, so it is a caption and stays.
  if (/^[a-z][\w.:/-]*$/.test(value)) {
    if (/[._:/-]/.test(value)) return false;                 // a path, a key, a slug
    if (/[a-z]\d/.test(value)) return false;                 // `crystal1`, `level2`
    return true;
  }
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
    const body = readFileSync(file, 'utf8');
    const functions = enclosingFunctions(body);
    for (const { value, before, line } of scan(body)) {
      const ctx = contextOf(before);
      // The call the literal sits in, whole or by its last segment. `contextOf`
      // reports the call it can see; `innermostCall` reports the one it cannot,
      // which is the caption helper whose first argument is itself a call.
      const call = ctx.call ?? innermostCall(before);
      const name = leaf(call);
      let kind = null;
      const site = SOURCES.find((s) => s.call === call
        && (s.first ? ctx.argIndex === 0 : true))
        ?? (name === null ? undefined : SOURCES.find((s) => s.call === name
          && (s.first ? ctx.argIndex === 0 : true)));
      if (site) kind = site.kind;
      else if (ctx.prop && ASSIGNMENTS.some((a) => a.key === leaf(ctx.prop))) kind = 'text';
      else if (name && (CAPTION_NAMED.has(name) || CAPTION_HELPER.test(name))) kind = 'text';
      else if (ctx.dictKey && DICT_KEYS.has(ctx.dictKey)) kind = 'text';
      // A `return "…"` only counts inside a function named after what it
      // returns: `element_name`, `wave_label`, `mode_hint`. Any other `return` is
      // arithmetic or a lookup, and its literal is a value, not a caption.
      else if (ctx.returned && NAME_FUNCTION.test(functions[line - 1] ?? '')) kind = 'text';
      else if (KEY_ARRAY.test(before.slice(-400))) kind = 'key';
      if (!kind) continue;
      if (!isDisplayText(value, kind)) continue;
      // The catalogue maps each entry to *itself*: the source sentence is both
      // the key and, in `en.json`, the value. Mapping to the file it was found
      // in produced catalogues whose values were paths, and the game then showed
      // `src/game/siedler/siedler_screen.gd` instead of a sentence. The key is
      // the search term; `grep` finds the call site.
      if (kind === 'key') keys.set(value, value);
      else {
        text.set(value, value);
        if (call === 'Loc.f' && /^[a-z][\w]*(\.[\w]+)+$/.test(value)) locF.push({ value, rel });
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
// Both sets mirror `Loc._specifier_letters` exactly. If they disagree, a
// template the runtime accepts is one `check` calls incompatible with its own
// arguments — or the other way round, which is worse: `check` stays quiet about
// a translation the runtime then drops on the floor, in the language the player
// just chose.
//
// `$` is a flag because it is positional (`%1$s`), and without it the walk stops
// on the `$` and reports zero placeholders for a template that has one. A space
// is deliberately not a flag: `+12 % fire rate` is a percent sign in a sentence.
const SPECIFIER_FLAGS = '-+#0123456789.*$';
const SPECIFIER_CONVERSIONS = 'sdfxXoiegcbu';
/** Templates are quoted in full in a problem message until they get silly. */
const LONG_TEMPLATE = 60;

/**
 * The conversion letters of a template's `%` placeholders, in order — `%%` is
 * not one. `"Points: %s   ·   Best: %d"` yields `['s', 'd']`.
 *
 * Letters, not a count, because a count cannot tell `%s` from `%d`: a
 * translation that swaps one for the other passes on cardinality and then hands
 * a formatted score — `Ui.format_number` returns a String — to a `%d`, which
 * Godot renders as a bare `0`. `Loc._signature` compares the same sequence, and
 * this is its counterpart.
 */
function specifierLetters(text) {
  const letters = [];
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
    if (j < text.length && SPECIFIER_CONVERSIONS.includes(text[j])) letters.push(text[j]);
    i = j + 1;
  }
  return letters;
}

/** How many `%` placeholders a template has. Kept for the call sites that count. */
function countSpecifiers(text) {
  return specifierLetters(text).length;
}

/**
 * The `{name}` placeholders of a text, sorted, the way `Loc._placeholders` does.
 *
 * A `keys` entry is filled from named arguments and a `text` entry is formatted
 * with `%`, so the two grammars never mix: counting `%` in a `{name}` sentence
 * finds nothing and accepts everything. The section is the only thing that says
 * which of the two a key is, which is why this is a parameter and not a second
 * pass.
 */
function bracePlaceholders(text) {
  return [...text.matchAll(/\{[a-z_][a-z0-9_]*\}/g)].map((m) => m[0]).sort();
}

/** What a text has to keep intact to be substitutable, as one comparable string. */
function signature(text, named) {
  return (named ? bracePlaceholders(text) : specifierLetters(text)).join(',');
}

/**
 * What one translation entry gets wrong about its placeholders.
 *
 * A plural is an object of forms, and the source decides: a form the source does
 * not have is a form nobody asked for, a form the translation is missing is a
 * half-finished entry that renders as "3 ", and either of them makes `Loc` drop
 * the whole entry at load time. So the forms are compared one by one, and the
 * count has to match on top — the runtime walks `forms`, the lint reads the file.
 */
function placeholderProblems(code, section, key, value, want, named) {
  const problems = [];
  const label = section === 'keys' ? `'${key}'` : `"${key}"`;
  if (want === undefined) return problems;                 // reported elsewhere
  if (value && typeof value === 'object' && want && typeof want === 'object') {
    for (const form of Object.keys(want)) {
      if (!(form in value)) {
        problems.push(`${code}.json ${section} ${label}: die Form '${form}' der Quelle fehlt`);
        continue;
      }
      const got = signature(String(value[form]), named);
      if (got !== signature(String(want[form]), named)) {
        problems.push(`${code}.json ${section} ${label}/${form}: andere Platzhalter als die Quelle `
          + `(erwartet ${quoteSignature(want[form], named)}, gefunden ${quoteSignature(value[form], named)})`);
      }
    }
    for (const form of Object.keys(value)) {
      if (!(form in want)) {
        problems.push(`${code}.json ${section} ${label}: die Form '${form}' gibt es in ${SOURCE}.json nicht`);
      }
    }
    return problems;
  }
  if (value && typeof value === 'object') {
    problems.push(`${code}.json ${section} ${label}: ist ein Plural, die Quelle ist ein einzelner Text`);
    return problems;
  }
  if (want && typeof want === 'object') {
    problems.push(`${code}.json ${section} ${label}: ist ein einzelner Text, die Quelle ist ein Plural`);
    return problems;
  }
  if (typeof value !== 'string') return problems;
  const got = signature(value, named);
  if (got !== signature(String(want), named)) {
    problems.push(`${code}.json ${section} ${label}: andere Platzhalter als die Quelle `
      + `(erwartet ${quoteSignature(want, named)}, gefunden ${quoteSignature(value, named)})`);
  }
  return problems;
}

function quoteSignature(value, named) {
  const one = (text) => signature(String(text), named) || '(keine)';
  if (value && typeof value === 'object') {
    return Object.entries(value).map(([form, text]) => `${form}: ${one(text)}`).join(' | ');
  }
  return one(value);
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
 * Per language: the entries that stay equal to the English source on purpose.
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

/**
 * The entries a maintainer has consciously judged to stay equal.
 *
 * `looksLikeUntranslatedSentence` is a heuristic, and a heuristic needs a way to
 * be wrong on purpose: a level-set name that reads like a sentence, a title of
 * thirty characters nobody translates. Such an entry goes into `_allow`, which is
 * a decision with a name on it — unlike an entry that drifted onto the list
 * because `lock` ran right after `sync`. `lock` carries the list over instead of
 * rewriting it, so a judgement survives a regeneration.
 */
function allowedSet(all, code) {
  const entry = readIdentical()[code] ?? {};
  if (typeof entry !== 'object' || entry === null) return new Set();
  return new Set(Array.isArray(entry._allow) ? entry._allow : []);
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
    // A translation is one that differs from the English source; an entry filled
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

  // `keys` stay hand-written: an identifier discovered in the code without an
  // English text is a gap, and the check should say so rather than fall back to
  // the key itself.
  for (const key of found.keys.keys()) {
    if (!(key in source.keys)) {
      console.warn(`[locale] ${key} wird im Code benutzt, fehlt aber in ${SOURCE}.json (keys)`);
    }
  }
  // `text` is generated: the code is the truth, the catalogue file the mirror.
  source.text = Object.fromEntries([...found.text.entries()].sort(([a], [b]) => a.localeCompare(b, 'en')));

  if (!existsSync(sourceDir)) mkdirSync(sourceDir, { recursive: true });
  writeFileSync(join(sourceDir, `${SOURCE}.json`), serialise(source));

  // Every catalogue next to the source, plus the ones named in the seed list and
  // not on disk yet. A language that is dropped from the seed list keeps being
  // kept in step; it simply stops being the language `sync` brings into being.
  for (const code of new Set([...all.keys(), ...TARGET_SEEDS])) {
    if (code === SOURCE) continue;
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
 * An entry that is only allowed on `identical.json` if it really is a name.
 *
 * `sync` seeds a new `de`/`fr` entry with the *English* value, because there is
 * nothing else to put there yet. Run `lock` right after and that seed is equal to
 * the source by construction — so the sentence is filed as "equal on purpose",
 * `coverage` leaves it out of the denominator, and the report says 100 % for a
 * catalogue nobody translated. The failure is silent and the number is green.
 *
 * Length alone is not the test, because a label of twenty-five characters is a
 * label: "Regeneration  %s/s → %s/s" and "Stone %d · Coal %d · Iron %d" are
 * patterns and pattern-like lines, and equality is the right answer for them in
 * every language. What separates them from a sentence is a sentence: six or more
 * words, or a full stop. "Tetris", "‖ Pause" and "%d · %s" stay unremarkable, and
 * "Goods are waiting for a carrier at the banner (%d, %d). …" does not.
 */
const IDENTICAL_SENTENCE_MIN = 24;
const SENTENCE_WORDS = 6;
/** What a sentence ends with, and what a caption rarely does. */
const SENTENCE_END = /[.!?…]$/;

/**
 * Whether an equal-to-the-source entry reads like a sentence nobody translated.
 *
 * A plural is checked form by form, because a language may have forms the source
 * has not — the value is an object then, and `str()` of it is `[object Object]`.
 */
function looksLikeUntranslatedSentence(value) {
  const forms = value && typeof value === 'object' ? Object.values(value) : [value];
  return forms.some((form) => {
    if (typeof form !== 'string') return false;
    const one = form.trim();
    if (one.length <= IDENTICAL_SENTENCE_MIN) return false;
    if (!ANY_LETTER.test(one)) return false;                 // a pure pattern
    // A word is a run of letters, so `%d`, `·` and `(…)` do not inflate the
    // count — the conversion letter is a letter too, and "Stone %d · Coal %d ·
    // Iron %d" is three words, not six. Placeholders go before the count, not
    // after it.
    const spoken = one
      .replace(/%[-+ #0-9.]*[sdfxXoiegcbu]/g, ' ')
      .replace(/\{[a-z_][a-z0-9_]*\}/g, ' ');
    const words = spoken.match(/[\p{L}]+/gu) ?? [];
    return words.length >= SENTENCE_WORDS || SENTENCE_END.test(one);
  });
}

/**
 * Rewrites `identical.json`: every entry a language still spells like the
 * English source goes onto that language's list.
 *
 * Running it is how a translator says "this one stays". Running it *after* a
 * translation shrinks the list, which is what keeps it from becoming a place to
 * hide a sentence nobody got round to — `check` fails in both directions.
 *
 * It refuses to write at all when a language has an entry that is equal to the
 * source and reads like a sentence, unless the entry is in that language's
 * `_allow`. That is the `sync`-then-`lock` accident above: the list must not be
 * able to absorb a fresh seed, because a list entry is a decision and a seed is
 * an accident — and a heuristic that can never be wrong is a heuristic that will
 * be worked around.
 */
function lock() {
  const all = readAll();
  const source = all.get(SOURCE);
  if (!source) {
    console.error(`[locale] locale/${SOURCE}.json fehlt.`);
    return 1;
  }
  const out = {};
  const refused = [];
  for (const [code, catalogue] of all) {
    if (code === SOURCE) continue;
    const allowed = allowedSet(all, code);
    const entry = { keys: [], text: [] };
    for (const section of ['keys', 'text']) {
      for (const [key, value] of Object.entries(catalogue[section] ?? {})) {
        if (JSON.stringify(value) !== JSON.stringify(source[section][key])) continue;
        if (looksLikeUntranslatedSentence(value) && !allowed.has(key)) {
          refused.push(`${code}.json ${section} "${key}"`);
          continue;
        }
        entry[section].push(key);
      }
      entry[section].sort((a, b) => a.localeCompare(b, 'en'));
    }
    // A judgement survives a regeneration: `lock` rewrites the lists, not the
    // decision somebody made about them.
    if (allowed.size) entry._allow = [...allowed].sort((a, b) => a.localeCompare(b, 'en'));
    out[code] = entry;
    console.log(`[locale] ${code}: ${entry.keys.length} Kennungen und ${entry.text.length} Quellstrings bleiben gleich`);
  }
  if (refused.length) {
    console.error('[locale] identical.json wird nicht geschrieben. Diese Einträge stehen');
    console.error('[locale] unverändert in der Quelle und lesen sich wie ein übersetzbarer Satz:');
    for (const line of refused) console.error(`[locale]   ${line}`);
    console.error('[locale] Ein frisch aufgesetzter Eintrag aus „sync“ sieht genau so aus.');
    console.error('[locale] Übersetze ihn. Ist es wirklich ein Name, den man so lässt,');
    console.error('[locale] trag ihn in „_allow“ der Sprache ein — das ist eine Entscheidung');
    console.error('[locale] mit Namen, ein aufgelaufener Eintrag ist es nicht.');
    return 1;
  }
  writeFileSync(join(sourceDir, IDENTICAL_FILE), `${JSON.stringify({
    _comment: [
      'Je Sprache die Einträge, die absichtlich der englischen Quelle entsprechen —',
      'Markennamen, Symbolmuster, geliehene Wörter. „Tetris“ und „‖ Pause“ sind nicht',
      'unübersetzt, sondern richtig so; „Bonbonland“ steht nur bei „fr“, weil es auf',
      'Deutsch so heißt. Gilt, solange niemand etwas übersetzt — danach gehört der',
      'Eintrag raus, damit „check“ wieder die Zahl nennt, die etwas bedeutet.',
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

  // 1. Every identifier used in code needs an English text. Otherwise `Loc.t`
  //    returns the identifier itself — "ui.back_to_lobby" ends up on screen.
  for (const key of found.keys.keys()) {
    if (!(key in source.keys)) problems.push(`Kennung '${key}' wird benutzt, fehlt aber in ${SOURCE}.json (keys)`);
  }
  //    …and an identifier in the catalogue that the code no longer uses is the
  //    other half of the same drift: `sync` only ever printed a warning for it,
  //    so `ui.settings_short` could sit in three catalogues and in no call site,
  //    and a reader would take it for one the game needs. It is a dead entry
  //    that a translator spends time on.
  for (const key of Object.keys(source.keys)) {
    if (!found.keys.has(key)) problems.push(`Kennung '${key}' steht in ${SOURCE}.json, wird aber im Code nicht mehr benutzt — Aufrufstelle wiederherstellen oder den Eintrag entfernen`);
  }
  // 2. The generated `text` half has to match the code. Otherwise the catalogue
  //    is a list of sentences that no longer exist.
  for (const key of found.text.keys()) {
    if (!(key in source.text)) problems.push(`Quellstring fehlt in ${SOURCE}.json: "${key}" — "npm run locale:sync"`);
  }
  for (const key of Object.keys(source.text)) {
    if (!found.text.has(key)) problems.push(`${SOURCE}.json enthält "${key}", das im Code nicht mehr vorkommt — "npm run locale:sync"`);
  }
  // 3. A translation catalogue may only know what the source knows, and what it
  //    fills in has to stay substitutable.
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
    // 3a. The placeholders, both sections, every plural form.
    //
    // `Loc` checks this too, at load time, and its answer is to *drop* the entry
    // and warn — so a translation that lost a `%s` or invented a `{name}` reaches
    // the player as the English sentence, in the language they did not choose,
    // with one line in a log nobody opens. A count is not enough: `%s` and `%d`
    // both take one argument, and swapping one for the other hands a formatted
    // score to a `%d`, which reads "0".
    for (const [section, named] of [['text', false], ['keys', true]]) {
      for (const [key, value] of Object.entries(catalogue[section] ?? {})) {
        problems.push(...placeholderProblems(code, section, key, value, source[section][key], named));
      }
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
  //
  //    And an entry that is equal *and* reads like a sentence is reported even
  //    when it is on the list, because that combination is the `sync`-then-`lock`
  //    accident: a fresh entry is seeded with the English value, `lock` files it
  //    as equal on purpose, and the coverage figure reports a language nobody
  //    translated as complete. The list may hold names, symbols and loanwords;
  //    it may not hold a sentence, and a sentence is six words or a full stop.
  //    `_allow` is the way to say "this one is a name after all" out loud.
  const identical = readIdentical();
  for (const [code, catalogue] of all) {
    if (code === SOURCE) continue;
    const locked = identicalSet(all, code);
    const allowed = allowedSet(all, code);
    for (const section of ['keys', 'text']) {
      for (const [key, value] of Object.entries(catalogue[section] ?? {})) {
        const same = JSON.stringify(value) === JSON.stringify(source[section][key]);
        if (same && !locked.has(key)) {
          problems.push(`${code}.json: "${key}" ist noch unübersetzt — übersetzen oder "npm run locale:lock"`);
        }
        if (!same && locked.has(key)) {
          problems.push(`${code}.json: '${key}' ist in identical.json (${code}) als gleich geführt, ist aber übersetzt — "npm run locale:lock"`);
        }
        if (same && !allowed.has(key) && looksLikeUntranslatedSentence(value)) {
          problems.push(`${code}.json ${section}: "${key}" steht unverändert in der Quelle und liest sich wie ein `
            + 'Satz. Übersetzen, oder — ist es wirklich ein Name? — in "_allow" der Sprache eintragen.');
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
    // An `_allow` entry that is gone, or that has been translated after all, is a
    // decision about a thing that no longer exists. Left in the file it reads as
    // permission, and the next `lock` carries it forward for good.
    for (const key of Array.isArray(locked?._allow) ? locked._allow : []) {
      const section = key in source.keys ? 'keys' : key in source.text ? 'text' : null;
      if (!section) {
        problems.push(`identical.json erlaubt '${key}' für ${code}, das es in ${SOURCE}.json nicht gibt`);
        continue;
      }
      const value = all.get(code)?.[section]?.[key];
      if (value === undefined || JSON.stringify(value) !== JSON.stringify(source[section][key])) {
        problems.push(`identical.json erlaubt '${key}' für ${code}, aber der Eintrag ist inzwischen übersetzt oder fehlt`);
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
