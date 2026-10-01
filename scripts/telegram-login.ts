import 'dotenv/config';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { TelegramClient } from 'telegram';
import { StringSession } from 'telegram/sessions';
import qrcode from 'qrcode-terminal';

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

  const session = new StringSession(readSession());
  const client = new TelegramClient(session, apiId, apiHash, {
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
        // `tg://login?token=…`, exactly as Telegram documents it (core.telegram.org/api/qr-login).
// There is no `t.me/login` web route — Telegram reads that first path segment as
// a username and answers "user name not found". A `tg://` link also cannot be
// tapped open; the code has to be *scanned* by the Telegram app, which is why
// the QR below is the real way in and the printed address is only a fallback.
const url = `tg://login?token=${code.token.toString('base64url')}`;
        // The token is written out as well as printed: it changes every minute,
        // and a page that shows the *current* one can be left open on the desktop
        // while the phone scans it. A camera reads a drawn code far more reliably
        // than it reads one made of terminal characters.
        try {
          mkdirSync(dataDir, { recursive: true });
          writeFileSync(join(dataDir, 'telegram-login-url.txt'), url);
        } catch {
          // Only a convenience; the code is on the screen either way.
        }
        // Drawn in the terminal, because the alternative is typing a 60-character
        // URL on the phone — and the phone is what has the Telegram app on it.
        qrcode.generate(url, { small: true }, (qr: string) => {
          console.log(qr);
        });
        console.log('  ↑ Mit der Kamera des Telefons scannen');
        console.log(`  Oder diese Adresse auf dem Telefon öffnen:\n  ${url}\n`);
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

  // `save()` **returns** the serialized session — it does not write a file, and
  // there is no `toString` to fall back on. `String(client.session)` produces the
  // 15 characters `[object Object]`, which is not a session and is not refused
  // until the next start tries to parse it.
  const serialized = session.save();
  writeFileSync(sessionPath, serialized);

  // Read it straight back through the class that has to accept it. A login that
  // saved nothing usable is worse than one that failed: it looks finished, and the
  // only symptom appears at the next server start, an hour later, as "session not
  // authorized".
  try {
    new StringSession(readFileSync(sessionPath, 'utf8'));
  } catch (err) {
    console.error(`Sitzung gespeichert, aber nicht lesbar: ${(err as Error).message}`);
    process.exitCode = 1;
    return;
  }
  const me = await client.getMe();
  await client.disconnect();
  console.log(`Angemeldet als ${me?.firstName ?? '?'}. Sitzung gespeichert: ${sessionPath}`);
  console.log('Der Server liest den Chat ab jetzt beim Start — Dashboard neu laden.');
}

main().catch((err: unknown) => {
  console.error('Anmeldung fehlgeschlagen:', (err as Error).message);
  process.exitCode = 1;
});