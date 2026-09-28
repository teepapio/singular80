#!/usr/bin/env node
/**
 * One `git worktree` per agent, so two agents stop sharing a directory.
 *
 *   node scripts/worktree.mjs list                 # every agent branch + its state
 *   node scripts/worktree.mjs new suggestion-14    # worktree + branch, import done
 *   node scripts/worktree.mjs path suggestion-14    # where it lives, for a `cd`
 *   node scripts/worktree.mjs import suggestion-14  # re-run the Godot import
 *   node scripts/worktree.mjs remove suggestion-14  # refuse a dirty one
 *   node scripts/worktree.mjs prune                # drop what is merged and clean
 *
 * Why a worktree and not just a branch: a branch only names a line of history.
 * Two agents in ONE directory cannot both sit on their own branch — the second
 * `git switch` moves the files under the first one's feet — so the isolation has
 * to be a second checkout. Measured on this repository: 56 MB of checkout plus
 * 11 s of import per lane, which is cheaper than one lost commit.
 *
 * The worktrees live OUTSIDE the repository. Inside it they would need a
 * `.gitignore` entry, a stale directory would show up in `git status` of the
 * shared tree, and a recursive clean could delete a lane that is still running.
 */
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

/** Everything an agent works on is a branch under this prefix. */
export const AGENT_PREFIX = 'agent/';

/**
 * Branch names go into paths and into `git worktree add -b`, so they are
 * reduced to what is safe in both. `suggestion-14`, `merge-gate`, `wt/1` are
 * fine; a space or a colon in a label would produce a worktree git cannot
 * remove again.
 */
