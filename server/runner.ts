import { spawn, spawnSync, type ChildProcessByStdio } from 'node:child_process';
import { EventEmitter } from 'node:events';
import type { Readable } from 'node:stream';
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import type {
  RunEvent,
  RunRecord,
  RunView,
  Settings,
  Suggestion,
  SuggestionStatus,
  SuggestionView,
} from '../src/shared/types';
import type { Store } from './db';

export interface RunnerCallbacks {
  onStarted?: (run: RunRecord, suggestion: Suggestion) => void;
  onEvent?: (runId: string, event: RunEvent) => void;
  onFinished?: (run: RunRecord, suggestion: Suggestion) => void;
  onSuggestionStatus?: (suggestionId: number, status: SuggestionStatus) => void;
}

type RunnerChild = ChildProcessByStdio<null, Readable, Readable>;

interface RunEntry {
  record: RunRecord;
  events: RunEvent[];
  summary: string;
  child: RunnerChild | null;
  cancelRequested: boolean;
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
 * Newest commit of the given suggestion whose commit time is at or after
 * `startedAt`, or null when there is no such commit. Used to reconstruct whether
 * an interrupted run managed to finish its work before its server process died.
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
  return Number.isFinite(timestamp) && timestamp >= startedAt ? hash : null;
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

export function buildPrompt(suggestion: Suggestion, cluster: Suggestion[], settings: Settings, projectRoot: string): string {
  const siblings = cluster.filter((s) => s.id !== suggestion.id);
  const siblingBlock = siblings.length
    ? `\nAndere Spieler haben sehr ähnliche Vorschläge gemacht (gleicher Cluster, berücksichtige sie alle):\n${siblings
        .map((s) => `- #${s.id}: ${s.text}`)
        .join('\n')}\n`
    : '';
  const extra = settings.extraInstructions.trim()
    ? `\nZusätzliche Anweisungen des Betreibers:\n${settings.extraInstructions.trim()}\n`
    : '';
  return `Du arbeitest im Repository "${projectRoot}" (Godot-Spiel "Singular 80" für Android mit Fastify-Backend und Web-Dashboard).

AUFGABE: Setze den folgenden spieler-eingereichten Vorschlag um.

Vorschlag #${suggestion.id} [Kategorie: ${suggestion.category}, Stimmen: ${suggestion.votes}]:
"""
${suggestion.text}
"""
${siblingBlock}REGELN:
1. Arbeite ausschließlich in diesem Repository. Lies zuerst AGENTS.md für Struktur und Erweiterungspunkte.
2. Das Spiel liegt in godot/ (GDScript, Godot 4.5). Server/Dashboard unter server/ und src/ sind Web-only und bleiben unverändert.
3. Bevorzuge reine Datenänderungen in content/*.json (Gegner, Waffen, Upgrades, Modi, Mechaniken) — sie werden beim Start der App geladen und wirken ohne Neubau.
4. Für neue Code-Mechaniken: lege eine Datei unter godot/src/core/logic/mechanics/<id>.gd an und registriere sie in godot/src/core/logic/mechanics/mechanics_index.gd. Halte dich an das Mechanic-Interface dort.
5. Performance ist wichtig: keine Allokationen pro Frame, vorhandene Pools nutzen, Entity-Limits beachten. Das Spiel muss flüssig auf Handy und Tablet laufen.
6. Touch-Steuerung ist Pflicht: jedes Spiel muss per virtuellem Stick und Buttons bedienbar sein, Tastatur ist optional.
7. Prüfe deine Änderung mit: "npm run typecheck" und "npm test". Danach baue die Godot-App neu: "npm run godot:import" und "npm run godot:check".
8. Committe am Ende alles mit:
   git add -A && git commit -m "feat(suggestion-${suggestion.id}): <kurze Beschreibung>"
9. Wenn der Vorschlag nicht sinnvoll umsetzbar ist, mache die kleinste vernünftige Verbesserung im Sinne des Vorschlags und erkläre das.
10. Antworte am Ende mit einer kurzen Zusammenfassung auf Deutsch (was geändert wurde, welche Dateien, wie getestet).
${extra}`;
}

export class Runner {
  private entries = new Map<string, RunEntry>();
  private queue: string[] = [];
  private activeId: string | null = null;

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
    this.recover();
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
    return { record, events: [], summary: '', child: null, cancelRequested: false, pid: null, logOffset: 0, timer: null };
  }

  enqueue(suggestion: Suggestion, settings: Settings, cluster: Suggestion[]): RunRecord {
    const id = this.makeId();
    const createdAt = Date.now();
    const logPath = join(this.logDir, `suggestion-${suggestion.id}_${formatStamp(new Date(createdAt))}.jsonl`);
    const record: RunRecord = {
      id,
      suggestionId: suggestion.id,
      status: 'queued',
      sessionId: null,
      prompt: buildPrompt(suggestion, cluster, settings, this.options.projectRoot),
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
    };
    this.store.createRun(record);
    this.store.setSuggestionRun(suggestion.id, id);
    this.entries.set(id, this.makeEntry(record));
    this.writeLogHeader(record, suggestion, settings);
    this.queue.push(id);
    this.pushEvent(id, { t: Date.now(), kind: 'status', text: 'In Warteschlange' });
    this.pump();
    return record;
  }

  /** Writes the metadata header (prompt, model, timestamp) that starts every run log. */
  private writeLogHeader(record: RunRecord, suggestion: Suggestion, settings: Settings): void {
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

  private pump() {
    if (this.activeId) return;
    const id = this.queue.shift();
    if (!id) return;
    const entry = this.entries.get(id);
    if (!entry) return;
    this.activeId = id;
    void this.start(entry);
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
    this.store.updateRun(record);
    const suggestion = this.store.getSuggestion(record.suggestionId);
    if (suggestion) {
      this.store.updateSuggestionStatus(suggestion.id, 'implementing');
      this.options.callbacks.onSuggestionStatus?.(suggestion.id, 'implementing');
    }
    this.options.callbacks.onStarted?.(record, suggestion!);
    this.pushEvent(record.id, { t: Date.now(), kind: 'status', text: `Run gestartet mit ${bin}` });

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
    if (this.activeId === record.id) this.activeId = null;
    if (silent) return;
    this.options.callbacks.onFinished?.(record, suggestion!);
    this.pump();
  }

  cancel(runId: string): { ok: boolean; error?: string } {
    const entry = this.entries.get(runId);
    if (!entry) return { ok: false, error: 'Run nicht gefunden' };
    if (entry.record.status === 'queued') {
      this.queue = this.queue.filter((id) => id !== runId);
      this.finalize(entry, null, 'Vor dem Start abgebrochen', 'cancelled');
      return { ok: true };
    }
    if (this.activeId === runId && entry.child) {
      entry.cancelRequested = true;
      entry.child.kill('SIGTERM');
      setTimeout(() => {
        if (entry.child && entry.child.exitCode === null) entry.child.kill('SIGKILL');
      }, 4000);
      return { ok: true };
    }
    // Adopted orphan: the process outlived its server, so kill it by PID.
    if (entry.pid !== null && isProcessAlive(entry.pid)) {
      entry.cancelRequested = true;
      try {
        process.kill(entry.pid, 'SIGTERM');
      } catch {
        /* already gone */
      }
      const pid = entry.pid;
      setTimeout(() => {
        if (isProcessAlive(pid)) {
          try {
            process.kill(pid, 'SIGKILL');
          } catch {
            /* already gone */
          }
        }
      }, 4000);
      return { ok: true };
    }
    return { ok: false, error: 'Run ist nicht aktiv' };
  }

  getRunView(id: string): RunView | null {
    const record = this.store.getRun(id);
    if (!record) return null;
    const entry = this.entries.get(id);
    const alive = entry ? entry.pid !== null || (entry.child !== null && entry.child.exitCode === null) : false;
    if (entry) return { ...record, events: entry.events, summary: entry.summary, alive };
    const events = readRunEvents(record.logPath);
    const summary = events
      .filter((event) => event.kind === 'text')
      .map((event) => event.text)
      .join('')
      .slice(-8000);
    return { ...record, events, summary, alive };
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
