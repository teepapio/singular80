import { describe, it, expect } from 'vitest';
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { isDisplayText, collect, readAll, coverage, SOURCE } from '../scripts/locale.mjs';

/**
 * Tests for the language catalogues and the script that maintains them.
 *
 * The GDScript suite proves the *runtime* behaves — resolution, plurals, number
 * separators. This one guards the *data* and the *filter*, which rot quietly:
 * a catalogue that is one commit out of date, a translation that lost a
 * placeholder, or a filter change that starts filing asset ids as sentences.
 * Both halves of that fail on a green `npm run test:game`.
 */
const root = join(import.meta.dirname, '..');
const read = (p: string) => JSON.parse(readFileSync(join(root, p), 'utf8'));
const all = readAll();
const source = all.get(SOURCE)!;

/** The entries `identical.json` says stay the same in every language. */
function identicalKeys(): Set<string> {
  const file = join(root, 'locale', 'identical.json');
  if (!existsSync(file)) return new Set();
  const parsed = JSON.parse(readFileSync(file, 'utf8'));
  return new Set([...(parsed.keys ?? []), ...(parsed.text ?? [])]);
}

/** `%` placeholders, the way GDScript counts them. */
function specifiers(text: string): number {
  const pattern = /%[-+#0-9.]*[sdfxXo]/g;
  return (text.match(pattern) ?? []).length;
}

/** `{name}` placeholders. */
function placeholders(text: string): string[] {
  return (text.match(/\{[a-z_][a-z0-9_]*\}/g) ?? []).sort();
}

describe('Kataloge', () => {
  it('gibt es die Quellsprache und mindestens eine Übersetzung', () => {
    expect(all.has(SOURCE)).toBe(true);
    const targets = [...all.keys()].filter((c) => c !== SOURCE);
    expect(targets.length).toBeGreaterThanOrEqual(1);
  });

  it('nennt jede Sprache in sich selbst', () => {
    for (const [code, catalogue] of all) {
      expect(catalogue.native, `${code} braucht einen eigenen Namen`).toBeTruthy();
      expect(catalogue.native).not.toBe(code);
    }
  });

  it('kennt in den Übersetzungen nichts, was die Quelle nicht hat', () => {
    for (const [code, catalogue] of all) {
      if (code === SOURCE) continue;
      for (const key of Object.keys(catalogue.keys)) {
        expect(Object.hasOwn(source.keys, key), `${code}.json: Kennung '${key}'`).toBe(true);
      }
      for (const key of Object.keys(catalogue.text)) {
        expect(Object.hasOwn(source.text, key), `${code}.json: "${key}"`).toBe(true);
      }
    }
  });

  it('verliert in keiner Übersetzung einen Platzhalter', () => {
    // The one that bites in production: `String % Array` throws when the counts
    // disagree, and a `{name}` with no argument is a hole in the sentence.
    for (const [code, catalogue] of all) {
      if (code === SOURCE) continue;
      for (const [key, value] of Object.entries(catalogue.text)) {
        expect(specifiers(String(value)), `${code}: "${key}" %-Angaben`)
          .toBe(specifiers(String(source.text[key])));
      }
      for (const [key, value] of Object.entries(catalogue.keys)) {
        if (typeof value !== 'string') continue;
        expect(placeholders(value), `${code}: '${key}' {platzhalter}`)
          .toEqual(placeholders(String(source.keys[key])));
      }
    }
  });

  it('ist in jeder Sprache übersetzt, was übersetzbar ist', () => {
    const identical = identicalKeys();
    for (const [code, catalogue] of all) {
      if (code === SOURCE) continue;
      const c = coverage(catalogue, source, identical);
      expect(c.open, `${code} hat ${c.open} offene Einträge`).toBe(0);
      expect(c.percent).toBeGreaterThanOrEqual(0.999);
    }
  });

  it('führt genau die als gleich markierten Einträge als offen', () => {
    // The list exists to say "this is equal on purpose", so it has to name every
    // entry that is equal in *every* language — otherwise the number is a
    // complaint about the one thing that is right — and nothing that is
    // actually translated somewhere, or "Tetris" could be localised by accident.
    //
    // Equal in only *one* language is not on the list: that one is genuinely
    // untranslated, and the coverage report has to keep saying so.
    const identical = identicalKeys();
    const targets = [...all.keys()].filter((c) => c !== SOURCE);
    for (const section of ['keys', 'text'] as const) {
      for (const key of Object.keys(source[section])) {
        const everywhere = targets.every((code) => JSON.stringify(all.get(code)![section][key])
          === JSON.stringify(source[section][key]));
        expect(identical.has(key), `'${key}' ist überall gleich, steht aber nicht in identical.json`)
          .toBe(everywhere);
        for (const code of targets) {
          const same = JSON.stringify(all.get(code)![section][key]) === JSON.stringify(source[section][key]);
          if (same && !everywhere) {
            // Flagged by the coverage report instead, which is the point.
            expect(identical.has(key)).toBe(false);
          }
        }
      }
    }
  });

  it('spiegelt unverändert nach godot/assets/locale', () => {
    // The device translates whatever sits under `res://assets/locale`. A
    // catalogue that only exists in the repository is a catalogue no player
    // ever sees, and no Godot test would notice.
    for (const code of all.keys()) {
      const name = `${code}.json`;
      expect(existsSync(join(root, 'godot/assets/locale', name)), `godot/assets/locale/${name}`).toBe(true);
      expect(readFileSync(join(root, 'godot/assets/locale', name), 'utf8'))
        .toBe(readFileSync(join(root, 'locale', name), 'utf8'));
    }
  });

  it('spiegelt keine Werkzeugdatei als Sprache', () => {
    // `identical.json` lives in `locale/` for the script, not for the game. If
    // it reached `res://assets/locale`, `Loc` would offer a language called
    // "identical".
    expect(existsSync(join(root, 'godot/assets/locale', 'exclude.json'))).toBe(false);
    expect(all.has('identical')).toBe(false);
  });
});

describe('Erkennung sichtbarer Texte', () => {
  it('nimmt Sätze und Beschriftungen', () => {
    for (const value of ['Vorschlag', '◀ Lobby', 'Welt %d zuerst', '… und %d weitere Strecken.']) {
      expect(isDisplayText(value, 'text'), value).toBe(true);
    }
  });

  it('behält einen Musterstring mit Inhalt dazwischen', () => {
    // The counterpart to the list below, and the reason the filter is not simply
    // „anything with a % is a pattern": `·` is a character, so the line has
    // content between the two placeholders and is a caption, not an empty shell.
    expect(isDisplayText('%d · %s', 'text')).toBe(true);
  });

  it('lässt Ids, Pfade, Zahlen und Symbole liegen', () => {
    for (const value of [
      'res://assets/meshes/crystal.glb', 'user://singular80.cfg', 'crystal', 'rpg/axe',
      '2048', '1.234', '#facc15', '◉', '☄', '♠', '⚙', '⚑', '↑', '%s', '%d',
      // …but a separator between two placeholders is content, not a pattern
      // with nothing in it: „%d · %s" is a line in a summary.
    ]) {
      expect(isDisplayText(value, 'text'), value).toBe(false);
    }
  });

  it('erkennt eine Kennung als Kennung, auch wenn sie wie ein Id aussieht', () => {
    // The regression this guards: the id filter runs first and would otherwise
    // swallow every `ui.…` before the key check ever saw it.
    expect(isDisplayText('ui.back_to_lobby', 'key')).toBe(true);
    expect(isDisplayText('ui.back_to_lobby', 'text')).toBe(false);
  });
});

describe('Ableitung aus dem Code', () => {
  const found = collect();

  it('findet die Kennungen, die der Code benutzt', () => {
    for (const key of ['ui.close', 'ui.settings', 'ui.suggest_title', 'legal.reason.insult']) {
      expect(found.keys.has(key), key).toBe(true);
    }
  });

  it('findet deutschen Quelltext an beiden Sorten von Aufrufstelle', () => {
    // One from each kind of place: a `Ui.title` argument, a `Loc.t` key that is
    // also a German sentence, a `name` in a data table, a `Loc.f` template.
    for (const value of ['Vorschlag einreichen', '◀ Lobby', 'Brettspiele', 'Axt', '%s   ·   %s Dreiecke']) {
      expect(found.text.has(value), value).toBe(true);
    }
  });

  it('findet keinen Wörterbuchschlüssel als Satz', () => {
    // `AppLegal.REASON_LOC_KEYS` sits in an array, not in a `Loc.t` call. The
    // `_LOC_KEYS` rule is what notices it, and a short `_KEYS` suffix would have
    // pulled in the asset lists of `asset_registry.gd` instead.
    expect(found.keys.has('crystal')).toBe(false);
    expect(found.text.has('mode')).toBe(false);
  });

  it('meldet keine Vorlage, die eine Kennung sein will', () => {
    // `Loc.f` formats with `%`; a key has no placeholders. A hit here means
    // somebody reached for `Loc.f` where `Loc.t` was meant.
    expect(found.locF.map((e) => e.value)).toEqual([]);
  });

  it('deckt den Quelltext aus dem Katalog vollständig ab', () => {
    for (const key of Object.keys(source.text)) {
      expect(found.text.has(key), `"${key}" steht im Katalog, kommt aber im Code nicht vor`).toBe(true);
    }
  });
});
