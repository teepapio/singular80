#!/usr/bin/env node
/**
 * Copies the canonical content pack into the Godot project.
 *
 * `content/*.json` is the single source of truth (the server, the dashboard and
 * every agent edit it). The Android app can only read files that live inside
 * its own project folder, so the pack is mirrored into `godot/assets/content/`.
 *
 *   node scripts/sync-content.mjs          copy the files
 *   node scripts/sync-content.mjs --check  fail if anything is out of date
 */
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const source = join(root, 'content');
const target = join(root, 'godot', 'assets', 'content');
const check = process.argv.includes('--check');

const files = readdirSync(source).filter((name) => name.endsWith('.json'));
let drift = 0;

for (const name of files) {
  const from = readFileSync(join(source, name));
  const to = join(target, name);
  let current = null;
  try {
    current = readFileSync(to);
  } catch {
    /* missing on the target side */
  }
  if (current && current.equals(from)) continue;
  if (check) {
    console.error(`[sync-content] veraltet: godot/assets/content/${name} weicht von content/${name} ab`);
    drift += 1;
    continue;
  }
  writeFileSync(to, from);
  console.log(`[sync-content] kopiert: ${name}`);
}

if (check && drift > 0) {
  console.error(`[sync-content] ${drift} Datei(en) nicht synchron. Führe "npm run content:sync" aus.`);
  process.exit(1);
}
if (!check) {
  console.log(`[sync-content] ${files.length} Inhaltsdateien synchron.`);
}
