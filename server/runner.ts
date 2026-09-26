import { spawn, spawnSync, type ChildProcessByStdio } from 'node:child_process';
import { EventEmitter } from 'node:events';
import type { Readable } from 'node:stream';
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import type {
  QueueState,
  RunEvent,
  RunRecord,
  RunView,
  RunnerPolicy,
  ScopeAudit,
  Settings,
  Suggestion,
  SuggestionStatus,
  SuggestionView,
} from '../src/shared/types';
import type { Store } from './db';
import { auditScope, scopeForSuggestion } from './scopes';

export interface RunnerCallbacks {
  onStarted?: (run: RunRecord, suggestion: Suggestion) => void;
  onEvent?: (runId: string, event: RunEvent) => void;
  onFinished?: (run: RunRecord, suggestion: Suggestion) => void;
  onSuggestionStatus?: (suggestionId: number, status: SuggestionStatus) => void;
  onQueueState?: (state: QueueState) => void;
}

type RunnerChild = ChildProcessByStdio<null, Readable, Readable>;

interface RunEntry {
  record: RunRecord;
  events: RunEvent[];
  summary: string;
  child: RunnerChild | null;
  cancelRequested: boolean;
  /** Set when the hard timeout fired, so the close handler does not relabel the run. */
  timedOut: boolean;
  /** PID of an adopted run whose owning server process is gone (no child handle). */
  pid: number | null;
  /** Byte/char offset already consumed when tailing an orphaned run's log file. */
  logOffset: number;
  /** Poll timer that watches an adopted run until its process exits. */
  timer: ReturnType<typeof setInterval> | null;
}

const MAX_MEMORY_EVENTS = 4000;
const MAX_DETAIL = 6000;
const MAX_SUMMARY = 600;

/** How often an adopted (orphaned) run is checked for new log output and process exit. */
const ORPHAN_POLL_MS = 3000;

/** How often the supervisor enforces the hard timeout and the backoff wake-up. */
const SUPERVISOR_MS = 2000;

/** Longest a single sleep between two supervisor ticks may last. */
const MAX_SLEEP_MS = 30_000;

/** Grace period between SIGTERM and SIGKILL for a child that should go away. */
const KILL_GRACE_MS = 4000;

/** Never let a backoff grow into an operator's afternoon. */
const MAX_BACKOFF_MS = 15 * 60_000;

/** How often a growing run log is re-read for the scope audit. */
const AUDIT_THROTTLE_MS = 30_000;

/** True while a process with the given PID exists (EPERM still means alive). */
export function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === 'EPERM';
  }
}

/**
 * Git records commit times in whole seconds, the runner in milliseconds. Without
 * a second of tolerance a commit made in the same second as the start would look
 * older than the run and go unnoticed — which matters twice: when a restarted
 * server reconstructs an outcome, and when a retry checks whether the failed
 * attempt already committed.
 */
const COMMIT_CLOCK_SLACK_MS = 1000;

/**
 * Newest commit of the given suggestion whose commit time is at or after
 * `startedAt`, or null when there is no such commit. Used to reconstruct whether
 * an interrupted run managed to finish its work before its server process died,
 * and to keep a failed attempt from being repeated when it already committed.
 * When no suggestion id is given, the newest commit overall is considered.
 */
export function commitSince(startedAt: number | null, projectRoot: string, suggestionId?: number): string | null {
  if (startedAt === null) return null;
  const args = ['-C', projectRoot, 'log', '-1', '--pretty=format:%h%n%ct'];
  if (suggestionId !== undefined) {
    args.push('--extended-regexp', `--grep=suggestion-${suggestionId}([^0-9]|$)`);
  }
  const result = spawnSync('git', args, { encoding: 'utf8' });
  if (result.status !== 0) return null;
  const [hash, seconds] = result.stdout.trim().split('\n');
  if (!hash) return null;
  const timestamp = Number(seconds) * 1000;
  return Number.isFinite(timestamp) && timestamp >= startedAt - COMMIT_CLOCK_SLACK_MS ? hash : null;
}

/**
 * Finds a still-running `opencode run` process for the given suggestion by its
 * `--title` marker. Needed because a freshly started server has no memory of the
 * child processes its predecessor spawned (only works on Linux via /proc).
 */
export function findOpencodePid(suggestionId: number): number | null {
  let entries: string[];
  try {
    entries = readdirSync('/proc');
  } catch {
    return null;
  }
  const titlePattern = new RegExp(`--title Vorschlag #${suggestionId}(\\s|$)`);
  for (const name of entries) {
    if (!/^\d+$/.test(name)) continue;
    let cmdline: string;
    try {
      cmdline = readFileSync(`/proc/${name}/cmdline`, 'utf8');
    } catch {
      continue;
    }
    const argv0 = cmdline.split('\0')[0];
    if (!/(^|\/)opencode$/.test(argv0)) continue;
    const flat = cmdline.replace(/\0/g, ' ');
    if (titlePattern.test(flat)) return Number(name);
  }
  return null;
}

