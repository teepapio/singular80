import 'dotenv/config';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { TelegramClient } from 'telegram';
import { StringSession } from 'telegram/sessions';

/**
 * One-time login of the owner's Telegram account, so the server can read the chat
 * the dashboard's suggestions arrive in.
 *
 * ## Why the owner has to scan something
 *
 * A suggestion from the game is posted **with the bot token**, and Telegram never
 * hands a bot its own messages back (official FAQ: bots "will not be able to see
 * messages from other bots regardless of mode"). The Bot API also has no method
 * that reads a chat's history at all. A user session does see everything in its
 * own chats — so the account has to be linked once, and this is that moment.
 *
 * A QR code rather than a phone number: nothing is typed, no code is read out,
 * and nothing that could be shoulder-surfed is written into a shell history.
 *
 * ## What it stores
 *
 * One file, `data/telegram-user.session` (git-ignored). It is the account
 * credential, so it is treated like the bot token: never committed, never sent
 * anywhere.
 */

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const dataDir = process.env.DATA_DIR ?? join(root, 'data');
const sessionPath = join(dataDir, 'telegram-user.session');

function requireCredentials(): { apiId: number; apiHash: string } {
  const apiId = Number(process.env.TELEGRAM_API_ID ?? '');
  const apiHash = (process.env.TELEGRAM_API_HASH ?? '').trim();
  if (!apiId || !apiHash) {
    console.error(
      [
        'Es fehlen TELEGRAM_API_ID und TELEGRAM_API_HASH.',
        '',
        'Diese zwei Werte kommen von https://my.telegram.org — dort mit der',
        'Telefonnummer anmelden, "API development tools" öffnen und eine App',
        'anlegen. Sie gehören zum Konto, nicht zum Bot.',
        '',
        'Dann in .env eintragen:',
        '  TELEGRAM_API_ID=123456',
        '  TELEGRAM_API_HASH=<32 Zeichen>',
      ].join('\n'),
    );
    process.exit(1);
  }
  return { apiId, apiHash };
}

function readSession(): string {
  try {
    return readFileSync(sessionPath, 'utf8');
  } catch {
    return '';
  }
}

async function main(): Promise<void> {
  const { apiId, apiHash } = requireCredentials();
  mkdirSync(dataDir, { recursive: true });

  const client = new TelegramClient(new StringSession(readSession()), apiId, apiHash, {
    connectionRetries: 3,
  });

  await client.connect();

  if (await client.isUserAuthorized()) {
    const me = await client.getMe();
    console.log(`Angemeldet als ${me?.firstName ?? '?'}. Sitzung ist gültig: ${sessionPath}`);
    await client.disconnect();
    return;
  }

  console.log('');
  console.log('  Telegram öffnen  →  Einstellungen  →  Geräte  →  Desktop-Gerät verbinden');
  console.log('  und die untenstehende Adresse öffnen (oder den QR-Code scannen).');
  console.log('');
  console.log('  Warte auf die Bestätigung …');
  console.log('');

  await client.signInUserWithQrCode(
    { apiId, apiHash },
    {
      // The token arrives as bytes; Telegram wants it base64url-encoded, and that
      // string is the entire payload of the QR code.
      qrCode: async (code) => {
        console.log(`  https://t.me/loginurl?token=${code.token.toString('base64url')}`);
        console.log('');
      },
      // Only reached if the account has a two-step password, which a QR login is
      // normally exempt from. Asked for interactively rather than from a variable,
      // so it never reaches a shell history.
      password: async () => {
        // Only reached when the account has a two-step password, which a QR login
        // normally bypasses. Asked interactively so it never reaches a shell
        // history or a log file.
        const { createInterface } = await import('node:readline/promises');
        const rl = createInterface({ input: process.stdin, output: process.stdout });
        try {
          return await rl.question('Zwei-Schritt-Passwort: ');
        } finally {
          rl.close();
        }
      },
      onError: async (err: Error) => {
        console.error(`Anmeldung fehlgeschlagen: ${err.message}`);
        return true; // stop the flow
      },
    },
  );

  // `StringSession.save()` persists the session into itself; there is no return
  // value to write — the serialized form is read back from the session.
  client.session.save();
  writeFileSync(sessionPath, String(client.session));
  const me = await client.getMe();
  await client.disconnect();
  console.log(`Angemeldet als ${me?.firstName ?? '?'}. Sitzung gespeichert: ${sessionPath}`);
  console.log('Der Server liest den Chat ab jetzt beim Start — Dashboard neu laden.');
}

main().catch((err: unknown) => {
  console.error('Anmeldung fehlgeschlagen:', (err as Error).message);
  process.exitCode = 1;
});