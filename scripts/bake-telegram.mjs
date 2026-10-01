#!/usr/bin/env node
/**
 * Bakes the Telegram credentials into the Godot build.
 *
 * The game delivers a player's suggestion to the owner's bot straight from the
 * device when no server address is configured, which means the token has to be
 * inside the APK. This script is the only thing that writes it, it reads
 * `.env` only, and its output is git-ignored — so the token never reaches the
 * public repository, the dashboard backup, or `git log`.
 *
 * It is also worth being blunt about what this cannot achieve: an APK is a zip,
 * so the token is readable by anyone who unpacks the game. Telegram cannot
 * restrict a token by application signature. See the note in
 * `godot/src/core/autoload/telegram_relay.gd` before treating that as a
 * settled question.
 *
 * Usage:  node scripts/bake-telegram.mjs [--check]
 *   --check  report what would be baked, write nothing. Exit 1 if unconfigured.
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const ENV_FILE = join(ROOT, '.env');
const TARGET = join(ROOT, 'godot', 'telegram_config.gd');

/** Minimal `.env` reader: KEY=VALUE lines, `#` comments, optional quotes. */
function readEnv(path) {
  const out = {};
  if (!existsSync(path)) return out;
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const trimmed = line.trim();
    if (trimmed === '' || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq < 1) continue;
    const key = trimmed.slice(0, eq).trim();
    let value = trimmed.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"') && value.length > 1) ||
      (value.startsWith("'") && value.endsWith("'") && value.length > 1)
    ) {
      value = value.slice(1, -1);
    }
    out[key] = value;
  }
  return out;
}

const checkOnly = process.argv.includes('--check');
const env = readEnv(ENV_FILE);
const token = (env.TELEGRAM_BOT_TOKEN ?? '').trim();
const chatId = (env.TELEGRAM_CHAT_ID ?? '').trim();
const missing = [];

if (!token) missing.push('TELEGRAM_BOT_TOKEN');
if (!chatId) missing.push('TELEGRAM_CHAT_ID');

// A GDScript string literal: backslash and quote escaped, newlines kept literal
// so the token cannot break out of the constant.
const gdString = (value) => `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;

const contents = `## GENERATED FILE — DO NOT EDIT, DO NOT COMMIT.
##
## Written by \`scripts/bake-telegram.mjs\` from \`.env\` at build time. It holds the
## owner's Telegram bot credentials so the game can deliver a suggestion from the
## device itself. Regenerate with \`npm run telegram:bake\`.
##
## Because this file is inside the exported package, the token is readable by
## anyone who unpacks the APK. That is a known, owner-accepted trade — see the
## header of \`src/core/autoload/telegram_relay.gd\`.

extends RefCounted

## Telegram bot token. Empty when the build was made without credentials, and
## the game then falls back to queuing the suggestion in \`user://\`.
const TOKEN := ${gdString(token)}

## Chat that receives every suggestion. The owner's own chat with the bot.
const CHAT_ID := ${gdString(chatId)}
`;

if (checkOnly) {
  if (missing.length > 0) {
    console.error(`[telegram] nicht konfiguriert: ${missing.join(', ')} fehlt in .env`);
    process.exit(1);
  }
  // Lengths only — the values themselves are secrets and belong in no log.
  console.log(
    `[telegram] bereit: Token ${token.length} Zeichen, Chat-ID ${chatId.length} Zeichen (--check, nichts geschrieben)`
  );
  process.exit(0);
}

if (missing.length > 0) {
  // Not fatal: a build without a bot still works, it just queues suggestions.
  console.warn(
    `[telegram] ${missing.join(', ')} fehlt in .env — der Build enthält keine Bot-Zugangsdaten, ` +
      'Vorschläge werden lokal in die Warteschlange geschrieben.'
  );
}

writeFileSync(TARGET, contents, 'utf8');
console.log(
  `[telegram] ${missing.length === 0 ? 'Zugangsdaten eingebaut' : 'leere Konfiguration geschrieben'} → godot/telegram_config.gd`
);