/** Local timestamp for log filenames, e.g. `2026-09-21_14-05-33`. */
function formatStamp(date: Date): string {
  const pad = (n: number) => String(n).padStart(2, '0');
  return (
    `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
    `_${pad(date.getHours())}-${pad(date.getMinutes())}-${pad(date.getSeconds())}`
  );
}

/** Human-readable timeout budget, e.g. `45 min` or `30 s` for a test-sized one. */
export function formatBudget(ms: number): string {
  if (ms <= 0) return 'unbegrenzt';
  if (ms < 60_000) return `${Math.round(ms / 1000)} s`;
  const minutes = ms / 60_000;
  return `${Number.isInteger(minutes) ? minutes : minutes.toFixed(1)} min`;
}

/** Collapse the agent's final text output into a short single-line summary. */
function shortSummary(raw: string, fallback: string): string {
  const clean = raw.replace(/\s+/g, ' ').trim();
  if (!clean) return fallback;
  if (clean.length <= MAX_SUMMARY) return clean;
  return `…${clean.slice(-MAX_SUMMARY).trimStart()}`;
}

export function findOpencodeBinary(): string {
  if (process.env.OPENCODE_BIN && existsSync(process.env.OPENCODE_BIN)) return process.env.OPENCODE_BIN;
  const local = join(homedir(), '.opencode', 'bin', 'opencode');
  if (existsSync(local)) return local;
  const which = spawnSync('which', ['opencode'], { encoding: 'utf8' });
  if (which.status === 0 && which.stdout.trim()) return which.stdout.trim();
  return 'opencode';
}

export function buildPrompt(
  suggestion: Suggestion,
  cluster: Suggestion[],
  settings: Settings,
  projectRoot: string,
  scopes: string[] = [],
  attempt = 1,
): string {
  const siblings = cluster.filter((s) => s.id !== suggestion.id);
  const siblingBlock = siblings.length
    ? `\nAndere Spieler haben sehr ähnliche Vorschläge gemacht (gleicher Cluster, berücksichtige sie alle):\n${siblings
        .map((s) => `- #${s.id}: ${s.text}`)
        .join('\n')}\n`
    : '';
  const extra = settings.extraInstructions.trim()
    ? `\nZusätzliche Anweisungen des Betreibers:\n${settings.extraInstructions.trim()}\n`
    : '';
  // The scope decides which agent may touch which file and which tests prove it.
  // Without it the agent has no way to know that `game_registry.gd` belongs to
  // somebody else — which is how a half-finished registry line slips through.
  const scopeBlock = scopes.length
    ? `\nSCOPE: ${scopes.join(', ')} (Manifest: node scripts/scopes.mjs list · node scripts/scopes.mjs explain <datei>)\n`
    : '';
  const retryBlock =
    attempt > 1
      ? `\nDIES IST WIEDERHOLUNGSVERSUCH ${attempt}: Der vorherige Versuch ist fehlgeschlagen. Prüfe zuerst das Run-Log und den Arbeitsbaum, mache nicht blind dasselbe noch einmal, und committe nur, was tatsächlich neu ist.\n`
      : '';
  return `Du arbeitest im Repository "${projectRoot}" (Godot-Spiel "Singular 80" für Android mit Fastify-Backend und Web-Dashboard).

AUFGABE: Setze den folgenden spieler-eingereichten Vorschlag um.

Vorschlag #${suggestion.id} [Kategorie: ${suggestion.category}, Stimmen: ${suggestion.votes}]:
"""
${suggestion.text}
"""
${siblingBlock}${scopeBlock}${retryBlock}REGELN:
1. Arbeite ausschließlich in diesem Repository. Lies zuerst AGENTS.md für Struktur und Erweiterungspunkte.
2. Das Spiel liegt in godot/ (GDScript, Godot 4.5). Server/Dashboard unter server/ und src/ sind Web-only und bleiben unverändert.
3. Bevorzuge reine Datenänderungen in content/*.json (Gegner, Waffen, Upgrades, Modi, Mechaniken) — sie werden beim Start der App geladen und wirken ohne Neubau.
4. Für neue Code-Mechaniken: lege eine Datei unter godot/src/core/logic/mechanics/<id>.gd an und registriere sie in godot/src/core/logic/mechanics/mechanics_index.gd. Halte dich an das Mechanic-Interface dort.
5. Performance ist wichtig: keine Allokationen pro Frame, vorhandene Pools nutzen, Entity-Limits beachten. Das Spiel muss flüssig auf Handy und Tablet laufen.
6. Touch-Steuerung ist Pflicht: jedes Spiel muss per virtuellem Stick und Buttons bedienbar sein, Tastatur ist optional.
7. Prüfe deine Änderung mit: "npm run typecheck" und "npm test". Im Godot-Bereich reicht der gezielte Lauf "npm run test:game -- --scope <dein-scope>"; der volle Lauf ist der Merge-Schritt.
8. Committe am Ende ausschließlich deine eigenen Dateien. "git add -A" ist verboten, weil im selben Baum andere Agenten arbeiten. Nutze einen eigenen Index:
   export GIT_INDEX_FILE=/tmp/opencode/idx-$(date +%s)-$$ ; git read-tree HEAD ; git add <deine Dateien> ; git commit -m "feat(suggestion-${suggestion.id}): <kurze Beschreibung>"
9. Wenn du eine Datei außerhalb deines Scopes brauchst (z. B. game_registry.gd, router.gd, asset_registry.gd), lege sie NICHT an, sondern schreibe sie in deine Zusammenfassung — das ist Sache des Merge-Schritts.
10. Wenn der Vorschlag nicht sinnvoll umsetzbar ist, mache die kleinste vernünftige Verbesserung im Sinne des Vorschlags und erkläre das.
11. Antworte am Ende mit einer kurzen Zusammenfassung auf Deutsch (was geändert wurde, welche Dateien, wie getestet).
${extra}`;
}

export class Runner {
  private entries = new Map<string, RunEntry>();
  private queue: string[] = [];
  private activeId: string | null = null;
  /** Persisted, not in memory: the queue survives a restart. */
  private paused: boolean;
  /** Wakes the runner when the head of the queue may start (retry backoff). */
  private wakeTimer: ReturnType<typeof setTimeout> | null = null;
  private wakeAt: number | null = null;
  private supervisor: ReturnType<typeof setInterval> | null = null;
  /** Memoized scope audits, keyed by log size so a growing log invalidates. */
  private auditCache = new Map<string, { key: string; audit: ScopeAudit; at: number }>();

  constructor(
    private store: Store,
    private options: {
      projectRoot: string;
      dataDir: string;
      contentDir: string;
      callbacks: RunnerCallbacks;
    },
  ) {
    mkdirSync(this.logDir, { recursive: true });
    this.paused = this.store.getQueuePaused();
    this.recover();
    this.supervisor = setInterval(() => this.tick(), SUPERVISOR_MS);
    this.supervisor.unref?.();
    // A run that was already past its budget when the server came up is killed
    // right away instead of at the first tick.
    this.tick();
  }

  /**
   * Releases timers. Never kills a child: a run that outlived its server is
   * adopted by the next process, and that is the whole point of the PID registry.
   */
  dispose(): void {
    if (this.supervisor) {
      clearInterval(this.supervisor);
      this.supervisor = null;
    }
    if (this.wakeTimer) {
      clearTimeout(this.wakeTimer);
      this.wakeTimer = null;
      this.wakeAt = null;
    }
    for (const entry of this.entries.values()) {
      if (entry.timer) {
        clearInterval(entry.timer);
        entry.timer = null;
      }
    }
  }

  /** Project-level folder holding one complete JSONL log per implementation run. */
  private get logDir(): string {
    return join(this.options.projectRoot, 'log');
  }

  /**
   * Registry mapping a run id to the PID of the opencode process it spawned. It
   * lets a freshly started server tell "still running elsewhere" apart from
   * "died with its previous server process" after a restart.
   */
  private get pidRegistryPath(): string {
    return join(this.options.dataDir, 'active-runs.json');
  }

  private readPidRegistry(): Record<string, number> {
    try {
      const parsed = JSON.parse(readFileSync(this.pidRegistryPath, 'utf8')) as Record<string, unknown>;
      const out: Record<string, number> = {};
      for (const [id, value] of Object.entries(parsed)) {
        if (typeof value === 'number' && Number.isFinite(value)) out[id] = value;
      }
      return out;
    } catch {
      return {};
    }
  }

  private writePidRegistry(map: Record<string, number>): void {
    try {
      writeFileSync(this.pidRegistryPath, JSON.stringify(map));
    } catch {
      /* registry is best effort */
    }
  }

  private rememberPid(runId: string, pid: number): void {
    const map = this.readPidRegistry();
    map[runId] = pid;
    this.writePidRegistry(map);
  }

  private forgetPid(runId: string): void {
    const map = this.readPidRegistry();
    if (map[runId] !== undefined) {
      delete map[runId];
      this.writePidRegistry(map);
    }
  }

  private makeId(): string {
    return `run_${Date.now().toString(36)}_${randomBytes(3).toString('hex')}`;
  }

  private makeEntry(record: RunRecord): RunEntry {
    return {
      record,
      events: [],
      summary: '',
      child: null,
      cancelRequested: false,
      timedOut: false,
      pid: null,
      logOffset: 0,
      timer: null,
    };
  }

  /** Policy the runner applies right now, clamped by what the store allows. */
  policy(): RunnerPolicy {
    const settings = this.store.getSettings();
    return {
      timeoutMinutes: settings.runTimeoutMinutes,
      retryLimit: settings.retryLimit,
      retryBackoffSeconds: settings.retryBackoffSeconds,
    };
  }

  queueState(): QueueState {
    const queue: RunRecord[] = [];
    for (const id of this.queue) {
      const run = this.store.getRun(id);
      if (run) queue.push(run);
    }
    return { paused: this.paused, policy: this.policy(), activeRun: this.activeRun(), queue };
  }

  /**
   * Pauses or resumes the queue. The running run keeps going — an operator who
   * pauses wants no *new* work, not a half-finished commit.
   */
  setPaused(paused: boolean): boolean {
    this.paused = this.store.setQueuePaused(paused);
    this.options.callbacks.onQueueState?.(this.queueState());
    if (!paused) this.pump();
    return this.paused;
  }

  isPaused(): boolean {
    return this.paused;
  }

  enqueue(suggestion: Suggestion, settings: Settings, cluster: Suggestion[]): RunRecord {
    const policy: RunnerPolicy = {
      timeoutMinutes: settings.runTimeoutMinutes,
      retryLimit: settings.retryLimit,
      retryBackoffSeconds: settings.retryBackoffSeconds,
    };
    return this.createRun(suggestion, cluster, {
      attempt: 1,
      retryOf: null,
      notBefore: null,
      timeoutMs: policy.timeoutMinutes * 60_000,
      maxAttempts: policy.retryLimit + 1,
    });
  }

  /**
   * Creates and enqueues a run. Retries and manual re-runs go through here too,
   * so a retry is a *visible new row* in the history instead of a second state
   * machine hidden inside a finished one.
   */
  private createRun(
    suggestion: Suggestion,
    cluster: Suggestion[],
    options: {
      attempt: number;
      retryOf: string | null;
      notBefore: number | null;
      timeoutMs: number;
      maxAttempts: number;
    },
  ): RunRecord {
    const settings = this.store.getSettings();
    const id = this.makeId();
    const createdAt = Date.now();
    const logPath = join(
      this.logDir,
      `suggestion-${suggestion.id}_${formatStamp(new Date(createdAt))}_a${options.attempt}.jsonl`,
    );
    const prediction = scopeForSuggestion(suggestion, cluster);
    const record: RunRecord = {
      id,
      suggestionId: suggestion.id,
      status: 'queued',
      sessionId: null,
      prompt: buildPrompt(suggestion, cluster, settings, this.options.projectRoot, prediction.scopes, options.attempt),
      exitCode: null,
      cost: null,
      tokensInput: null,
      tokensOutput: null,
      commitHash: null,
      resultSummary: '',
      createdAt,
      startedAt: null,
      finishedAt: null,
      logPath,
      attempt: options.attempt,
      maxAttempts: options.maxAttempts,
      retryOf: options.retryOf,
      notBefore: options.notBefore,
      timeoutMs: options.timeoutMs,
      scopes: prediction.scopes,
      scope: prediction.scopes[0] ?? null,
      note: null,
      scopeIssues: null,
    };
    this.store.createRun(record);
    this.store.setSuggestionRun(suggestion.id, id);
    this.entries.set(id, this.makeEntry(record));
    this.writeLogHeader(record, suggestion, settings, prediction);
    this.queue.push(id);
    const wait = options.notBefore && options.notBefore > Date.now()
      ? ` · startet frühestens ${new Date(options.notBefore).toLocaleTimeString('de-DE')}`
      : '';
    this.pushEvent(id, {
      t: Date.now(),
      kind: 'status',
      text: `In Warteschlange (Versuch ${record.attempt}/${record.maxAttempts}${wait})`,
    });
    if (prediction.reason) {
      this.pushEvent(id, { t: Date.now(), kind: 'status', text: `Scope: ${prediction.reason}` });
    }
    this.pump();
    return record;
  }

  /**
   * Manual retry of a finished run. `force` overrides the commit guard, which
   * exists so a run that already committed cannot produce a second commit for
   * the same suggestion.
   */
  retry(runId: string, opts: { force?: boolean } = {}): { ok: boolean; run?: RunRecord; error?: string } {
    const record = this.store.getRun(runId);
    if (!record) return { ok: false, error: 'Run nicht gefunden' };
    if (record.status === 'queued' || record.status === 'running') {
      return { ok: false, error: 'Run ist noch nicht abgeschlossen' };
    }
    // A successful run is not repeated: its work is done and its commit exists.
    // Re-running it would answer "what did the agent do for this suggestion?"
    // twice, which is exactly the ambiguity the retry guard exists to prevent.
    if (record.status === 'succeeded' && !opts.force) {
      return { ok: false, error: 'Der Run war erfolgreich — es gibt nichts zu wiederholen.' };
    }
    const suggestion = this.store.getSuggestion(record.suggestionId);
    if (!suggestion) return { ok: false, error: 'Vorschlag nicht gefunden' };
    if (this.isBusyForSuggestion(suggestion)) {
      return { ok: false, error: 'Für diesen Vorschlag läuft bereits ein Run.' };
    }
    if (!opts.force) {
      const guard = this.existingCommit(record);
      if (guard !== null) return { ok: false, error: guard };
    }
    const policy = this.policy();
    const run = this.createRun(suggestion, this.clusterOf(suggestion), {
      attempt: record.attempt + 1,
      retryOf: record.id,
      notBefore: null,
      timeoutMs: policy.timeoutMinutes * 60_000,
      maxAttempts: Math.max(record.attempt + 1, policy.retryLimit + 1),
    });
    return { ok: true, run };
  }

  /** Writes the metadata header (prompt, model, timestamp, scope) that starts every run log. */
  private writeLogHeader(
    record: RunRecord,
    suggestion: Suggestion,
    settings: Settings,
    prediction: { scopes: string[]; reason: string },
  ): void {
    const header = {
      type: 'run_meta',
      runId: record.id,
      suggestionId: suggestion.id,
      suggestionText: suggestion.text,
      category: suggestion.category,
      votes: suggestion.votes,
      author: suggestion.author,
      model: settings.model.trim() || '(Standard)',
      startedAt: new Date(record.createdAt).toISOString(),
      attempt: record.attempt,
      maxAttempts: record.maxAttempts,
      retryOf: record.retryOf,
      timeoutMs: record.timeoutMs,
      scope: { scopes: prediction.scopes, reason: prediction.reason },
      prompt: record.prompt,
    };
    try {
      writeFileSync(record.logPath, `${JSON.stringify(header)}\n`);
    } catch (err) {
      console.warn('[runner] konnte Run-Log nicht anlegen:', (err as Error).message);
    }
  }

  /** Appends a final result line (status, exit code, cost, summary) to the run log. */
  private appendLogResult(record: RunRecord, note?: string): void {
    const footer = {
      type: 'run_result',
      runId: record.id,
      status: record.status,
      exitCode: record.exitCode,
      cost: record.cost,
      tokensInput: record.tokensInput,
      tokensOutput: record.tokensOutput,
      commitHash: record.commitHash,
      finishedAt: record.finishedAt ? new Date(record.finishedAt).toISOString() : null,
      resultSummary: record.resultSummary,
      note: note ?? null,
    };
    try {
      appendFileSync(record.logPath, `${JSON.stringify(footer)}\n`);
    } catch {
      /* logging must never crash the run */
    }
  }

  /**
   * Cleans up after a server restart. A run that was active when the previous
   * process died is adopted when its opencode process is still alive, otherwise
   * its outcome is reconstructed from the run log and git history. Runs that
   * never started are put back into the queue so they are not silently lost.
   */
  private recover(): void {
    const pids = this.readPidRegistry();
    const adopted: string[] = [];
    const interrupted: string[] = [];
    for (const record of this.store.listRuns(500)) {
      if (record.status !== 'running') continue;
      const pid = pids[record.id] ?? findOpencodePid(record.suggestionId);
      if (pid !== null && isProcessAlive(pid)) {
        const entry = this.adoptEntry(record, pid);
        this.entries.set(record.id, entry);
        if (!this.activeId) this.activeId = record.id;
        this.watchOrphan(entry);
        adopted.push(record.id);
      } else {
        this.finalizeInterrupted(record);
        interrupted.push(record.id);
      }
    }
    for (const record of this.store.listRuns(500)) {
      if (record.status !== 'queued' || this.entries.has(record.id)) continue;
      this.entries.set(record.id, this.makeEntry(record));
      this.queue.push(record.id);
      this.pushEvent(record.id, { t: Date.now(), kind: 'status', text: 'Nach Server-Neustart erneut in die Warteschlange' });
    }
    // Keep only adopted processes in the registry; dead entries are dropped.
    const alive: Record<string, number> = {};
    for (const [id, entry] of this.entries) if (entry.pid !== null) alive[id] = entry.pid;
    this.writePidRegistry(alive);
    if (adopted.length > 0) console.log(`[runner] übernommene Runs: ${adopted.join(', ')}`);
    if (interrupted.length > 0) console.log(`[runner] nach Neustart aufgeräumte Runs: ${interrupted.join(', ')}`);
    this.pump();
  }

  /** Builds an entry for a run whose process survived a server restart. */
  private adoptEntry(record: RunRecord, pid: number): RunEntry {
    const entry = this.makeEntry(record);
    entry.pid = pid;
    try {
      const raw = readFileSync(record.logPath, 'utf8');
      entry.logOffset = raw.length;
      const events: RunEvent[] = [];
      for (const line of raw.split('\n')) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        try {
          const parsed = JSON.parse(trimmed) as Record<string, unknown>;
          if (parsed.type === 'run_meta' || parsed.type === 'run_result') continue;
          events.push(...mapOpencodeEvent(parsed));
        } catch {
          /* skip malformed line */
        }
      }
      entry.events = events.slice(-MAX_MEMORY_EVENTS);
      entry.summary = events
        .filter((event) => event.kind === 'text')
        .map((event) => event.text)
        .join('')
        .slice(-8000);
    } catch {
      /* log may not exist yet */
    }
    return entry;
  }

  /** Polls an adopted run: mirrors new log output and finalizes it once it exits. */
  private watchOrphan(entry: RunEntry): void {
    const pid = entry.pid;
    if (pid === null) {
      this.finishEntry(entry, 'Verwaister Run beendet', true);
      return;
    }
    entry.timer = setInterval(() => {
      this.tailLog(entry);
      if (isProcessAlive(pid)) return;
      if (entry.timer) {
        clearInterval(entry.timer);
        entry.timer = null;
      }
      this.tailLog(entry);
      if (entry.cancelRequested) {
        this.finalize(entry, null, 'Abgebrochen (verwaister Run)', 'cancelled');
      } else {
        this.finishEntry(entry, 'übernommen und abgeschlossen', false);
      }
    }, ORPHAN_POLL_MS);
    entry.timer.unref?.();
  }

  /** Mirrors newly appended log lines of an adopted run to the live event bus. */
  private tailLog(entry: RunEntry): void {
    try {
      const raw = readFileSync(entry.record.logPath, 'utf8');
      if (raw.length <= entry.logOffset) return;
      const chunk = raw.slice(entry.logOffset);
      entry.logOffset = raw.length;
      for (const line of chunk.split('\n')) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        let parsed: Record<string, unknown>;
        try {
          parsed = JSON.parse(trimmed) as Record<string, unknown>;
        } catch {
          continue;
        }
        if (parsed.type === 'run_meta' || parsed.type === 'run_result') continue;
        for (const event of mapOpencodeEvent(parsed)) {
          entry.events.push(event);
          if (entry.events.length > MAX_MEMORY_EVENTS) entry.events.splice(0, entry.events.length - MAX_MEMORY_EVENTS);
          this.options.callbacks.onEvent?.(entry.record.id, event);
        }
      }
    } catch {
      /* log may not exist yet */
    }
  }

  /** Adds up cost/tokens from the reconstructed events of a run. */
  private accumulateUsage(record: RunRecord, events: RunEvent[]): void {
    for (const event of events) {
      if (event.kind !== 'done' || !event.detail) continue;
      try {
        const meta = JSON.parse(event.detail) as { cost?: number; tokensInput?: number; tokensOutput?: number };
        if (typeof meta.cost === 'number') record.cost = (record.cost ?? 0) + meta.cost;
        if (typeof meta.tokensInput === 'number') record.tokensInput = (record.tokensInput ?? 0) + meta.tokensInput;
        if (typeof meta.tokensOutput === 'number') record.tokensOutput = (record.tokensOutput ?? 0) + meta.tokensOutput;
      } catch {
        /* ignore */
      }
    }
  }

  /**
   * Finalizes an adopted run once its process exited: success is detected via a
   * commit made after the run started, so a run that finished its work right
   * before the server restarted is still recorded as succeeded.
   */
  private finishEntry(entry: RunEntry, note: string, silent: boolean): void {
    const { record } = entry;
    if (record.status !== 'running') return;
    const events = readRunEvents(record.logPath);
    entry.events = events.slice(-MAX_MEMORY_EVENTS);
    entry.summary = events
      .filter((event) => event.kind === 'text')
      .map((event) => event.text)
      .join('')
      .slice(-8000);
    this.accumulateUsage(record, events);
    const commit = commitSince(record.startedAt, this.options.projectRoot, record.suggestionId);
    record.commitHash = commit;
    const succeeded = commit !== null;
    this.finalize(
      entry,
      succeeded ? 0 : null,
      succeeded ? `Server-Neustart: ${note}` : `Server-Neustart: ${note} – kein Commit gefunden`,
      succeeded ? 'succeeded' : 'failed',
      silent,
    );
  }

  /** Reconstructs a dead run at startup without firing callbacks or notifications. */
  private finalizeInterrupted(record: RunRecord): void {
    const entry = this.makeEntry(record);
    this.finishEntry(entry, 'aus Log/History rekonstruiert', true);
    this.forgetPid(record.id);
  }

  /**
   * Finalizes every running run whose process is gone. Exposed so the dashboard
   * can clean up stuck runs without restarting the server.
   */
  reconcileNow(): RunRecord[] {
    const pids = this.readPidRegistry();
    const fixed: RunRecord[] = [];
    for (const record of this.store.listRuns(500)) {
      if (record.status !== 'running' || this.entries.has(record.id)) continue;
      const pid = pids[record.id] ?? findOpencodePid(record.suggestionId);
      if (pid !== null && isProcessAlive(pid)) continue;
      this.finalizeInterrupted(record);
      fixed.push(this.store.getRun(record.id) ?? record);
    }
    if (fixed.length > 0) this.pump();
    return fixed;
  }

  /**
   * Starts the next queued run, unless the queue is paused or the head of the
   * queue is still inside its retry backoff.
   */
  private pump() {
    if (this.paused) return;
    if (this.activeId) return;
    const id = this.queue[0];
    if (!id) {
      this.clearWake();
      return;
    }
    const entry = this.entries.get(id);
    if (!entry) {
      this.queue.shift();
      this.pump();
      return;
    }
    const notBefore = entry.record.notBefore ?? 0;
    if (notBefore > Date.now()) {
      this.scheduleWake(notBefore);
      return;
    }
    this.clearWake();
    this.queue.shift();
    this.activeId = id;
    void this.start(entry);
  }

  private scheduleWake(at: number): void {
    if (this.wakeTimer && this.wakeAt !== null && this.wakeAt <= at) return;
    this.clearWake();
    const delay = Math.max(50, Math.min(at - Date.now(), MAX_SLEEP_MS));
    this.wakeAt = at;
    this.wakeTimer = setTimeout(() => {
      this.wakeTimer = null;
      this.wakeAt = null;
      this.pump();
    }, delay);
    this.wakeTimer.unref?.();
  }

  private clearWake(): void {
    if (!this.wakeTimer) return;
    clearTimeout(this.wakeTimer);
    this.wakeTimer = null;
    this.wakeAt = null;
  }

  /**
   * Supervisor tick: enforces the hard timeout of every running run.
   *
   * A timer per run would be the obvious implementation and the wrong one — a
   * run adopted after a restart has no timer, and the timeout has to survive the
   * restart. A deadline derived from `startedAt` and checked against the clock
   * is stateless, so a fresh server process applies exactly the same budget to
   * the run it inherited. Exposed for tests, which call it directly instead of
   * waiting out a real timeout.
   */
  tick(now: number = Date.now()): RunRecord[] {
    const expired: RunRecord[] = [];
    for (const entry of [...this.entries.values()]) {
      const { record } = entry;
      if (record.status !== 'running' || record.startedAt === null) continue;
      if (record.timeoutMs <= 0) continue;
      if (now - record.startedAt < record.timeoutMs) continue;
      this.expire(entry);
      expired.push(this.store.getRun(record.id) ?? record);
    }
    if (expired.length > 0) this.pump();
    return expired;
  }

  /**
   * Hard timeout: the child gets SIGTERM, then SIGKILL, and the run is marked
   * failed with the reason. A cancelled run stays cancelled — `finalize` only
   * ever moves a run out of `running`, and the close handler of the dying child
   * is a no-op afterwards.
   */
  private expire(entry: RunEntry): void {
    const { record } = entry;
    const budget = formatBudget(record.timeoutMs);
    const note = `Zeitüberschreitung nach ${budget} — Prozess beendet`;
    entry.timedOut = true;
    this.pushEvent(record.id, { t: Date.now(), kind: 'error', text: note });
    this.terminate(entry);
    this.finalize(entry, null, note, 'failed');
  }

  /** SIGTERM, then SIGKILL after a grace period. Works for own and adopted children. */
  private terminate(entry: RunEntry): void {
    const pid = entry.child?.pid ?? entry.pid;
    if (entry.child) entry.child.kill('SIGTERM');
    if (pid != null && !entry.child) {
      try {
        process.kill(pid, 'SIGTERM');
      } catch {
        /* already gone */
      }
    }
    if (pid == null) return;
    setTimeout(() => {
      if (!isProcessAlive(pid)) return;
      try {
        process.kill(pid, 'SIGKILL');
      } catch {
        /* already gone */
      }
    }, KILL_GRACE_MS).unref?.();
  }

  private async start(entry: RunEntry) {
    const { record } = entry;
    const settings = this.store.getSettings();
    const bin = findOpencodeBinary();
    const args = ['run', '--format', 'json', '--auto', '--title', `Vorschlag #${record.suggestionId}`];
    if (settings.model.trim()) args.push('--model', settings.model.trim());
    args.push(record.prompt);

    record.status = 'running';
    record.startedAt = Date.now();
    record.notBefore = null;
    this.store.updateRun(record);
    const suggestion = this.store.getSuggestion(record.suggestionId);
    if (suggestion) {
      this.store.updateSuggestionStatus(suggestion.id, 'implementing');
      this.options.callbacks.onSuggestionStatus?.(suggestion.id, 'implementing');
    }
    this.options.callbacks.onStarted?.(record, suggestion!);
    this.pushEvent(
      record.id,
      {
        t: Date.now(),
        kind: 'status',
        text: `Run gestartet mit ${bin}${record.timeoutMs > 0 ? ` · Zeitlimit ${formatBudget(record.timeoutMs)}` : ''}`,
      },
    );

    let child: RunnerChild;
    try {
      child = spawn(bin, args, {
        cwd: this.options.projectRoot,
        env: { ...process.env },
        stdio: ['ignore', 'pipe', 'pipe'],
      });
    } catch (err) {
      this.finalize(entry, null, `spawn fehlgeschlagen: ${(err as Error).message}`);
      return;
    }
    entry.child = child;
    entry.pid = child.pid ?? null;
    if (entry.pid !== null) this.rememberPid(record.id, entry.pid);

    let buffer = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk: string) => {
      buffer += chunk;
      let index = buffer.indexOf('\n');
      while (index >= 0) {
        const line = buffer.slice(0, index).trim();
        buffer = buffer.slice(index + 1);
        if (line) this.handleLine(entry, line);
        index = buffer.indexOf('\n');
      }
    });
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk: string) => {
      const text = chunk.trim();
      if (!text) return;
      this.pushEvent(record.id, { t: Date.now(), kind: 'info', text: text.slice(0, 500) });
    });
    child.on('error', (err) => {
      this.finalize(entry, null, `Fehler beim Starten von opencode: ${err.message}`);
    });
    child.on('close', (code, signal) => {
      if (buffer.trim()) this.handleLine(entry, buffer.trim());
      if (entry.timedOut) {
        // The timeout already wrote the outcome; the dying process must not
        // relabel a timeout as a cancellation.
        return;
      }
      if (entry.cancelRequested) {
        this.finalize(entry, code ?? null, `Abgebrochen (${signal ?? 'manuell'})`, 'cancelled');
      } else {
        this.finalize(entry, code);
      }
    });
  }

  private handleLine(entry: RunEntry, line: string) {
    try {
      appendFileSync(entry.record.logPath, `${line}\n`);
    } catch {
      /* logging must never crash the run */
    }
    let parsed: Record<string, unknown>;
    try {
      parsed = JSON.parse(line) as Record<string, unknown>;
    } catch {
      this.pushEvent(entry.record.id, { t: Date.now(), kind: 'info', text: line.slice(0, 500) });
      return;
    }
    const mapped = mapOpencodeEvent(parsed);
    for (const event of mapped) {
      if (event.kind === 'text') {
        entry.summary = `${entry.summary}${event.text}`.slice(-8000);
      }
      if (event.kind === 'done' && event.detail) {
        try {
          const meta = JSON.parse(event.detail) as {
            sessionId?: string;
            cost?: number;
            tokensInput?: number;
            tokensOutput?: number;
          };
          if (meta.sessionId) entry.record.sessionId = meta.sessionId;
          if (typeof meta.cost === 'number') entry.record.cost = (entry.record.cost ?? 0) + meta.cost;
          if (typeof meta.tokensInput === 'number') {
            entry.record.tokensInput = (entry.record.tokensInput ?? 0) + meta.tokensInput;
          }
          if (typeof meta.tokensOutput === 'number') {
            entry.record.tokensOutput = (entry.record.tokensOutput ?? 0) + meta.tokensOutput;
          }
        } catch {
          /* ignore */
        }
      }
      this.pushEvent(entry.record.id, event);
    }
  }

  private pushEvent(runId: string, event: RunEvent) {
    const entry = this.entries.get(runId);
    if (entry) {
      entry.events.push(event);
      if (entry.events.length > MAX_MEMORY_EVENTS) entry.events.splice(0, entry.events.length - MAX_MEMORY_EVENTS);
    }
    this.options.callbacks.onEvent?.(runId, event);
  }

  private finalize(
    entry: RunEntry,
    exitCode: number | null,
    note?: string,
    forceStatus?: RunRecord['status'],
    silent = false,
  ) {
    const { record } = entry;
    if (record.status === 'succeeded' || record.status === 'failed' || record.status === 'cancelled') return;
    if (entry.timer) {
      clearInterval(entry.timer);
      entry.timer = null;
    }
    if (entry.pid !== null) {
      this.forgetPid(record.id);
      entry.pid = null;
    }
    record.exitCode = exitCode;
    record.finishedAt = Date.now();
    if (forceStatus) record.status = forceStatus;
    else record.status = exitCode === 0 ? 'succeeded' : 'failed';
    // The reason is kept separately from the summary: the summary is the agent's
    // own text, and a timeout must stay visible even when the agent did say
    // something before it hung.
    record.note = note ?? (record.status === 'succeeded' ? 'ok' : `exit ${exitCode ?? '?'}`);
    if (record.status === 'succeeded' && record.commitHash === null) {
      const hash = spawnSync('git', ['-C', this.options.projectRoot, 'log', '-1', '--pretty=format:%h'], {
        encoding: 'utf8',
      });
      if (hash.status === 0) record.commitHash = hash.stdout.trim() || null;
    }
    const fallback =
      record.status === 'succeeded'
        ? 'Erfolgreich abgeschlossen.'
        : note ?? `Fehlgeschlagen${exitCode != null ? ` (Exit ${exitCode})` : ''}.`;
    record.resultSummary = shortSummary(entry.summary, fallback);
    record.scopeIssues = this.scopeIssuesOf(record, entry.events);
    this.store.updateRun(record);
    this.appendLogResult(record, note);
    const suggestion = this.store.getSuggestion(record.suggestionId);
    if (suggestion) {
      const status: SuggestionStatus = record.status === 'succeeded' ? 'implemented' : record.status === 'cancelled' ? 'approved' : 'failed';
      this.store.updateSuggestionStatus(suggestion.id, status);
      if (!silent) this.options.callbacks.onSuggestionStatus?.(suggestion.id, status);
    }
    this.pushEvent(record.id, {
      t: Date.now(),
      kind: 'done',
      text: note ?? (record.status === 'succeeded' ? 'Erfolgreich abgeschlossen' : `Fehlgeschlagen (Exit ${exitCode})`),
    });
    const retry = this.scheduleRetry(entry);
    if (this.activeId === record.id) this.activeId = null;
    if (silent) return;
    this.options.callbacks.onFinished?.(record, suggestion!);
    if (retry) this.options.callbacks.onQueueState?.(this.queueState());
    this.pump();
  }

  /** Compact JSON of what the run touched outside its scope, or null when clean. */
  private scopeIssuesOf(record: RunRecord, events: RunEvent[]): string | null {
    try {
      const source = events.length > 0 ? events : readRunEvents(record.logPath);
      const audit = auditScope({ runId: record.id, scopes: record.scopes, events: source });
      if (audit.ok && audit.shared.length === 0 && audit.notes.length === 0) return null;
      return JSON.stringify({
        violations: audit.violations,
        shared: audit.shared,
        unclaimed: audit.unclaimed,
        notes: audit.notes,
        checked: audit.checked,
      });
    } catch {
      // An audit problem must never cost a run its result.
      return null;
    }
  }

  /**
   * Queues the next attempt of a failed run when the policy allows it.
   *
   * The commit guard is the reason retries exist as separate rows and not as a
   * silent re-run: if the failed attempt already committed work for this
   * suggestion, repeating it would produce a second commit for the same order —
   * the "did the agent do anything" question would then have two answers.
   */
  private scheduleRetry(entry: RunEntry): RunRecord | null {
    const { record } = entry;
    if (record.status !== 'failed') return null;
    if (record.attempt >= record.maxAttempts) return null;
    const guard = this.existingCommit(record);
    if (guard !== null) {
      this.pushEvent(record.id, { t: Date.now(), kind: 'status', text: `Kein Wiederholungsversuch: ${guard}` });
      return null;
    }
    const suggestion = this.store.getSuggestion(record.suggestionId);
    if (!suggestion) return null;
    const policy = this.policy();
    const next = this.createRun(suggestion, this.clusterOf(suggestion), {
      attempt: record.attempt + 1,
      retryOf: record.id,
      notBefore: Date.now() + this.backoffMs(record.attempt, policy.retryBackoffSeconds),
      timeoutMs: policy.timeoutMinutes * 60_000,
      maxAttempts: record.maxAttempts,
    });
    this.pushEvent(
      record.id,
      {
        t: Date.now(),
        kind: 'status',
        text: `Wiederholung ${next.attempt}/${next.maxAttempts} geplant · ${next.id}`,
      },
    );
    return next;
  }

  /** Doubling backoff, capped. Zero when the operator disabled it. */
  private backoffMs(attempt: number, baseSeconds: number): number {
    if (baseSeconds <= 0) return 0;
    const raw = baseSeconds * 2 ** Math.max(0, attempt - 1);
    return Math.min(MAX_BACKOFF_MS, raw) * 1000;
  }

  /**
   * Why a run must not be repeated, or null when repeating it is safe. Looks at
   * the whole attempt chain, not just this run: attempt 3 must not re-run work
   * that attempt 1 already committed.
   */
  private existingCommit(record: RunRecord): string | null {
    const chainStart = this.chainStart(record);
    if (chainStart === null) return null;
    const commit = commitSince(chainStart, this.options.projectRoot, record.suggestionId);
    return commit === null ? null : `es gibt bereits einen Commit (${commit}) für Vorschlag #${record.suggestionId}`;
  }

  /** Start time of the first attempt in this run's chain, i.e. `createdAt` of the root. */
  private chainStart(record: RunRecord): number | null {
    let cursor: RunRecord = record;
    const guard = new Set<string>([record.id]);
    while (cursor.retryOf) {
      const previous: RunRecord | null = this.store.getRun(cursor.retryOf);
      if (!previous || guard.has(previous.id)) break;
      guard.add(previous.id);
      cursor = previous;
    }
    return cursor.startedAt ?? cursor.createdAt;
  }

  /** All suggestions of the same cluster — the siblings an agent is told about. */
  private clusterOf(suggestion: Suggestion): Suggestion[] {
    const all = this.store.listSuggestions();
    const canonical = suggestion.canonicalId ?? suggestion.id;
    return all.filter((s) => (s.canonicalId ?? s.id) === canonical);
  }

  cancel(runId: string): { ok: boolean; error?: string } {
    const entry = this.entries.get(runId);
    if (!entry) return { ok: false, error: 'Run nicht gefunden' };
    if (entry.record.status === 'queued') {
      this.queue = this.queue.filter((id) => id !== runId);
      this.clearWake();
      this.finalize(entry, null, 'Vor dem Start abgebrochen', 'cancelled');
      return { ok: true };
    }
    if (this.activeId === runId && entry.child) {
      entry.cancelRequested = true;
      this.terminate(entry);
      return { ok: true };
    }
    // Adopted orphan: the process outlived its server, so kill it by PID.
    if (entry.pid !== null && isProcessAlive(entry.pid)) {
      entry.cancelRequested = true;
      this.terminate(entry);
      return { ok: true };
    }
    return { ok: false, error: 'Run ist nicht aktiv' };
  }

  getRunView(id: string): RunView | null {
    const record = this.store.getRun(id);
    if (!record) return null;
    const entry = this.entries.get(id);
    const alive = entry ? entry.pid !== null || (entry.child !== null && entry.child.exitCode === null) : false;
    if (entry) {
      return {
        ...record,
        events: entry.events,
        summary: entry.summary,
        alive,
        scopeAudit: this.auditOf(record, entry.events),
      };
    }
    const events = readRunEvents(record.logPath);
    const summary = events
      .filter((event) => event.kind === 'text')
      .map((event) => event.text)
      .join('')
      .slice(-8000);
    return { ...record, events, summary, alive, scopeAudit: this.auditOf(record, events) };
  }

  /**
   * Scope audit for a run, memoized on the log size. A finished log no longer
   * grows, so a polled dashboard reads the result from memory instead of
   * re-parsing a log that can be several megabytes.
   */
  auditScopeOf(runId: string): ScopeAudit | null {
    const record = this.store.getRun(runId);
    if (!record) return null;
    const entry = this.entries.get(runId);
    return this.auditOf(record, entry?.events);
  }

  private auditOf(record: RunRecord, liveEvents: RunEvent[] | undefined): ScopeAudit | null {
    let size = -1;
    try {
      size = statSync(record.logPath).size;
    } catch {
      size = -1;
    }
    const finished = record.status === 'succeeded' || record.status === 'failed' || record.status === 'cancelled';
    const key = `${record.status}:${record.finishedAt ?? 0}:${size}`;
    const hit = this.auditCache.get(record.id);
    // While a run is going, its log grows, so the key changes on every poll.
    // Re-reading it more than every 30 s buys nothing for a warning.
    if (hit && hit.key === key && (finished || Date.now() - hit.at < AUDIT_THROTTLE_MS)) return hit.audit;
    const events = liveEvents && liveEvents.length > 0 ? liveEvents : readRunEvents(record.logPath);
    const audit = auditScope({ runId: record.id, scopes: record.scopes, events });
    this.auditCache.set(record.id, { key, audit, at: Date.now() });
    return audit;
  }

  getEvents(id: string): RunEvent[] {
    return this.entries.get(id)?.events ?? [];
  }

  activeRun(): RunRecord | null {
    if (!this.activeId) return null;
    return this.store.getRun(this.activeId);
  }

  isBusyForSuggestion(suggestion: Suggestion): boolean {
    if (!suggestion.runId) return false;
    const run = this.store.getRun(suggestion.runId);
    return !!run && (run.status === 'queued' || run.status === 'running');
  }

  listSuggestionRuns(suggestionId: number): RunRecord[] {
    return this.store.listRuns(200).filter((r) => r.suggestionId === suggestionId);
  }
}

