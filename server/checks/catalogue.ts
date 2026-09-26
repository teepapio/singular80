/**
 * The catalogue of deployed-version checks.
 *
 * A check is one thing worth looking at on a build that is already on a phone.
 * The three families are the three complaints that reach support and that no
 * headless test suite can see:
 *
 * - `actions`  — "the button does nothing"
 * - `logs`     — "the game is noisy/laggy"
 * - `performance` — "it stutters"
 *
 * Each family exists twice: a `static` probe that reads the source and needs
 * nothing but the repository, and a `device` probe that measures the installed
 * app. The static one is what runs unattended, because it is deterministic and
 * cheap; the device one is what an operator starts when a static check found
 * nothing but a player still complains.
 *
 * The static globs are deliberately coarse. A check that only looked at one
 * screen would go green while the same defect sat in the next one, and a queue
 * that reports "all clear" on a partial view is worse than no queue.
 */
import type { CheckKind, CheckSpec } from '../../src/shared/types.js';

/** Where the game's own GDScript lives. */
const GAME_SRC = 'godot/src/game';
const LOGIC_SRC = 'godot/src/core';

export const CHECK_SPECS: CheckSpec[] = [
  {
    id: 'actions-buttons',
    kind: 'actions',
    probe: 'static',
    title: 'Tote Knöpfe',
    description:
      'Findet Schaltflächen, die gerendert werden, aber weder einen Callback noch eine '
      + 'Input-Action bekommen. Ui.button() verbindet nur `if on_press.is_valid()` — ein '
      + 'fehlender Callback ist deshalb kein Fehler, sondern ein toter Knopf, der im '
      + 'Screenshot gut aussieht.',
    scope: [`${GAME_SRC}/**/*.gd`, `${LOGIC_SRC}/**/*.gd`],
  },
  {
    id: 'actions-wired',
    kind: 'actions',
    probe: 'device',
    title: 'Knöpfe auf dem Gerät',
    description:
      'Tippt jeden Knopf eines Bildschirms an und prüft, ob sich etwas ändert: ein '
      + 'Statewechsel, ein Ton, ein neuer Screen. Der Source-Check sieht einen verdrahteten '
      + 'Knopf, aber nicht, ob die verdrahtete Funktion das tut, was der Knopf verspricht.',
    targets: ['tetris', 'arena', 'siedler', 'candy3d', 'pang', 'metro3d', 'merge3d'],
    limits: { maxFrameMs: 250 },
  },
  {
    id: 'logs-spam',
    kind: 'logs',
    probe: 'static',
    title: 'Logspam',
    description:
      'Findet `print` und Verwandte in Funktionen, die pro Frame oder pro Eingabe laufen. '
      + 'Ein einzelnes `print` in `_process` sind rund 60 Zeilen pro Sekunde: auf Android '
      + 'teuer, und es begräbt die eine Zeile, auf die es ankommt.',
    scope: [`${GAME_SRC}/**/*.gd`, `${LOGIC_SRC}/**/*.gd`],
  },
  {
    id: 'logs-device',
    kind: 'logs',
    probe: 'device',
    title: 'Logcat des Geräts',
    description:
      'Liest logcat über eine Session und misst, wie viele Zeilen pro Sekunde ankommen und '
      + 'welche Tags am lautesten sind. Findet Logspam aus Bibliotheken und aus Pfaden, die '
      + 'der Source-Check nicht sieht.',
    targets: ['tetris', 'arena', 'siedler', 'candy3d', 'pang', 'metro3d', 'merge3d'],
    limits: { maxLogLinesPerSecond: 5 },
  },
  {
    id: 'performance-frame',
    kind: 'performance',
    probe: 'static',
    title: 'Ruckler-Ursachen',
    description:
      'Findet Allokationen (`new`) und wachsende Container in `_process`, `_physics_process` '
      + 'und `_update_world`. Eine Allokation pro Frame ist der klassische GC-Ruckler auf '
      + 'Android; ein Container ohne `clear()` wächst und wird mit der Zeit immer langsamer.',
    scope: [`${GAME_SRC}/**/*.gd`],
  },
  {
    id: 'performance-fps',
    kind: 'performance',
    probe: 'device',
    title: 'Bildrate auf dem Gerät',
    description:
      'Fährt jedes Spiel an und misst die Bildrate über eine feste Strecke. Der Source-Check '
      + 'findet die Ursache, aber nicht die tatsächliche Last: dieselbe Schleife ist auf einem '
      + 'Flaggschiff ein Flop und auf einem Tablett ein Einbruch.',
    targets: ['tetris', 'arena', 'siedler', 'candy3d', 'pang', 'metro3d', 'merge3d'],
    limits: { minFps: 30, maxFrameMs: 33, maxMemoryMb: 900 },
  },
];

/** Every spec, by id. */
export const CHECKS_BY_ID = new Map(CHECK_SPECS.map((spec) => [spec.id, spec]));

export function specsOfKind(kind: CheckKind): CheckSpec[] {
  return CHECK_SPECS.filter((spec) => spec.kind === kind);
}

export function specsForProbe(probe: CheckSpec['probe']): CheckSpec[] {
  return CHECK_SPECS.filter((spec) => spec.probe === probe);
}

/** Human label for a finding code, for the dashboard and the promoted suggestion. */
export const FINDING_LABELS: Record<string, string> = {
  'button-without-callback': 'Knopf ohne Callback',
  'button-without-action': 'Knopf ohne Input-Action',
  'log-per-frame': 'Logausgabe pro Frame',
  'log-in-hot-path': 'Logausgabe auf heißen Pfad',
  'alloc-per-frame': 'Allokation pro Frame',
  'array-per-frame': 'Container pro Frame',
  'append-per-frame': 'Wachsender Container pro Frame',
};

/**
 * Turns findings into a German text for a promoted suggestion, so the operator
 * does not have to write the sentence a second time in the dashboard form.
 */
export function findingToSuggestionText(
  spec: CheckSpec,
  findings: { code: string; file: string; line: number; message: string }[],
  limit = 5,
): string {
  const head = `Die Prüfung „${spec.title}" meldet ${findings.length} Fundort(e):`;
  const lines = findings.slice(0, limit).map((f) => `- ${f.file}:${f.line} — ${f.message}`);
  const rest = findings.length > limit ? `\n… und ${findings.length - limit} weitere.` : '';
  return `${head}\n\n${lines.join('\n')}${rest}`;
}