export function sanitizeLabel(label) {
  const clean = String(label)
    .trim()
    .replace(/^agent\//, '')
    .replace(/[^A-Za-z0-9._/-]+/g, '-')
    .replace(/^[./-]+/, '')
    .replace(/-+$/, '');
  if (!clean) throw new Error('Leerer Name — ein Worktree braucht einen Branch-Namen.');
  if (clean.includes('..')) throw new Error(`Name enthält "..": ${label}`);
  return clean;
}

/** `suggestion-14` → `agent/suggestion-14`. */
export function agentBranch(label) {
  return `${AGENT_PREFIX}${sanitizeLabel(label)}`;
}

/** The inverse, for messages: `agent/suggestion-14` → `suggestion-14`. */
export function labelOf(branch) {
  return branch.startsWith(AGENT_PREFIX) ? branch.slice(AGENT_PREFIX.length) : branch;
}

/**
 * Where the worktrees go. `S80_WORKTREE_DIR` moves them (a fast disk, a tmpfs
 * for a throwaway lane); the default keeps them next to the other per-user state
 * of the same project.
 */
export function worktreeRoot() {
  const override = process.env.S80_WORKTREE_DIR?.trim();
  if (override) return resolve(override);
  return join(homedir(), '.local', 'share', 'singular80', 'worktrees');
}

/** The checkout of one branch. Slashes become directories, so `wt/1` nests. */
export function worktreePath(label, base = worktreeRoot()) {
  return join(base, sanitizeLabel(label));
}

/**
 * Generated files. They are written by `sync-content.mjs` and `locale.mjs sync`
 * from the sources, so a merge must never try to reconcile two versions of
 * them: the gate resets them to the base and regenerates once, which is both
 * cheaper and the only way the result is guaranteed to match its sources.
 */
export const DERIVED_MIRRORS = ['godot/assets/content', 'godot/assets/locale'];

/** Godot writes `.uid` files next to every script it imports. */
export function godotDir(worktree) {
  return join(worktree, 'godot');
}

/* ------------------------------------------------------------------ git --- */

/** `git` with a bound: a git that never answers must not freeze the caller. */
function git(cwd, args, timeoutMs = 30_000) {
  const res = spawnSync('git', ['-C', cwd, ...args], {
    encoding: 'utf8',
    timeout: timeoutMs,
    killSignal: 'SIGKILL',
    env: { ...process.env, GIT_TERMINAL_PROMPT: '0' },
  });
  const stderr = (res.stderr ?? '').trim();
  return {
    ok: res.status === 0,
    out: (res.stdout ?? '').trim(),
    err: res.error ? res.error.message : res.signal ? `Signal ${res.signal}` : stderr || `exit ${res.status}`,
    code: res.status,
  };
}

/**
 * `git worktree list --porcelain`, parsed. Pure, so the parsing is testable
 * without a repository — the format is one stanza per worktree, `worktree`/
 * `HEAD`/`branch` (or `detached`), stanzas separated by a blank line.
 */
export function parseWorktreeList(text) {
  const out = [];
  let current = null;
  for (const line of String(text).split('\n')) {
    if (line.trim() === '') {
      if (current) out.push(current);
      current = null;
      continue;
    }
    const space = line.indexOf(' ');
    const key = space === -1 ? line : line.slice(0, space);
    const value = space === -1 ? '' : line.slice(space + 1);
    if (key === 'worktree') current = { path: value, head: null, branch: null, detached: false };
    else if (!current) continue;
    else if (key === 'HEAD') current.head = value;
    else if (key === 'branch') current.branch = value.replace(/^refs\/heads\//, '');
    else if (key === 'detached') current.detached = true;
  }
  if (current) out.push(current);
  return out;
}

/**
 * `git branch --list agent/*` → the branch names, with the checked-out marker
 * (`* `) stripped. A branch that is checked out in a worktree comes back with
 * the marker, and the marker is the only thing that says the branch is in use.
 */
export function parseBranchList(text) {
  return String(text)
    .split('\n')
    .map((l) => l.replace(/^[*+]\s+/, '').trim())
    .filter((l) => l.startsWith(AGENT_PREFIX));
}

/** Uncommitted changes in a checkout, as paths. */
export function dirtyFiles(cwd) {
  // Not through `git()`: that trims its output, and trimming eats the leading
  // status column of the *first* porcelain line — ` M README.md` became
  // `M README.md`, and slicing three characters off that names `EADME.md`.
  const res = spawnSync('git', ['-C', cwd, 'status', '--porcelain'], { encoding: 'utf8', timeout: 20_000 });
  if (res.status !== 0) return [];
  return (res.stdout ?? '')
    .split('\n')
    .filter((l) => l.trim() !== '')
    .map((l) => l.slice(3).trim())
    .filter(Boolean);
}

/**
 * True when the branch has nothing left to give: it is reachable from `base`
 * *and* contributes no commit of its own.
 *
 * Both halves are needed. A branch created at `HEAD` and never committed to is
 * an ancestor of `main` by definition, so the first half alone would call every
 * freshly created lane "merged" and the gate would skip exactly the work it
 * exists to merge.
 */
export function isMergedInto(repoRoot, branch, base = 'main') {
  const res = spawnSync('git', ['-C', repoRoot, 'merge-base', '--is-ancestor', branch, base], {
    encoding: 'utf8',
    timeout: 15_000,
  });
  if (res.status !== 0) return false;
  const own = spawnSync('git', ['-C', repoRoot, 'rev-list', '--count', `${base}..${branch}`], {
    encoding: 'utf8',
    timeout: 15_000,
  });
  return (own.stdout ?? '').trim() === '0';
}

/** Commits on the branch that `base` does not have. */
export function ownCommits(repoRoot, branch, base = 'main') {
  const res = spawnSync('git', ['-C', repoRoot, 'rev-list', '--count', `${base}..${branch}`], {
    encoding: 'utf8',
    timeout: 15_000,
  });
  const n = Number((res.stdout ?? '').trim());
  return Number.isFinite(n) ? n : 0;
}

/**
 * Every agent branch, with the state a person needs before touching it.
 *
 * A branch without a worktree is normal: a crashed runner leaves one behind,
 * and it is the work that must not be lost — so it is listed, not cleaned.
 */
export function listAgentWorktrees(repoRoot = root) {
  const worktrees = parseWorktreeList(
    spawnSync('git', ['-C', repoRoot, 'worktree', 'list', '--porcelain'], { encoding: 'utf8', timeout: 20_000 }).stdout ?? '',
  );
  const branches = parseBranchList(
    spawnSync('git', ['-C', repoRoot, 'branch', '--list', `${AGENT_PREFIX}*`], { encoding: 'utf8', timeout: 20_000 }).stdout ?? '',
  );
  const byBranch = new Map();
  for (const w of worktrees) {
    if (w.branch && w.branch.startsWith(AGENT_PREFIX)) byBranch.set(w.branch, w);
  }
  const names = new Set([...branches, ...byBranch.keys()]);
  return [...names].sort().map((branch) => {
    const entry = byBranch.get(branch) ?? null;
    const path = entry ? entry.path : worktreePath(labelOf(branch));
    const registered = entry !== null;
    const exists = existsSync(path);
    const dirty = registered && exists ? dirtyFiles(path) : [];
    const commits = ownCommits(repoRoot, branch);
    return {
      branch,
      label: labelOf(branch),
      path,
      registered,
      exists,
      head: entry ? entry.head : null,
      dirty,
      clean: dirty.length === 0,
      commits,
      /** A branch nobody committed to: it has nothing to merge, either way. */
      empty: commits === 0,
      merged: isMergedInto(repoRoot, branch),
    };
  });
}

/* --------------------------------------------------------------- create --- */

/**
 * The Godot import of a fresh checkout.
 *
 * Measured on this project: 11 s and 57 MB of `godot/.godot`, without which the
 * first `--headless` run in that worktree cannot resolve a single texture. The
 * retry is not decoration: the first import in a brand-new worktree aborted with
 * a core dump on this machine and succeeded unchanged on the second try, and a
 * lane that dies there looks exactly like an agent that failed to start.
 */
export function importGodot(worktree, { log = () => {}, attempts = 2 } = {}) {
  const dir = godotDir(worktree);
  if (!existsSync(dir)) return { ok: false, reason: `kein Godot-Projekt in ${worktree}` };
  const binary = process.env.GODOT_BIN?.trim() || 'godot';
  let last = '';
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    const res = spawnSync(binary, ['--headless', '--path', dir, '--import'], {
      encoding: 'utf8',
      timeout: 900_000,
      killSignal: 'SIGKILL',
    });
    if (res.status === 0) {
      log(`Import fertig (${attempt}. Versuch).`);
      return { ok: true, attempt };
    }
    last = res.error ? res.error.message : (res.stderr ?? '').trim().split('\n').pop() || `exit ${res.status}`;
    if (attempt < attempts) log(`Import abgebrochen (${last}) — zweiter Versuch.`);
  }
  return { ok: false, reason: last || 'unbekannt' };
}

/**
 * Creates the checkout for one agent.
 *
 * `base` defaults to `HEAD`, which is what makes the lane reproducible: the
 * worktree is a snapshot of the tree the moment the lane started, so a commit
 * in the shared tree afterwards cannot change what this agent is looking at.
 */
export function createWorktree(label, { repoRoot = root, base = 'HEAD', doImport = true, log = () => {} } = {}) {
  const branch = agentBranch(label);
  const path = worktreePath(label);
  const existing = listAgentWorktrees(repoRoot).find((w) => w.branch === branch);
  if (existing?.registered) {
    if (dirtyFiles(path).length > 0) {
      return { ok: false, branch, path, reason: `Worktree existiert und ist nicht sauber (${dirtyFiles(path).join(', ')})` };
    }
    const imported = doImport ? importGodot(path, { log }) : { ok: true, skipped: true };
    return { ok: imported.ok, branch, path, reused: true, import: imported };
  }
  if (existing) {
    // The branch is there but its checkout is gone: a crashed run, or a stale
    // admin entry. Refuse rather than delete — the commits on it may be the only
    // copy of a finished piece of work.
    return { ok: false, branch, path, reason: `Branch ${branch} existiert, aber ohne Checkout — erst prüfen` };
  }
  mkdirSync(dirname(path), { recursive: true });
  const added = git(repoRoot, ['worktree', 'add', '-b', branch, path, base]);
  if (!added.ok) {
    return { ok: false, branch, path, reason: added.err };
  }
  log(`Worktree ${path} (${branch} ab ${base}).`);
  const imported = doImport ? importGodot(path, { log }) : { ok: true, skipped: true };
  if (!imported.ok) {
    return { ok: false, branch, path, reason: `Import fehlgeschlagen: ${imported.reason}` };
  }
  return { ok: true, branch, path, reused: false, import: imported };
}

/* --------------------------------------------------------------- remove --- */

/**
 * Removes the checkout, and with `--delete-branch` the branch too.
 *
 * A dirty worktree is refused: that is uncommitted work, and the one command in
 * this file that could throw it away is the one that must ask twice. `--force`
 * is the answer, typed by a person who knows what is in there.
 */
export function removeWorktree(label, { repoRoot = root, force = false, deleteBranch = false } = {}) {
  const branch = agentBranch(label);
  const entry = listAgentWorktrees(repoRoot).find((w) => w.branch === branch);
  if (!entry) return { ok: false, branch, reason: `kein Worktree für ${branch}` };
  if (entry.registered && !entry.clean && !force) {
    return { ok: false, branch, reason: `nicht sauber: ${entry.dirty.join(', ')} — erst committen oder --force` };
  }
  if (entry.registered) {
    const removed = git(repoRoot, ['worktree', 'remove', force ? '--force' : '--', entry.path]);
    if (!removed.ok) return { ok: false, branch, reason: removed.err };
  } else if (entry.exists) {
    rmSync(entry.path, { recursive: true, force: true });
  }
  let branchDeleted = false;
  if (deleteBranch) {
    // `-D` because an unmerged branch is exactly the case where somebody asks
    // for this: the worktree is gone and the decision has been made.
    const res = git(repoRoot, ['branch', deleteBranch === 'force' ? '-D' : '-d', branch]);
    branchDeleted = res.ok;
    if (!res.ok) return { ok: false, branch, reason: `Worktree weg, Branch nicht: ${res.err}` };
  }
  return { ok: true, branch, branchDeleted };
}

/**
 * Drops the checkouts whose branch is already in `main` and that have nothing
 * uncommitted. Anything else is left alone: a merged branch whose worktree is
 * dirty still holds work, and an unmerged branch is work in progress.
 */
export function pruneWorktrees({ repoRoot = root } = {}) {
  const removed = [];
  const kept = [];
  for (const entry of listAgentWorktrees(repoRoot)) {
    if (!entry.registered) continue;
    // `empty` counts as removable: a lane that never committed has nothing in
    // its checkout that a merge would miss. The branch stays, so the run can be
    // inspected.
    if ((entry.merged || entry.empty) && entry.clean) {
      const res = removeWorktree(entry.label, { repoRoot });
      (res.ok ? removed : kept).push(res.ok ? entry.branch : `${entry.branch} (${res.reason})`);
    } else {
      kept.push(entry.merged ? `${entry.branch} (nicht sauber)` : entry.branch);
    }
  }
  return { removed, kept };
}

/** Total size of the checkouts, in MB. The number that decides free disk. */
export function worktreeDiskMb(repoRoot = root) {
  const dir = worktreeRoot();
  if (!existsSync(dir)) return 0;
  let total = 0;
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    try {
      if (statSync(path).isDirectory()) total += dirSize(path);
    } catch {
      /* vanished between the two calls */
    }
  }
  return Math.round(total / (1024 * 1024));
}

