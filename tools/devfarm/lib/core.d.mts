/**
 * Typdeklaration für die Farm-Werkzeuge.
 *
 * Die Farm ist JavaScript, weil sie ohne Build-Schritt neben `godot` und
 * `scripts/` liegen soll. `tsc` kann eine `.mjs` ohne Deklaration nicht
 * prüfen und meldet für jedes Feld ein implizites `any` — in einer
 * `strict`-Konfiguration ist das ein Fehler, kein Hinweis. Diese Datei
 * beschreibt also den schmalen Schnitt, den die Tests und die Dashboard-Skripte
 * brauchen, damit die Typprüfung wieder etwas prüft.
 */

export interface Lease {
  file: string;
  acquire(owner: string): Lease;
  release(): void;
}

export interface FarmConfig {
  backend: string;
  avd: string;
  systemImage: string;
  deviceProfile: string;
  instances: number;
  basePort: number;
  gpu: string;
  bootTimeoutSeconds: number;
  package: string;
  activity: string;
  apkPreset: string;
  apkPath: string;
  bridgeHost: string;
  bridgePort: number;
  outDir: string;
  stateDir: string;
  /** von `loadConfig` ergänzt */
  sdk: string;
  adb: string;
  emulator: string;
  avdmanager: string;
}

export declare function loadConfig(file?: string): FarmConfig;
export declare function run(file: string, args: string[], opts?: Record<string, unknown>): string;
export declare function tryRun(
  file: string,
  args: string[],
  opts?: Record<string, unknown>,
): { ok: boolean; out: string; code: number };
export declare function ensureDir(dir: string): string;
export declare function writeJson(file: string, value: unknown): void;
export declare function readJson<T>(file: string, fallback?: T | null): T | null;
export declare function hash(text: string, length?: number): string;
export declare function adb(cfg: FarmConfig, serial: string, args: string[], opts?: Record<string, unknown>): string;
export declare function adbTry(
  cfg: FarmConfig,
  serial: string,
  args: string[],
  opts?: Record<string, unknown>,
): { ok: boolean; out: string; code: number };
export declare function listDevices(cfg: FarmConfig): { serial: string; state: string }[];
export declare function stamp(seconds: number): string;
export declare function centreOf(rect: { x: number; y: number; width: number; height: number }): { x: number; y: number };
export declare const ROOT: string;

export declare class Lease {
  constructor(file: string, options?: { timeoutMs?: number; onWait?: (file: string) => void });
  file: string;
  acquire(owner: string): Lease;
  release(): void;
}