function readRunEvents(logPath: string): RunEvent[] {
  try {
    const raw = readFileSync(logPath, 'utf8');
    const events: RunEvent[] = [];
    for (const line of raw.split('\n')) {
      if (!line.trim()) continue;
      try {
        events.push(...mapOpencodeEvent(JSON.parse(line) as Record<string, unknown>));
      } catch {
        /* skip malformed line */
      }
    }
    return events.slice(-3000);
  } catch {
    return [];
  }
}

export function mapOpencodeEvent(parsed: Record<string, unknown>): RunEvent[] {
  const type = parsed.type as string;
  const part = (parsed.part ?? {}) as Record<string, unknown>;
  const t = typeof parsed.timestamp === 'number' ? parsed.timestamp : Date.now();
  switch (type) {
    case 'text': {
      const text = typeof part.text === 'string' ? part.text : '';
      if (!text.trim()) return [];
      return [{ t, kind: 'text', text }];
    }
    case 'tool':
    case 'tool_use': {
      const tool = typeof part.tool === 'string' ? part.tool : 'tool';
      const state = (part.state ?? {}) as Record<string, unknown>;
      const status = typeof state.status === 'string' ? state.status : 'running';
      const title = typeof state.title === 'string' ? state.title : describeToolInput(state.input);
      const output = typeof state.output === 'string' ? state.output.slice(0, MAX_DETAIL) : undefined;
      const error = typeof state.error === 'string' ? state.error : undefined;
      const events: RunEvent[] = [
        { t, kind: 'tool', tool, text: `${tool} · ${status}${title ? ` — ${title}` : ''}` },
      ];
      if (status === 'completed' && output) events.push({ t, kind: 'info', text: output, tool, detail: output });
      if (status === 'error') events.push({ t, kind: 'error', text: error ?? 'Tool-Fehler', tool });
      return events;
    }
    case 'step_finish': {
      const tokens = (part.tokens ?? {}) as Record<string, unknown>;
      const cost = typeof part.cost === 'number' ? part.cost : undefined;
      const input = typeof tokens.input === 'number' ? tokens.input : 0;
      const output = typeof tokens.output === 'number' ? tokens.output : 0;
      const text = `Schritt beendet · tokens in/out: ${input}/${output}${cost != null ? ` · $${cost.toFixed(4)}` : ''}`;
      return [
        {
          t,
          kind: 'done',
          text,
          detail: JSON.stringify({ cost, tokensInput: input, tokensOutput: output }),
        },
      ];
    }
    case 'error': {
      const err = (part.error ?? parsed.error ?? {}) as Record<string, unknown>;
      const data = (err.data ?? {}) as Record<string, unknown>;
      const message =
        (typeof data.message === 'string' && data.message) ||
        (typeof err.message === 'string' && err.message) ||
        JSON.stringify(err).slice(0, 500);
      return [{ t, kind: 'error', text: message }];
    }
    default:
      return [];
  }
}

function describeToolInput(input: unknown): string {
  if (!input || typeof input !== 'object') return '';
  const obj = input as Record<string, unknown>;
  const candidate = obj.description ?? obj.command ?? obj.filePath ?? obj.pattern ?? obj.query;
  if (typeof candidate === 'string') return candidate.slice(0, 200);
  return '';
}
