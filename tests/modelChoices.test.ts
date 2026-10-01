/**
 * The model dropdown in the settings dialog: which models opencode can run here,
 * and which effort levels each one accepts.
 *
 * The two halves of that answer come from two different places — `opencode models`
 * for the models, opencode's public catalog for the effort levels — and the tests
 * drive both: a stub binary for the first, a stub catalog for the second. Nothing
 * here reaches the network or a model.
 *
 * Why the effort levels are per model at all is measured, not assumed:
 * `opencode run --model 'opencode/nemotron-3.5-lightning-free#low'` exits 1 with
 * `Variant unavailable for opencode/nemotron-3.5-lightning-free: low`. A generic
 * "low/medium/high" list would therefore be a list of ways to fail a run.
 */
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  buildModelChoices,
  catalogEfforts,
  joinModelSetting,
  listModelChoices,
  parseModelLines,
  readModelIds,
  resetModelCaches,
  splitModelSetting,
} from '../server/models';
import {
  effortOptionLabel,
  effortOptions,
  findChoice,
  formatContext,
  formatCost,
  groupModelChoices,
  joinModelSetting as joinFromDashboard,
  modelOptionLabel,
  splitModelSetting as splitFromDashboard,
} from '../src/dashboard/models';

/** Two real lines from this machine, plus the noise a terminal adds. */
const MODELS_STDOUT = [
  'opencode-go/space-bunny-free',
  'opencode-go/deepseek-v4.1-flash',
  'opencode-go/gpt-6-luna',
  'opencode/nemotron-3.5-lightning-free',
  'opencode/space-bunny-free',
  'opencode-go/space-bunny-free',
  'warn: something the CLI wanted to say',
  '  opencode-go/kimi-k3  ',
  '',
].join('\n');

/** The shape of `https://models.opencode.ai/api.json`, cut down to three models. */
const CATALOG = {
  'opencode-go': {
    models: {
      'space-bunny-free': {
        name: 'Space Bunny Free',
        reasoning_options: [{ type: 'effort', values: ['low', 'medium', 'high', 'xhigh', 'max'] }],
        limit: { context: 1_048_576 },
        cost: { input: 0, output: 0 },
      },
      'deepseek-v4.1-flash': {
        name: 'DeepSeek V4.1 Flash',
        reasoning_options: [{ type: 'effort', values: ['low', 'high', 'max'] }],
        limit: { context: 163_840 },
        cost: { input: 0.15, output: 0.6 },
      },
      'gpt-6-luna': {
        name: 'GPT-6 Luna',
        reasoning_options: [
          { type: 'effort', values: ['none', 'low', 'medium', 'high', 'xhigh', 'max'] },
        ],
        limit: { context: 272_000 },
        cost: { input: 0.1, output: 0.5 },
      },
    },
  },
  opencode: {
    models: {
      // Free tier, no effort levels — the case a generic effort list would break.
      'nemotron-3.5-lightning-free': { name: 'Nemotron 3.5 Lightning Free' },
    },
  },
};

const dirs: string[] = [];

function stubBinary(script: string): string {
  const dir = mkdtempSync(join(tmpdir(), 'singular80-models-'));
  dirs.push(dir);
  const bin = join(dir, 'opencode-stub');
  writeFileSync(bin, `#!/bin/sh\n${script}\n`);
  chmodSync(bin, 0o755);
  return bin;
}

beforeEach(() => {
  resetModelCaches();
});

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
  vi.unstubAllGlobals();
});

