/**
 * One command that answers "can we upload yet?".
 *
 * It chains the checks Play enforces in turn: config/app.json placeholders and
 * https URLs, the store listing's character limits and forbidden marketing
 * words, the four required legal documents, the graphics and their dimensions,
 * and finally the AAB itself (targetSdk, package, signature).
 *
 * Exit code 0 means "uploadable", anything else lists what is missing.
 */
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join, extname } from 'node:path';
import {
  config, PROJECT, ASSET_DIR, BUILD_DIR, SHOT_DIR, listTodos, isTodo,
  ok, info, warn, fail, step, done, abort, tryRun, which,
} from './lib.mjs';

const cfg = config();
const blockers = [];
const warnings = [];
let checks = 0;
let passed = 0;

const hard = (cond, good, bad) => {
  checks += 1;
  if (cond) {
    passed += 1;
    ok(good);
  } else {
    fail(bad);
    blockers.push(bad);
  }
  return cond;
};
const soft = (cond, good, bad) => {
  checks += 1;
  if (cond) {
    passed += 1;
    ok(good);
  } else {
    warn(bad);
    warnings.push(bad);
  }
  return cond;
};

// --- 1. config --------------------------------------------------------------
step('1 config/app.json');
const todos = listTodos();
hard(todos.length === 0, 'keine Platzhalter', `${todos.length} Platzhalter: ${todos.map((t) => t.path).join(', ')}`);
for (const [name, url] of Object.entries(cfg.urls)) {
  if (isTodo(url)) continue;
  soft(/^https:\/\/[^ ]+$/.test(url), `urls.${name} ist eine https-URL`, `urls.${name} = ${url} — Play verlangt eine öffentlich erreichbare https-URL für Datenschutz und Nutzungsbedingungen.`);
}
soft(cfg.app.storeName.length <= 30, `App-Name "${cfg.app.storeName}" (${cfg.app.storeName.length}/30 Zeichen)`, `App-Name ist ${cfg.app.storeName.length} Zeichen — Play erlaubt 30.`);
soft(/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/.test(cfg.app.packageName), `Paketname ${cfg.app.packageName} ist gültig`, `Paketname ${cfg.app.packageName} ist kein gültiger Android-Paketname.`);
soft(cfg.version.versionCode >= 1, `versionCode ${cfg.version.versionCode}`, 'versionCode muss ≥ 1 sein.');

// --- 2. store listing -------------------------------------------------------
step('2 Store-Texte');

/**
 * `## Field` heading followed by plain text until the next heading.
 *
 * The end-of-input lookahead is `(?![\s\S])` rather than `$`: with the `m` flag
 * `$` also matches at every line end, which truncates each field after one line.
 */
function parseListing(file) {
  const text = readFileSync(file, 'utf8');
  const out = {};
  const re = /^##[ \t]+(.+?)[ \t]*\r?\n([\s\S]*?)(?=\r?\n##[ \t]|(?![\s\S]))/gm;
  for (const m of text.matchAll(re)) out[m[1].trim()] = m[2].trim();
  return out;
}

