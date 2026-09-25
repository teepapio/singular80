// Heuristic support for splitting one suggestion ("Auftrag") into several
// independent sub-tasks ("Einzelaufträge"). The result is only a proposal: the
// dashboard shows it in an editable dialog before anything is created.

const MIN_TASK_LENGTH = 8;
const MIN_TASK_WORDS = 3;
export const MAX_TASKS = 20;

const LIST_MARKER = /^\s*(?:[-*•‣◦–—]|\d+[.)]|[a-z][.)])\s+/i;
// Conjunctions that typically join two separate pieces of work.
const CONJUNCTIONS = /(?:^|\s)(?:und|sowie|außerdem|ausserdem|zusätzlich|zusaetzlich)(?=\s)/gi;

function cleanTask(part: string): string {
  return part
    .replace(LIST_MARKER, '')
    .replace(/^[\s:;,.–—-]+/, '')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * Best-effort split of a suggestion into independent sub-tasks. Explicit lists
 * win over sentence boundaries, which win over conjunctions. Never returns an
 * empty list and falls back to the original text when no sensible split is found.
 */
export function splitIntoTasks(text: string): string[] {
  const normalized = text.replace(/\r\n?/g, '\n').trim();
  if (!normalized) return [];

  // 1) Explicit list structure: one item per line (bullets / numbers / plain lines).
  const lines = normalized
    .split('\n')
    .map(cleanTask)
    .filter((line) => line.length >= MIN_TASK_LENGTH);
  if (lines.length >= 2) return lines.slice(0, MAX_TASKS);

  // 2) Sentence boundaries.
  const sentences = normalized
    .split(/(?<=[.!?;])\s+/)
    .map(cleanTask)
    .filter((sentence) => sentence.length >= MIN_TASK_LENGTH);
  if (sentences.length >= 2) return sentences.slice(0, MAX_TASKS);

  // 3) Conjunctions joining separate work items.
  const conjunctive = normalized
    .replace(CONJUNCTIONS, '\n')
    .split('\n')
    .map(cleanTask)
    .filter((part) => part.length >= MIN_TASK_LENGTH && part.split(' ').length >= MIN_TASK_WORDS);
  if (conjunctive.length >= 2) return conjunctive.slice(0, MAX_TASKS);

  return [normalized];
}

export interface NormalizedTasks {
  tasks?: string[];
  error?: string;
}

/** Validate and clean tasks coming from the dashboard before they are persisted. */
export function normalizeTasks(input: unknown): NormalizedTasks {
  if (!Array.isArray(input)) return { error: 'tasks muss eine Liste aus Texten sein.' };
  const tasks: string[] = [];
  for (const raw of input) {
    if (typeof raw !== 'string') return { error: 'Jeder Einzelauftrag muss ein Text sein.' };
    const task = raw.replace(/\s+/g, ' ').trim();
    if (task.length < 3) return { error: 'Ein Einzelauftrag ist zu kurz (mindestens 3 Zeichen).' };
    if (task.length > 2000) return { error: 'Ein Einzelauftrag ist zu lang (höchstens 2000 Zeichen).' };
    tasks.push(task);
  }
  if (tasks.length < 2) return { error: 'Mindestens zwei Einzelaufträge werden benötigt.' };
  if (tasks.length > MAX_TASKS) return { error: `Höchstens ${MAX_TASKS} Einzelaufträge pro Vorschlag.` };
  return { tasks };
}
