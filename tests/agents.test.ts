import { describe, expect, it } from 'vitest';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const AGENT_DIR = join(process.cwd(), '.opencode', 'agents');

/**
 * Why this file exists.
 *
 * Every agent definition is a markdown file with YAML frontmatter, and the
 * harness parses that frontmatter *before* it shows the agent anywhere. A plain
 * unquoted scalar may not contain `": "` — to a YAML parser that is a key/value
 * separator, not punctuation. gray-matter throws, opencode's loader treats the
 * throw as "no such agent", and the agent disappears from the catalog without a
 * word, a log line or a failed test.
 *
 * It happened: `agent-merge` carried a colon in its description and the company
 * ran with sixteen of seventeen specialists for a day. The only symptom was a
 * name missing from a list, and a list is exactly the thing nobody diffs.
 *
 * There is no YAML parser in the dependencies, and adding one to catch a colon
 * would be the bigger dependency. So this is the rule itself, spelled out: an
 * unquoted scalar may not contain a key/value separator, a comment marker or a
 * leading YAML indicator. A quoted value may contain anything.
 */
const TOP_LEVEL_KEY = /^([A-Za-z_][A-Za-z0-9_-]*):(?: (.*))?$/;
const INDICATOR = /^["'[{&*!|>%@`?#-]/;

interface AgentDefinition {
  name: string;
  lines: string[];
  frontmatter: string;
  /** `null` when the closing `---` is missing, which is the other silent way. */
  body: string | null;
}

function readAgent(name: string): AgentDefinition {
  const lines = readFileSync(join(AGENT_DIR, name), 'utf8').split('\n');
  if (lines[0] !== '---') {
    return { name, lines, frontmatter: '', body: null };
  }
  const end = lines.indexOf('---', 1);
  if (end < 0) {
    return { name, lines, frontmatter: '', body: null };
  }
  return { name, lines, frontmatter: lines.slice(1, end).join('\n'), body: lines.slice(end + 1).join('\n') };
}

function agentFiles(): string[] {
  return readdirSync(AGENT_DIR)
    .filter((f) => f.endsWith('.md'))
    .sort();
}

describe('Agentendefinitionen', () => {
  it('liest jede Datei als Frontmatter mit Abschluss', () => {
    const broken = agentFiles().filter((f) => readAgent(f).body === null);
    expect(broken, 'diese Dateien haben kein schließendes "---" und gelten dem Harness als reiner Text').toEqual([]);
  });

  it('hält sich an die YAML-Regeln, an denen eine Beschreibung scheitern kann', () => {
    const problems: string[] = [];
    for (const file of agentFiles()) {
      const { name, lines, frontmatter } = readAgent(file);
      if (frontmatter === '') continue;
      lines.slice(1, lines.indexOf('---', 1)).forEach((line, i) => {
        const match = TOP_LEVEL_KEY.exec(line);
        // A key without a value opens a nested block (`permission:`), and a
        // comment is not a key at all.
        if (!match || match[2] === undefined) return;
        const value = match[2];
        if (/^["']/.test(value)) return;
        const line2 = i + 2;
        if (value.includes(': ')) problems.push(`${name}:${line2} — unquotierter Wert mit ": ": ${match[1]}`);
        else if (value.endsWith(':')) problems.push(`${name}:${line2} — Wert endet auf ":": ${match[1]}`);
        else if (/\s#/.test(value)) problems.push(`${name}:${line2} — " #" beginnt einen Kommentar: ${match[1]}`);
        else if (INDICATOR.test(value)) problems.push(`${name}:${line2} — Wert beginnt mit einem YAML-Indikator: ${match[1]}`);
      });
    }
    expect(problems, 'invalides Frontmatter — der Agent fällt dann still aus dem Katalog').toEqual([]);
  });

  it('gibt jedem Agenten eine Beschreibung, einen Modus und ein Modell', () => {
    const missing: string[] = [];
    for (const file of agentFiles()) {
      const { name, frontmatter } = readAgent(file);
      const description = /^description: (?:"[^"]*"|\S.*)$/m.test(frontmatter);
      const mode = /^mode: (\S+)$/m.exec(frontmatter)?.[1];
      const model = /^model: (\S+)$/m.exec(frontmatter)?.[1];
      if (!description) missing.push(`${name} — keine description`);
      if (!mode) missing.push(`${name} — kein mode`);
      else if (!['subagent', 'primary', 'all'].includes(mode)) missing.push(`${name} — mode "${mode}" gibt es nicht`);
      if (!model) missing.push(`${name} — kein model`);
    }
    expect(missing).toEqual([]);
  });

  it('nennt den Torwächter als Subagent, nicht als primären Sitz', () => {
    // A gatekeeper that is a primary agent is a session the owner can type into,
    // and `main` is the one thing that must only be touched by a gate.
    expect(readAgent('agent-merge.md').frontmatter).toMatch(/^mode: subagent$/m);
  });

  it('gibt der Leitsitzung genau das eine Werkzeug, das sie braucht', () => {
    const { frontmatter } = readAgent('agent-main.md');
    const shell = [...frontmatter.matchAll(/^ {4}"([^"]+)": (?:allow|deny)$/gm)].map((m) => m[1]);

    // Primary, because the owner addresses it directly.
    expect(frontmatter).toMatch(/^mode: primary$/m);
    // The one instrument a dispatcher has: the specialist itself.
    expect(frontmatter).toMatch(/^ {2}subagent: allow$/m);
    expect(frontmatter).toMatch(/^ {2}"\*": deny$/m);
    // No write surface: a dispatcher that may also write becomes the queue.
    // This is the wall that matters and it is still intact.
    expect(frontmatter).not.toMatch(/^ {2}edit:/m);
    // Shell was opened to every agent on the owner's instruction (2026-10-01): a
    // subagent stalling on a permission prompt mid-task was judged a worse
    // failure than an over-permissioned one. The former hand-written allowlist
    // is therefore gone from all seventeen definitions, `agent-main` included.
    //
    // What that costs is recorded here rather than discovered later: with
    // `"*": allow` this session can run `npm run gate` itself, so the "only the
    // Torwächter merges" property is no longer enforced by permissions — it is
    // now a rule the agent is trusted to follow. The one place it is still
    // mechanically enforced is the tree: `agent-merge` remains the only
    // definition holding an `edit` grant for `CHANGELOG.md`, and the gate is a
    // merge-gate script rather than an agent's judgement.
    expect(shell).toEqual(['*']);
  });

  it('gibt keinem Agenten einen Bearbeitungszugang auf Produktcode außerhalb seines Scopes', () => {
    // The narrow walls below are what the broad shell grant does not touch.
    // If one of them disappears, `agent-grade` could read the implementation it
    // is supposed to grade against, and `agent-hire` could edit the game.
    const grade = readAgent('agent-grade.md').frontmatter;
    expect(grade).not.toMatch(/^ {4}"godot\/src/);

    const hire = readAgent('agent-hire.md').frontmatter;
    expect(hire).toMatch(/^ {4}"\.opencode\/agents\/\*\*": allow$/m);
    expect(hire).not.toMatch(/^ {4}"(godot|server|src)\//m);
  });
});
