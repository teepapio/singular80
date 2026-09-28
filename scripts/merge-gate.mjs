#!/usr/bin/env node
/**
 * The merge gate: the one place where agent branches become `main`.
 *
 *   node scripts/merge-gate.mjs --status           # what would be merged
 *   node scripts/merge-gate.mjs suggestion-14 …    # these branches
 *   node scripts/merge-gate.mjs                    # every open agent branch
 *   node scripts/merge-gate.mjs --no-verify        # merge without the suites
 *   node scripts/merge-gate.mjs --no-push          # verify + fast-forward only
 *   node scripts/merge-gate.mjs --keep             # leave the gate worktree
 *
 * Why a gate at all: with one working directory, two agents cannot both sit on
 * their own branch, so their work interleaves in the same files and the only
 * thing that separates them afterwards is a commit message. With a worktree per
 * agent, every lane ends in a branch, and a branch that is never merged is work
 * that never ships — the failure this repository already has once, in the shape
 * of 101 commits nobody pushed. The gate is what makes a branch safe to promise.
 *
 * The order of the steps is the whole design:
 *
 *   1. nothing is touched in the shared tree — a throwaway worktree at `main`
 *   2. merge the branches there, one merge commit each
 *   3. regenerate the derived files instead of reconciling them
 *   4. run the full suite there, against the merged result
 *   5. only then fast-forward `main` and push
 *
 * A red suite therefore costs one worktree, not the branch of a player.
 */
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  DERIVED_MIRRORS,
  agentBranch,
  dirtyFiles,
  listAgentWorktrees,
} from './worktree.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

/** Git calls here are local and bounded; a hung git must not hang the gate. */
const GIT_TIMEOUT_MS = 60_000;

function git(cwd, args, timeoutMs = GIT_TIMEOUT_MS) {
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
  };
}

function run(cwd, bin, args, { timeout = 1_800_000 } = {}) {
  return spawnSync(bin, args, { cwd, encoding: 'utf8', timeout, killSignal: 'SIGKILL' });
}

/* ------------------------------------------------------------ pure parts --- */

/**
 * Which branches go in, and which are named but do not exist.
 *
 * Already-merged branches are reported as such rather than merged again: after
 * a gate run the branches are still there until somebody prunes them, and
 * "merged twice" would produce an empty merge commit and a confusing report.
 */
export function resolveBranches(names, entries) {
  const known = new Map(entries.map((e) => [e.branch, e]));
  const merge = [];
  const skipped = [];
  for (const name of names) {
    const branch = name.startsWith('agent/') ? name : agentBranch(name);
    const entry = known.get(branch);
    if (!entry) {
      skipped.push({ branch, why: 'gibt es nicht' });
      continue;
    }
    if (entry.merged) {
      skipped.push({ branch, why: 'schon in main' });
      continue;
    }
    merge.push(branch);
  }
  return { merge, skipped };
}

/**
 * Everything that must stop the gate before it merges anything.
 *
 * The dirty shared tree is *not* in this list on purpose: a foreign session's
 * half-finished work is exactly what the gate exists to survive. It is refused
 * only at the last step, the fast-forward, where git itself decides whether the
 * merge would overwrite it.
 */
export function gateRefusals({ head, base, behindOrigin, origin }) {
  const out = [];
  if (head !== 'main') out.push(`Der gemeinsame Baum steht auf \`${head}\`, nicht auf \`main\` — erst dorthin wechseln.`);
  if (!base) out.push('Kein `main` gefunden — das Gate hat nichts, womit es arbeiten könnte.');
  if (origin && behindOrigin) {
    out.push('`origin/main` ist weiter als das lokale `main` — erst `git pull`, sonst schiebt der Push nichts.');
  }
  return out;
}

/** The files the sync tools own: their output is committed, never merged. */
export function syncPaths() {
  return [...DERIVED_MIRRORS, 'locale'];
}

/**
 * What the gate verifies, and in which order. Cheap and specific first, so a
 * mistake is named before the 15 minutes are spent.
 */