describe('opencode models', () => {
  it('liest Provider/Modell-Zeilen und lässt den Rest liegen', () => {
    expect(parseModelLines(MODELS_STDOUT)).toEqual([
      'opencode-go/space-bunny-free',
      'opencode-go/deepseek-v4.1-flash',
      'opencode-go/gpt-6-luna',
      'opencode/nemotron-3.5-lightning-free',
      'opencode/space-bunny-free',
      'opencode-go/kimi-k3',
    ]);
  });

  it('liest die Zeilen wirklich aus dem Prozess', async () => {
    const bin = stubBinary(`cat <<'EOF'\n${MODELS_STDOUT}\nEOF`);
    expect(await readModelIds(bin)).toContain('opencode-go/gpt-6-luna');
  });

  it('ein Binary, das es nicht gibt, liefert eine leere Liste statt zu raten', async () => {
    expect(await readModelIds(join(tmpdir(), 'gibt-es-nicht-12345'))).toEqual([]);
  });
});

describe('Katalog und Modelle', () => {
  it('nimmt die Anstrengungsstufen genau so, wie der Katalog sie nennt', () => {
    expect(catalogEfforts(CATALOG['opencode-go'].models['space-bunny-free'])).toEqual([
      'low',
      'medium',
      'high',
      'xhigh',
      'max',
    ]);
    // Ein Modell ohne `reasoning_options` hat keine Stufen — das ist der Fall, in
    // dem jede erfundene Stufe den Lauf killt.
    expect(catalogEfforts(CATALOG.opencode.models['nemotron-3.5-lightning-free'])).toEqual([]);
    expect(catalogEfforts(undefined)).toEqual([]);
  });

  it('ein Modell mit mehreren Optionen sammelt nur die der Art "effort"', () => {
    expect(
      catalogEfforts({
        reasoning_options: [
          { type: 'budget_tokens', values: ['1024', '2048'] },
          { type: 'effort', values: ['high'] },
        ],
      }),
    ).toEqual(['high']);
  });

  it('verbindet Modell und Stufe und sortiert nach Provider, dann Preis', () => {
    const choices = buildModelChoices(parseModelLines(MODELS_STDOUT), CATALOG);
    // Bezahlt zuerst (nach Namen), dann die kostenlosen und die ohne Preisangabe.
    expect(choices.map((c) => c.id)).toEqual([
      'opencode/nemotron-3.5-lightning-free',
      'opencode/space-bunny-free',
      'opencode-go/deepseek-v4.1-flash',
      'opencode-go/gpt-6-luna',
      'opencode-go/kimi-k3',
      'opencode-go/space-bunny-free',
    ]);
    const bunny = choices.find((c) => c.id === 'opencode-go/space-bunny-free');
    expect(bunny?.efforts).toEqual(['low', 'medium', 'high', 'xhigh', 'max']);
    expect(bunny?.context).toBe(1_048_576);
    expect(bunny?.name).toBe('Space Bunny Free');
  });

  it('ohne Katalog bleiben die Modelle da — nur ohne Stufen', () => {
    const choices = buildModelChoices(parseModelLines(MODELS_STDOUT), null);
    expect(choices).toHaveLength(6);
    expect(choices.every((c) => c.efforts.length === 0)).toBe(true);
    // Der Name fällt auf die Id zurück, statt zu einem erfundenen zu werden.
    expect(choices[0].name).toBe(choices[0].id);
  });

  it('fragt den Katalog nur einmal und merkt sich die Antwort', async () => {
    const bin = stubBinary(`cat <<'EOF'\n${MODELS_STDOUT}\nEOF`);
    const fetchMock = vi.fn(async () => ({ ok: true, json: async () => CATALOG }));
    vi.stubGlobal('fetch', fetchMock);
    const first = await listModelChoices({ bin });
    const second = await listModelChoices({ bin });
    expect(first.find((c) => c.id === 'opencode-go/gpt-6-luna')?.efforts).toEqual([
      'none',
      'low',
      'medium',
      'high',
      'xhigh',
      'max',
    ]);
    expect(second.map((c) => c.id)).toEqual(first.map((c) => c.id));
    // Ein Klick auf den Dialog darf keinen zweiten Download auslösen.
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('ein Katalog, der nicht kommt, kostet die Modelle nicht', async () => {
    const bin = stubBinary(`cat <<'EOF'\n${MODELS_STDOUT}\nEOF`);
    vi.stubGlobal('fetch', vi.fn(async () => {
      throw new Error('offline');
    }));
    const choices = await listModelChoices({ bin });
    expect(choices.length).toBeGreaterThan(0);
    expect(choices.every((c) => c.efforts.length === 0)).toBe(true);
  });
});

describe('Die gespeicherte Einstellung', () => {
  it('teilt sich in Modell und Stufe und baut sich wieder zusammen', () => {
    expect(splitModelSetting('opencode-go/gpt-6-luna#high')).toEqual({
      model: 'opencode-go/gpt-6-luna',
      effort: 'high',
    });
    expect(splitModelSetting('  opencode-go/kimi-k3  ')).toEqual({ model: 'opencode-go/kimi-k3', effort: '' });
    expect(splitModelSetting('')).toEqual({ model: '', effort: '' });
    expect(joinModelSetting('opencode-go/gpt-6-luna', 'high')).toBe('opencode-go/gpt-6-luna#high');
    // Kein Modell heißt "opencode entscheidet" — und dann gibt es auch kein `#`.
    expect(joinModelSetting('', 'high')).toBe('');
    expect(joinModelSetting('opencode-go/kimi-k3', '')).toBe('opencode-go/kimi-k3');
  });

  it('Server und Dashboard rechnen dasselbe', () => {
    // Zwei Kopien derselben Logik an einer Drahtstelle: wenn sie auseinanderlaufen,
    // zeigt das Dialogfeld etwas anderes als das, was der Runner bekommt.
    for (const value of ['a/b#high', 'a/b', '', '  a/b # max ']) {
      const server = splitModelSetting(value);
      const client = splitFromDashboard(value);
      expect(client).toEqual(server);
      expect(joinFromDashboard(client.model, client.effort)).toBe(joinModelSetting(server.model, server.effort));
    }
  });
});

describe('GET /api/models', () => {
  it('antwortet mit den Modellen samt Stufen, über HTTP', async () => {
    const { createApp } = await import('../server/app');
    const dir = mkdtempSync(join(tmpdir(), 'singular80-models-http-'));
    dirs.push(dir);
    // The stub behaves like the real CLI: `models` prints the list, everything
    // else is irrelevant here because no run starts.
    const bin = stubBinary('if [ "$1" = "models" ]; then cat <<\'EOF\'\n' + MODELS_STDOUT + '\nEOF\nfi');
    const previous = process.env.OPENCODE_BIN;
    process.env.OPENCODE_BIN = bin;
    vi.stubGlobal('fetch', vi.fn(async () => ({ ok: true, json: async () => CATALOG })));
    const app = createApp({
      dataDir: dir,
      contentDir: join(import.meta.dirname, '..', 'content'),
      projectRoot: dir,
      distDir: join(dir, 'dist'),
      runnerEnabled: false,
    });
    try {
      await app.ready();
      const res = await app.inject({ path: '/api/models' });
      expect(res.statusCode).toBe(200);
      const body = res.json() as { models: { id: string; efforts: string[] }[]; catalog: boolean };
      expect(body.catalog).toBe(true);
      expect(body.models.map((m) => m.id)).toContain('opencode-go/gpt-6-luna');
      expect(body.models.find((m) => m.id === 'opencode-go/gpt-6-luna')?.efforts).toContain('xhigh');
      // The free model with no levels stays selectable, without levels.
      expect(body.models.find((m) => m.id === 'opencode/nemotron-3.5-lightning-free')?.efforts).toEqual([]);
    } finally {
      await app.close();
      if (previous === undefined) delete process.env.OPENCODE_BIN;
      else process.env.OPENCODE_BIN = previous;
    }
  });
});

describe('Das Dialogfeld', () => {
  // Source-level, like `queueTaskText.test.ts` and `runConsole.test.ts`: the
  // dashboard has no DOM in the suite, and every way this can break is a string
  // in the template or a missing id.
  const MAIN = readFileSync(join(import.meta.dirname, '..', 'src/dashboard/main.ts'), 'utf8');
  const HTML = readFileSync(join(import.meta.dirname, '..', 'index.html'), 'utf8');

  it('zwei Auswahllisten statt eines Eingabefeldes', () => {
    expect(HTML).toContain('<select id="setting-model">');
    expect(HTML).toContain('<select id="setting-effort">');
    // The text field is what the owner asked to get rid of: a typo in it is a
    // failed run with no way to see the mistake in a list.
    expect(HTML).not.toMatch(/<input[^>]*id="setting-model"/);
  });

  it('speichert Modell und Anstrengung als ein `--model`, wie es der Runner liest', () => {
    expect(MAIN).toContain("joinModelSetting(\n        ($('#setting-model') as HTMLSelectElement).value");
    expect(MAIN).toContain("($('#setting-effort') as HTMLSelectElement).value");
  });

  it('die Anstrengung wird beim Modellwechsel neu gefüllt', () => {
    // Ohne das bleibt die Stufe des vorherigen Modells stehen und der Lauf
    // scheitert an `Variant unavailable`.
    expect(MAIN).toContain("$('#setting-model').addEventListener('change'");
    expect(MAIN).toContain('renderEffortSelect(findChoice(state.models, id), \'\')');
    expect(MAIN).toContain('effortOptions(choice)');
  });

  it('die Liste kommt einmal pro Seitenaufruf, nicht bei jedem Öffnen', () => {
    expect(MAIN).toContain('if (state.modelsLoaded) return;');
    expect(MAIN).toContain("api<ModelList>('/api/models')");
  });
});

describe('Die Auswahl im Dashboard', () => {
  const list = buildModelChoices(parseModelLines(MODELS_STDOUT), CATALOG);

  it('nennt Kontext und Preis, damit man ein Modell nach Zahlen wählt', () => {
    const luma = findChoice(list, 'opencode-go/gpt-6-luna')!;
    expect(formatContext(luma.context)).toBe('272k');
    expect(formatContext(1_048_576)).toBe('1 Mio');
    expect(formatContext(1_500_000)).toBe('1.5 Mio');
    expect(formatCost(luma)).toBe('$0,10 / $0,50 je Mio. Token');
    expect(formatCost(findChoice(list, 'opencode-go/space-bunny-free')!)).toBe('kostenlos');
    expect(modelOptionLabel(luma)).toContain('GPT-6 Luna');
  });

  it('die Stufen kommen vom Modell, nicht aus einer festen Liste', () => {
    expect(effortOptions(findChoice(list, 'opencode-go/deepseek-v4.1-flash'))).toEqual([
      { value: '', label: 'wie im Modell vorgesehen' },
      { value: 'low', label: 'niedrig' },
      { value: 'high', label: 'hoch' },
      { value: 'max', label: 'maximum' },
    ]);
    // Ein Modell ohne Stufen: nur die Standardzeile, und der Dialog sperrt sie.
    expect(effortOptions(findChoice(list, 'opencode/nemotron-3.5-lightning-free'))).toEqual([
      { value: '', label: 'wie im Modell vorgesehen' },
    ]);
    expect(effortOptionLabel('xhigh')).toBe('sehr hoch');
  });

  it('gruppiert nach Provider und zeigt einen gespeicherten Wert, den es nicht mehr gibt', () => {
    const groups = groupModelChoices(list, 'opencode-go/steht-nicht-mehr-drin');
    expect(groups[0].provider).toBe('gespeichert');
    expect(groups[0].options[0].label).toContain('nicht in der Liste');
    expect(groups.map((g) => g.provider)).toContain('opencode-go');
    // Ein Wert, den es gibt, wird nicht als "gespeichert" geführt.
    expect(groupModelChoices(list, 'opencode-go/kimi-k3').map((g) => g.provider)).not.toContain('gespeichert');
  });
});