// Play rejects these in short/full descriptions: performance claims, prices,
// calls to action, and decorative punctuation.
const FORBIDDEN = [
  { re: /\b(best|bestever|am besten|number one|#1|no\. ?1|top seller|bestseller)\b/i, why: 'Performance-/Rang-Behauptung' },
  { re: /\b(new|neu|brandneu|jetzt neu)\b/i, why: 'Zeitbezogene Werbung' },
  { re: /\b(free|gratis|kostenlos)\b/i, why: 'Preisangabe — die App ist zwar kostenlos, Play verbietet den Begriff im Listing' },
  { re: /\b(sale|rabatt|discount|deal|angebot|50 ?% off)\b/i, why: 'Preis-/Rabattangabe' },
  { re: /\b(download now|jetzt laden|install(ieren)? now|play now|jetzt spielen|try now|ausprobieren und)\b/i, why: 'Call-to-Action' },
  { re: /\b(million downloads|millionen downloads|million+)\b/i, why: 'Downloadzahl' },
  { re: /[★☆♥♦♠♣]/u, why: 'Symbol/Sternchen' },
  { re: /!!|\?\?|\?!|!\?|\.\.\.|…/u, why: 'Wiederholte Satzzeichen' },
  { re: /[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/u, why: 'Emoji' },
];

for (const lang of cfg.app.languages) {
  const file = join(PROJECT, 'listing', `${lang}.md`);
  if (!existsSync(file)) {
    hard(false, '', `listing/${lang}.md fehlt (Pflicht: Store-Listing in ${lang}).`);
    continue;
  }
  const fields = parseListing(file);
  const short = fields['Short description'] ?? '';
  const full = fields['Full description'] ?? '';
  const name = fields['App name'] ?? '';

  hard(short.length > 0, `${lang}: Short description vorhanden`, `${lang}: "## Short description" fehlt.`);
  hard(
    short.length <= 80,
    `${lang}: Short description ${short.length}/80 Zeichen`,
    `${lang}: Short description hat ${short.length} Zeichen, erlaubt sind 80.`,
  );
  hard(full.length > 0, `${lang}: Full description vorhanden`, `${lang}: "## Full description" fehlt.`);
  hard(
    full.length <= 4000,
    `${lang}: Full description ${full.length}/4000 Zeichen`,
    `${lang}: Full description hat ${full.length} Zeichen, erlaubt sind 4000.`,
  );
  hard(
    name === cfg.app.storeName,
    `${lang}: App-Name stimmt mit config/app.json`,
    `${lang}: App-Name "${name}" ≠ config/app.json "${cfg.app.storeName}".`,
  );
  soft(/^https?:\/\//.test(fields['App name'] ? name : 'https://x') || name.length > 0, `${lang}: App-Name gesetzt`, `${lang}: App-Name fehlt.`);

  for (const [key, value] of Object.entries(fields)) {
    if (!key.startsWith('Short description') && key !== 'Full description') continue;
    for (const { re, why } of FORBIDDEN) {
      const m = value.match(re);
      if (m) {
        hard(false, '', `${lang}: "${key}" enthält "${m[0]}" — ${why}. Play lehnt das im Listing ab.`);
        break;
      }
    }
  }

  const captions = Object.keys(fields).filter((k) => k.startsWith('Screenshot'));
  soft(captions.length >= 2, `${lang}: ${captions.length} Screenshot-Beschreibungen`, `${lang}: nur ${captions.length} Screenshot-Beschreibungen — Play verlangt mindestens 2 Screenshots.`);
  for (const key of captions) {
    if (fields[key].length > 80) {
      hard(false, '', `${lang}: "${key}" hat ${fields[key].length} Zeichen (Play erlaubt 80 für Screenshot-Captions).`);
    }
  }
  if (![...FORBIDDEN].some(({ re }) => re.test(short + full))) ok(`${lang}: keine verbotenen Begriffe`);
}

// --- 3. legal documents -----------------------------------------------------
step('3 Rechtstexte');
const REQUIRED_DOCS = [
  ['privacy-policy.en.md', 'Datenschutzrichtlinie (EN, Pflicht für die Play-Datenschutz-URL)'],
  ['terms-of-use.en.md', 'Nutzungsbedingungen (EN, von Play für UGC verlangt)'],
  ['moderation.md', 'Moderations-/Meldekonzept (Pflicht wegen Spieler-Vorschlägen)'],
  ['imprint.md', 'Impressum (Pflicht in DE/AT/CH für öffentlich zugängliche Angebote)'],
];
for (const [file, why] of REQUIRED_DOCS) {
  const path = join(PROJECT, 'legal', file);
  if (!existsSync(path)) {
    hard(false, '', `legal/${file} fehlt — ${why}.`);
    continue;
  }
  const text = readFileSync(path, 'utf8');
  const placeholders = [...text.matchAll(/\[\[([A-Z_]+)\]\]/g)].map((m) => m[1]);
  soft(placeholders.length === 0, `legal/${file} ohne Platzhalter`, `legal/${file} enthält noch ${[...new Set(placeholders)].join(', ')} — ausfüllen, dann Play.`);
  hard(text.length > 500, `legal/${file} ist substanziell (${text.length} Zeichen)`, `legal/${file} ist mit ${text.length} Zeichen zu kurz für eine verwertbare Rechtsseite.`);
}

// --- 4. graphics ------------------------------------------------------------
step('4 Grafiken');
const generated = join(ASSET_DIR, 'generated');

function imageInfo(name) {
  if (!which('identify')) return null;
  const res = tryRun('identify', ['-format', '%w %h %[channels]', join(generated, name)]);
  return res.code === 0 ? res.out.trim() : null;
}

for (const [file, width, height, maxKb, note] of [
  ['icon-512.png', 512, 512, 1024, 'App-Icon (32-Bit PNG mit Alpha)'],
  ['feature-graphic-1024x500.png', 1024, 500, 15 * 1024, 'Feature Graphic (24-Bit PNG, kein Alpha)'],
]) {
  const path = join(generated, file);
  if (!existsSync(path)) {
    hard(false, '', `${file} fehlt → npm run assets (${note}).`);
    continue;
  }
  const info = imageInfo(file);
  const [w, h] = (info ?? `${width} ${height}`).split(' ').map(Number);
  const kb = statSync(path).size / 1024;
  hard(w === width && h === height, `${file} ${w}×${h} (${note})`, `${file} ist ${w}×${h}, Play verlangt exakt ${width}×${height}.`);
  soft(kb <= maxKb, `${file} ${kb.toFixed(0)} KB (Limit ${maxKb >= 1024 ? `${(maxKb / 1024).toFixed(0)} MB` : `${maxKb} KB`})`, `${file} ist ${kb.toFixed(0)} KB — über dem Limit.`);
}

const shots = existsSync(SHOT_DIR) ? readdirSync(SHOT_DIR).filter((f) => extname(f).toLowerCase() === '.png') : [];
soft(shots.length >= 2, `${shots.length} Screenshots bereit`, `Nur ${shots.length} Screenshots. Mindestens 2, besser 3–4 in 16:9. Auf dieser Maschine nicht headless renderbar → siehe docs/LISTING.md.`);
for (const s of shots) {
  const info = imageInfo(s) ?? null;
  if (!info) break;
  const [w, h] = info.split(' ').map(Number);
  if (w && h && Math.abs(w / h - 16 / 9) > 0.02) {
    warn(`Screenshot ${s} ist ${w}×${h} — Play empfiehlt 16:9.`);
  }
}

// --- 5. AAB -----------------------------------------------------------------
step('5 Release-Artefakt');
const aab = join(BUILD_DIR, 'singular80-play.aab');
if (!existsSync(aab)) {
  hard(false, '', 'Kein AAB gebaut → npm run build');
} else {
  const ageHours = (Date.now() - statSync(aab).mtimeMs) / 3_600_000;
  soft(ageHours < 48, `AAB ist ${ageHours.toFixed(1)} h alt`, `AAB ist ${ageHours.toFixed(0)} h alt — vor dem Upload neu bauen.`);
  const verify = tryRun('node', ['scripts/verify-aab.mjs'], { cwd: PROJECT });
  const failed = verify.out.split('\n').filter((l) => l.includes('✗'));
  hard(failed.length === 0, 'AAB besteht alle technischen Prüfungen', failed.join(' | '));
}

// --- result -----------------------------------------------------------------
step('Bilanz');
info(`${passed}/${checks} Prüfungen bestanden, ${warnings.length} Hinweis(e).`);
if (blockers.length) {
  for (const b of blockers) info(`  ✗ ${b}`);
  abort(`${blockers.length} Blocker — noch nicht hochladen.`);
}
done(
  warnings.length
    ? `Abnahmebereit (${warnings.length} Hinweis(e) offen).`
    : 'Alles grün: AAB hochladen, Formulare ausfüllen, Tester einladen.',
);