export function verificationSteps({ hasNodeModules }) {
  const steps = [
    { name: 'typecheck', bin: 'npx', args: ['tsc', '--noEmit'], needsModules: true },
    { name: 'npm test', bin: 'npm', args: ['test'], needsModules: true },
    { name: 'Spieltests', bin: 'node', args: ['scripts/test-game.mjs'], needsModules: false },
  ];
  return steps.filter((s) => !s.needsModules || hasNodeModules);
}

/* ------------------------------------------------------------------ gate --- */

/**
 * The whole cycle, in a throwaway checkout. Returns a report; never throws for
 * a merge conflict, because a conflict is an answer and not a crash.
 */
export function runGate({ branches, verify = true, push = true, advance = true, keep = false, repoRoot = root, log = console.log } = {}) {
  const head = git(repoRoot, ['rev-parse', '--abbrev-ref', 'HEAD']).out;
  const base = git(repoRoot, ['rev-parse', '--verify', '--quiet', 'refs/heads/main']).out;
  const hasOrigin = git(repoRoot, ['remote']).out.split('\n').includes('origin');
  const behindOrigin = hasOrigin ? git(repoRoot, ['rev-list', '--count', 'main..origin/main']).out !== '0' : false;
  // One fetch, at the start: a surprise about the remote after 15 minutes of
  // suite is the worst moment to learn that the push was never going to work.
  if (hasOrigin) git(repoRoot, ['fetch', '--quiet', 'origin', 'main'], 120_000);

  const report = { head, base, branches, steps: [], refused: gateRefusals({ head, base, behindOrigin, origin: hasOrigin }), mergeSha: null, pushed: false, fastForwarded: false };
  if (report.refused.length) return report;

  const gateDir = mkdtempSync(join(tmpdir(), 's80-gate-'));
  report.gateDir = gateDir;
  try {
    const added = git(repoRoot, ['worktree', 'add', '--detach', gateDir, 'main']);
    if (!added.ok) {
      report.refused.push(`Gate-Worktree nicht anlegbar: ${added.err}`);
      return report;
    }
    // `node_modules` is a symlink, not a copy: 104 MB per gate would be the
    // largest thing in the process, and the packages are read-only here.
    if (existsSync(join(repoRoot, 'node_modules')) && !existsSync(join(gateDir, 'node_modules'))) {
      try {
        symlinkSync(join(repoRoot, 'node_modules'), join(gateDir, 'node_modules'));
      } catch (err) {
        log(`Hinweis: node_modules nicht verlinkt (${err.message}) — typecheck und npm test übersprungen.`);
      }
    }
    const hasNodeModules = existsSync(join(gateDir, 'node_modules'));

    for (const branch of branches) {
      const merged = git(gateDir, ['merge', '--no-ff', '-m', `merge(${branch}): Vorschlag über das Gate`, branch]);
      if (merged.ok) {
        log(`gemergt  ${branch}`);
        report.steps.push({ kind: 'merge', branch, ok: true });
        continue;
      }
      const conflicts = git(gateDir, ['diff', '--name-only', '--diff-filter=U']).out.split('\n').filter(Boolean);
      git(gateDir, ['merge', '--abort']);
      report.steps.push({ kind: 'merge', branch, ok: false, conflicts });
      report.refused.push(
        `Konflikt beim Merge von ${branch}${conflicts.length ? `: ${conflicts.join(', ')}` : ''}`,
      );
      return report;
    }
    // Derived files: reset to the base, then regenerate once. Merging two
    // versions of a 900-entry catalogue is a conflict nobody can resolve by
    // reading; regenerating it from the sources cannot conflict at all.
    const reset = git(gateDir, ['checkout', 'main', '--', ...DERIVED_MIRRORS]);
    if (!reset.ok) log(`Hinweis: Spiegel zurücksetzen ging nicht (${reset.err}) — sie werden neu erzeugt.`);
    const contentSync = run(gateDir, 'node', ['scripts/sync-content.mjs']);
    const localeSync = run(gateDir, 'node', ['scripts/locale.mjs', 'sync']);
    for (const [name, res] of [['content:sync', contentSync], ['locale:sync', localeSync]]) {
      report.steps.push({ kind: name, ok: res.status === 0, output: res.status === 0 ? '' : (res.stderr ?? '').slice(-800) });
      if (res.status !== 0) report.refused.push(`${name} fehlgeschlagen — siehe Ausgabe.`);
    }
    const syncCommit = git(gateDir, ['add', '--', ...syncPaths()]);
    if (syncCommit.ok) {
      const changed = git(gateDir, ['diff', '--cached', '--name-only']).out.split('\n').filter(Boolean);
      if (changed.length) {
        const committed = git(gateDir, ['commit', '-m', 'chore(sync): Kataloge und Spiegel nach dem Merge']);
        report.steps.push({ kind: 'sync-commit', ok: committed.ok, files: changed });
        if (!committed.ok) report.refused.push(`Sync-Commit fehlgeschlagen: ${committed.err}`);
      }
    }

    if (verify) {
      for (const step of verificationSteps({ hasNodeModules })) {
        log(`prüfe    ${step.name} …`);
        const res = run(gateDir, step.bin, step.args, { timeout: step.name === 'Spieltests' ? 1_200_000 : 600_000 });
        const ok = res.status === 0;
        report.steps.push({
          kind: 'verify',
          name: step.name,
          ok,
          output: ok ? '' : tail(res.stdout, res.stderr),
        });
        log(ok ? `         ${step.name} grün` : `         ${step.name} rot`);
        if (!ok) {
          report.refused.push(`${step.name} ist rot — main bleibt unberührt.`);
          break;
        }
      }
    }

    if (report.refused.length) return report;

    // Read the sha *after* the sync commit: the tree that was verified is the
    // one `main` has to end up at, and an earlier reading would skip it.
    report.mergeSha = git(gateDir, ['rev-parse', 'HEAD']).out;
    if (!report.mergeSha) {
      report.refused.push('Konnte den Merge-Stand nicht lesen.');
      return report;
    }

    if (advance === false) {
      log(`Geprüft. Fast-forward auf ${report.mergeSha} liegt bereit.`);
      return report;
    }

    // The shared tree keeps its own uncommitted work; git refuses the
    // fast-forward when the merge would touch one of those files, which is the
    // answer we want — and it comes with the file name.
    const ff = git(repoRoot, ['merge', '--ff-only', report.mergeSha], 60_000);
    if (!ff.ok) {
      report.refused.push(`Fast-forward auf main nicht möglich: ${ff.err}`);
      return report;
    }
    report.fastForwarded = true;
    log(`main ist auf ${report.mergeSha.slice(0, 7)}`);

    if (push) {
      const res = git(repoRoot, ['push', 'origin', 'main'], 120_000);
      report.pushed = res.ok;
      if (!res.ok) report.refused.push(`Push fehlgeschlagen: ${res.err}`);
      else log('gepusht  origin/main');
    }
    return report;
  } finally {
    if (!keep) {
      git(repoRoot, ['worktree', 'remove', '--force', gateDir]);
      rmSync(gateDir, { recursive: true, force: true });
    } else {
      log(`Gate-Worktree bleibt liegen: ${gateDir}`);
    }
  }
}

