import { describe, it, expect } from 'vitest';
import { readFileSync, existsSync } from 'node:fs';
import type { LocaleCatalogue } from '../scripts/locale.mjs';
import { join } from 'node:path';
import {
  isDisplayText, collect, readAll, coverage, identicalSet, SOURCE,
  formatMismatches, formatMismatchesInProject,
} from '../scripts/locale.mjs';

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

/** The entries `identical.json` says one language keeps equal on purpose. */
function identicalFor(code: string): Set<string> {
  return identicalSet(readAll(), code);
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
    // Per language, because "honest" is a property of one language: "Bonbonland"
    // is the French name of the Candy world, so only the English catalogue is
    // asked to translate it.
    for (const [code, catalogue] of all) {
      if (code === SOURCE) continue;
      const c = coverage(catalogue, source, identicalFor(code));
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
    for (const [code, catalogue] of all) {
      if (code === SOURCE) continue;
      const locked = identicalFor(code);
      for (const section of ['keys', 'text'] as const) {
        for (const [key, value] of Object.entries(catalogue[section])) {
          const same = JSON.stringify(value) === JSON.stringify(source[section][key]);
          expect(locked.has(key), `${code}: "${key}" ist gleich — steht aber nicht in identical.json (${code})`)
            .toBe(same);
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
      'res://assets/meshes/crystal.glb', 'user://singular80.cfg', 'rpg/axe', 'crystal1',
      'free_cells', '2048', '1.234', '#facc15', '◉', '☄', '♠', '⚙', '⚑', '↑', '%s', '%d',
      // …but a separator between two placeholders is content, not a pattern
      // with nothing in it: „%d · %s" is a line in a summary.
    ]) {
      expect(isDisplayText(value, 'text'), value).toBe(false);
    }
  });

  it('hält einen nackten Kleinbuchstaben füranzeigbaren Text, einen Id nicht', () => {
    // The rule changed on purpose. A bare lowercase word used to be dropped,
    // which threw away real captions — „recessive", „dominant", „carrier",
    // „shows" in the hatchery are all one word. An id is still an id because it
    // carries `_`, `.`, `/`, `-` or a digit; `crystal` on its own is a word, and
    // the mesh key that reaches it never gets past the id filter upstream.
    for (const value of ['recessive', 'dominant', 'carrier', 'shows', 'Gold', 'low', 'crystal']) {
      expect(isDisplayText(value, 'text'), value).toBe(true);
    }
    // The extractor must still not leak asset keys, so the id shapes are pinned
    // separately even though a bare word is now kept.
    for (const value of ['rpg/axe', 'free_cells', 'crystal1']) {
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
    // also a sentence, a `name` in a data table, a `Loc.f` template, a value out
    // of `content/*.json`. English, because the source language is the language
    // of the code.
    for (const value of [
      'Submit a suggestion', '◀ Lobby', 'Board games', 'Axe', '%s   ·   %s triangles', 'Railgun',
    ]) {
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
    expect(found.locF.map((entry) => entry.value)).toEqual([]);
  });

  it('deckt den Quelltext aus dem Katalog vollständig ab', () => {
    for (const key of Object.keys(source.text)) {
      expect(found.text.has(key), `"${key}" steht im Katalog, kommt aber im Code nicht vor`).toBe(true);
    }
  });
});

describe('Vorlagen-Lint', () => {
  // The failure this guards has no compile-time symptom: `"TEMP" % n if n > 0`
  // let `%` bind tighter than the conditional, and moving the `%` into the
  // argument list handed a string to a `%d`. Godot only answers that at
  // runtime, as a log line nobody reads before the run.
  it('findet im Spielcode keinen Streit zwischen Platzhaltern und Werten', () => {
    expect(formatMismatchesInProject()).toEqual([]);
  });

  it('meldet einen Platzhalter, dem mehr Werte übergeben werden', () => {
    const problems = formatMismatches('var s := Loc.f("Best: %s", [a, b])\n', 'probe.gd');
    expect(problems).toHaveLength(1);
    expect(problems[0]).toContain('Loc.f("Best: %s") in probe.gd:1');
    expect(problems[0]).toContain('hat 1 Platzhalter, bekommt aber 2 Werte');
  });

  it('meldet Werte, für die es keinen Platzhalter gibt', () => {
    const problems = formatMismatches('var s := Loc.f("%d/%d", [n])\n', 'probe.gd');
    expect(problems).toHaveLength(1);
    expect(problems[0]).toContain('hat 2 Platzhaltern, bekommt aber 1 Wert');
  });

  it('lässt eine reine Zusammensetzung in Ruhe', () => {
    // `"%s  %s"` is a pattern and not a sentence, so the catalogue leaves it
    // untranslated on purpose. Two values for two placeholders is exactly
    // right and must not be the thing this lint complains about.
    expect(formatMismatches('notify(Loc.f("%s  %s", [glyph, text]), 2.4)\n', 'probe.gd')).toEqual([]);
  });

  it('zählt %% als escapes Prozentzeichen, nicht als Platzhalter', () => {
    // `+%d%% Tempo` has one placeholder and one value; the `%%` is a written
    // percent sign and would make a naive counter ask for a second value.
    expect(formatMismatches('Loc.f("+%d%% Tempo", [speed])\nLoc.f("Rückstoß %s%%", [damp])\n', 'probe.gd'))
      .toEqual([]);
  });

  it('hält ein Prozentzeichen mit Leerzeichen für Prosa', () => {
    // `printf` would read `% F` as a conversion; this catalogue does not, and
    // `+12 % Feuerrate` is a sentence. A value the template cannot use is
    // still a mistake — here with no value, there is nothing to report.
    expect(formatMismatches('Loc.f("+12 % Feuerrate", [])\n', 'probe.gd')).toEqual([]);
    expect(formatMismatches('Loc.f("+12 % Feuerrate", [rate])\n', 'probe.gd')).toHaveLength(1);
  });

  it('übergeht eine Liste mit einem if auf oberster Ebene', () => {
    // The conditional may hand a different shape per branch, and which branch
    // runs is not a question this lint can answer.
    expect(formatMismatches('var s := Loc.f("Ziel geschafft! %s", [note if done else fallback])\n', 'probe.gd'))
      .toEqual([]);
  });

  it('ist an genau dieser Stelle blind — die echte Migration sah so aus', () => {
    // The blind spot, written down so it is a decision and not a surprise.
    // The migration once wrote this shape into `hangar_screen.gd`, and it is
    // the one that answered with `String formatting error: a number is
    // required` at runtime: one placeholder, one value, nothing for a count to
    // disagree about. What is wrong is the *type* of the second branch, and
    // only a check of conversions against types can say so. Until someone
    // writes that one, this line is the guard's ceiling.
    expect(formatMismatches('box.add_child(Ui.label(Loc.f("· %d Sterne benötigt",'
      + ' [need if need > 0 else "· Level %d zuerst" % (n - 1)]), 12))\n', 'probe.gd')).toEqual([]);
  });

  it('zählt eine Liste über mehrere Zeilen, auch mit Schlusskomma', () => {
    expect(formatMismatches('Loc.f("Boni: %d · %d · %d · %d", [a,\n\tb,\n\tc,\n\td,])\n', 'probe.gd'))
      .toEqual([]);
  });

  it('lässt einen auskommentierten Aufruf in Ruhe', () => {
    expect(formatMismatches('\t\t# Loc.f("Bestwert: %s", [best])\n', 'probe.gd')).toEqual([]);
  });

  it('lässt Aufrufe liegen, deren Liste es nicht zählen kann', () => {
    // A variable instead of a list, a built template, a `"""` block: the count
    // is not knowable here, and a guess is worse than silence.
    expect(formatMismatches('Loc.f("Best: %s", values)\n', 'probe.gd')).toEqual([]);
    expect(formatMismatches('Loc.f("Best: " + name, [a, b])\n', 'probe.gd')).toEqual([]);
    expect(formatMismatches('Loc.f("""\nBest: %s\n""", [a, b])\n', 'probe.gd')).toEqual([]);
  });
});
