/**
 * Types for `qrcode-terminal`.
 *
 * The package ships no declarations, and it is used by exactly one call:
 * `scripts/telegram-login.ts` draws the Telegram login link as a QR code so the
 * owner scans it with the phone that has Telegram on it. One function, written by
 * hand — a build step for a single signature would be the larger statement.
 *
 * A bare-specifier ambient declaration rather than a file beside the module: the
 * import is `from 'qrcode-terminal'`, not `from './qrcode-terminal.mjs'`, so
 * TypeScript looks for a declared module and not for a neighbouring file. That is
 * the one difference to `scripts/locale.d.mts`, which works the other way round.
 */
declare module 'qrcode-terminal' {
  /**
   * Renders `text` as a QR code into the terminal.
   *
   * The callback rather than a return value is the package's shape, and the scan
   * only works if the caller prints it synchronously: Telegram's login token
   * expires after about a minute, so the code has to be on the screen before it is
   * read, never stored for later.
   */
  export function generate(
    text: string,
    options: { small?: boolean },
    callback: (code: string) => void,
  ): void;
}