function tail(...parts) {
  const text = parts.filter(Boolean).join('\n').trimEnd();
  const lines = text.split('\n');
  return lines.slice(-40).join('\n');
}

/* ------------------------------------------------------------------ cli --- */

const HELP = `Merge-Gate — node scripts/merge-gate.mjs [branch …] [optionen]

  --status      nur berichten, nichts mergen
  --no-verify   ohne typecheck, npm test und Spieltests mergen
  --no-advance  prüfen, aber main nicht fast-forwarden
  --no-push     main fast-forwarden, aber nicht pushen
  --keep        den Gate-Worktree liegen lassen zum Nachsehen
  --repo <pfad>  anderes Repository (ein Klon, ein Testrepo)`;

function main(argv) {
  const flags = new Set(argv.filter((a) => a.startsWith('--')));
  // `--repo` is what makes this testable: the suite runs the whole gate against
  // a throwaway clone, and the owner's repository is never the test subject.
  const repoIndex = argv.indexOf('--repo');
  const repoRoot = resolve(repoIndex === -1 ? root : argv[repoIndex + 1] ?? '.');
  // Everything positional except the value of `--repo`, which is a path and not
  // a branch. Counting it as a name produced the memorable message
  // "agent/tmp/opencode/gate-e2e/repo (gibt es nicht)".
  const names = argv.filter((a, i) => !a.startsWith('--') && i !== repoIndex + 1);
  if (flags.has('--help')) {
    console.log(HELP);
    return 0;
  }
  if (!existsSync(join(repoRoot, '.git'))) {
    console.error(`Kein Git-Repository in ${repoRoot}.`);
    return 1;
  }

  const entries = listAgentWorktrees(repoRoot);
  const open = entries.filter((e) => !e.merged);
  const { merge, skipped } = resolveBranches(names.length ? names : open.map((e) => e.branch), entries);

  if (flags.has('--status')) {
    console.log(`Branches: ${entries.length}, offen: ${open.length}`);
    for (const e of entries) {
      console.log(`  ${e.merged ? 'gemergt' : 'offen  '}  ${e.branch.padEnd(32)} ${e.dirty.length ? `${e.dirty.length} uncommittet` : e.registered ? 'sauber' : 'kein Checkout'}`);
    }
    for (const s of skipped) console.log(`  übersprungen  ${s.branch} (${s.why})`);
    const foreign = dirtyFiles(repoRoot);
    console.log(`\nGemeinsamer Baum: ${foreign.length} Datei(en) von Hand geändert.`);
    console.log('Merge ist davon unberührt; der Fast-forward am Ende prüft es von sich aus.');
    return 0;
  }

  if (!merge.length) {
    console.log(skipped.length ? `Nichts zu tun: ${skipped.map((s) => `${s.branch} (${s.why})`).join(', ')}` : 'Keine offenen Agent-Branches.');
    return 0;
  }

  console.log(`Gate: ${merge.join(', ')}\n`);
  const report = runGate({
    branches: merge,
    verify: !flags.has('--no-verify'),
    advance: !flags.has('--no-advance'),
    push: !flags.has('--no-push'),
    keep: flags.has('--keep'),
    repoRoot,
  });

  for (const step of report.steps) {
    if (step.kind === 'merge') console.log(`merge    ${step.branch}: ${step.ok ? 'ok' : `KONFLIKT ${step.conflicts.join(', ')}`}`);
    else if (step.kind === 'sync-commit') console.log(`sync     ${step.files.length} Datei(en) neu erzeugt`);
    else if (step.kind === 'verify') console.log(`prüfe    ${step.name}: ${step.ok ? 'grün' : 'ROT'}`);
  }
  for (const step of report.steps) {
    if (step.kind === 'verify' && !step.ok && step.output) console.log(`\n--- ${step.name} ---\n${step.output}`);
  }

  if (report.refused.length) {
    console.error(`\nGate gestoppt:\n${report.refused.map((r) => `  - ${r}`).join('\n')}`);
    console.error('\nmain ist unverändert. Worktrees aufräumen: node scripts/worktree.mjs prune');
    return 1;
  }
  if (!report.fastForwarded) {
    console.log(`\nGeprüft, nichts angefasst. Fast-forward mit:\n  git merge --ff-only ${report.mergeSha}`);
    console.log('Aufräumen: node scripts/worktree.mjs prune');
    return 0;
  }
  console.log(`\nmain fast-forwarded${report.pushed ? ' und gepusht' : ' (nicht gepusht)'}.`);
  console.log('Aufräumen: node scripts/worktree.mjs prune');
  return 0;
}
if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  process.exit(main(process.argv.slice(2)));
}