function dirSize(path) {
  let total = 0;
  for (const entry of readdirSync(path, { withFileTypes: true })) {
    const child = join(path, entry.name);
    if (entry.isDirectory()) total += dirSize(child);
    else {
      try {
        total += statSync(child).size;
      } catch {
        /* ignore */
      }
    }
  }
  return total;
}

/* ------------------------------------------------------------------ cli --- */

const HELP = `Worktrees je Agent — node scripts/worktree.mjs <befehl>

  list                    alle Agent-Branches mit Zustand
  new <name>              Worktree + Branch anlegen, Godot-Import laufen lassen
  path <name>             Pfad ausgeben (für ein \`cd\`)
  import <name>           Import wiederholen
  remove <name>           Worktree entfernen (nicht sauber → Verweis)
  prune                   gemergte und saubere Worktrees entfernen

Optionen: --base <ref>  --repo <pfad>  --no-import  --force  --delete-branch`;

function main(argv) {
  const [command, ...rest] = argv;
  const flags = new Set(rest.filter((a) => a.startsWith('--')));
  const positional = rest.filter((a) => !a.startsWith('--'));
  const flagValue = (name) => {
    const i = rest.indexOf(name);
    return i === -1 ? null : rest[i + 1] ?? null;
  };
  const log = (line) => console.log(line);

  if (!command || command === 'help' || flags.has('--help')) {
    console.log(HELP);
    return 0;
  }
  // `--repo` is what makes this testable: the suite drives the whole lifecycle
  // against a throwaway clone, and the owner's repository is never the subject.
  const repoRoot = resolve(flagValue('--repo') ?? root);
  if (!existsSync(join(repoRoot, '.git'))) {
    console.error(`Kein Git-Repository in ${repoRoot} — Worktrees brauchen eines.`);
    return 1;
  }

  if (command === 'list') {
    const rows = listAgentWorktrees(repoRoot);
    if (!rows.length) {
      console.log('Keine Agent-Branches.');
      return 0;
    }
    for (const row of rows) {
      const state = row.commits === 0 ? 'leer' : row.merged ? 'gemergt' : 'offen';
      const where = row.registered ? (row.clean ? 'sauber' : `${row.dirty.length} uncommittet`) : 'kein Checkout';
      console.log(
        `${row.branch.padEnd(34)} ${state.padEnd(9)} ${String(row.commits).padStart(3)} Commit(s)  ${where.padEnd(18)} ${row.path}`,
      );
    }
    console.log(`\n${worktreeDiskMb()} MB in ${worktreeRoot()}`);
    return 0;
  }

  const label = positional[0];
  if (!label) {
    console.error(`Welcher Agent? ${HELP}`);
    return 2;
  }

  if (command === 'new') {
    const res = createWorktree(label, {
      repoRoot,
      base: flagValue('--base') ?? 'HEAD',
      doImport: !flags.has('--no-import'),
      log,
    });
    if (!res.ok) {
      console.error(`Worktree nicht angelegt: ${res.reason}`);
      return 1;
    }
    console.log(`${res.reused ? 'Vorhanden' : 'Neu'}: ${res.path} (${res.branch})`);
    return 0;
  }
  if (command === 'path') {
    console.log(worktreePath(label));
    return 0;
  }
  if (command === 'import') {
    const res = importGodot(worktreePath(label), { log });
    if (!res.ok) {
      console.error(`Import fehlgeschlagen: ${res.reason}`);
      return 1;
    }
    return 0;
  }
  if (command === 'remove') {
    const res = removeWorktree(label, {
      repoRoot,
      force: flags.has('--force'),
      deleteBranch: flags.has('--delete-branch') ? (flags.has('--force') ? 'force' : true) : false,
    });
    if (!res.ok) {
      console.error(`Nicht entfernt: ${res.reason}`);
      return 1;
    }
    console.log(`Entfernt: ${res.branch}${res.branchDeleted ? ' (Branch gelöscht)' : ''}`);
    return 0;
  }
  if (command === 'prune') {
    const { removed, kept } = pruneWorktrees({ repoRoot });
    for (const b of removed) console.log(`entfernt  ${b}`);
    for (const b of kept) console.log(`behalten  ${b}`);
    return 0;
  }

  console.error(`Unbekannter Befehl: ${command}\n\n${HELP}`);
  return 2;
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  process.exit(main(process.argv.slice(2)));
}

/** Reads a file, for callers that need the manifest text. */
export function readRepoFile(rel) {
  return readFileSync(join(root, rel), 'utf8');
}
