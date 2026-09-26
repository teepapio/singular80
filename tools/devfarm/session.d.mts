/**
 * Typdeklaration für den Session-Treiber. Siehe `lib/core.d.mts` für den Grund.
 */

export interface FarmScreen {
  id: string;
  path: string;
}

export interface FarmFinding {
  kind: string;
  severity: string;
  where: string;
  message: string;
  screen?: string;
}

export interface FarmReport {
  runId: string;
  game: string | null;
  screen: string | null;
  serial: string;
  startedAt: number;
  findings: FarmFinding[];
  audits: { screen: string; findings: FarmFinding[] }[];
  metrics: Record<string, number>[];
  shots: string[];
  errors: string[];
  logcat: string;
  ok: boolean;
  notes: string[];
  app?: string;
}

/** Alle Screens aus `godot/src/core/autoload/router.gd`. */
export declare function screensOfProject(): FarmScreen[];

export declare function runSession(options: {
  game?: string;
  screen?: string;
  audit?: boolean;
  soakSeconds?: number;
  shots?: number;
  label?: string;
}): Promise<{ report: FarmReport; outDir: string }>;
