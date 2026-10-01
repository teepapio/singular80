/**
 * Model and effort for the settings dialog: pure formatting, no DOM.
 *
 * The settings are stored as one string (`provider/model#level`) because that is
 * what the runner hands to `opencode run --model`, and because it is what was
 * stored before the dialog had a dropdown. Everything here exists so that string
 * can be *chosen* instead of typed.
 */

/** One entry of `GET /api/models`, mirroring `server/models.ts`. */
export interface ModelChoice {
  id: string;
  provider: string;
  model: string;
  name: string;
  /** Reasoning levels this exact model accepts; empty means it has none. */
  efforts: string[];
  /** Context window in tokens, 0 when unknown. */
  context: number;
  /** USD per million tokens; 0 means free. */
  costIn: number;
  costOut: number;
}

export interface ModelList {
  models: ModelChoice[];
  /** False when the catalog could not be read: models without effort levels. */
  catalog: boolean;
}

export interface SelectOption {
  value: string;
  label: string;
}

export interface SelectGroup {
  provider: string;
  options: SelectOption[];
}

/** `provider/model#level` split into its two parts. */
export function splitModelSetting(value: string): { model: string; effort: string } {
  const hash = value.indexOf('#');
  if (hash < 0) return { model: value.trim(), effort: '' };
  return { model: value.slice(0, hash).trim(), effort: value.slice(hash + 1).trim() };
}

/** The inverse. An empty model means "opencode decides", which is no `--model`. */
export function joinModelSetting(model: string, effort: string): string {
  const id = model.trim();
  const level = effort.trim();
  if (!id || !level) return id;
  return `${id}#${level}`;
}

/** 1_048_576 → "1 Mio", 262_144 → "262k", 0 → "". */
export function formatContext(tokens: number): string {
  if (!Number.isFinite(tokens) || tokens <= 0) return '';
  if (tokens >= 1_000_000) {
    // Rounded to one decimal, and the trailing ",0" goes: 1_048_576 is "1 Mio",
    // not "1.0 Mio".
    const millions = Math.round((tokens / 1_000_000) * 10) / 10;
    return `${String(millions).replace(/\.0$/, '')} Mio`;
  }
  if (tokens >= 1000) return `${Math.round(tokens / 1000)}k`;
  return String(tokens);
}

/** Price per million tokens, or "kostenlos" — which is a reason to pick it. */
export function formatCost(choice: ModelChoice): string {
  if (choice.costIn === 0 && choice.costOut === 0) return 'kostenlos';
  const price = (value: number) => (value === 0 ? '0' : value.toFixed(2).replace('.', ','));
  return `$${price(choice.costIn)} / $${price(choice.costOut)} je Mio. Token`;
}

/** What the owner reads in the list: the name, and the two numbers that decide. */
export function modelOptionLabel(choice: ModelChoice): string {
  const parts = [choice.name, formatContext(choice.context), formatCost(choice)];
  return parts.filter((part) => part !== '').join(' — ');
}

/** German names for opencode's effort levels; an unknown one keeps its name. */
export function effortOptionLabel(level: string): string {
  switch (level) {
    case '':
      return 'wie im Modell vorgesehen';
    case 'none':
      return 'kein Nachdenken';
    case 'minimal':
      return 'minimal';
    case 'low':
      return 'niedrig';
    case 'medium':
      return 'mittel';
    case 'high':
      return 'hoch';
    case 'xhigh':
      return 'sehr hoch';
    case 'max':
      return 'maximum';
    default:
      return level;
  }
}

/** The effort options of one model, "wie im Modell vorgesehen" first. */
export function effortOptions(choice: ModelChoice | null): SelectOption[] {
  const efforts = choice?.efforts ?? [];
  return [{ value: '', label: effortOptionLabel('') }, ...efforts.map((level) => ({ value: level, label: effortOptionLabel(level) }))];
}

/** The model the stored value names, or null for "opencode decides". */
export function findChoice(list: ModelChoice[], id: string): ModelChoice | null {
  if (!id) return null;
  return list.find((choice) => choice.id === id) ?? null;
}

/**
 * The model options, grouped by provider and with the standard choice first.
 *
 * A stored value that the list does not contain is added as its own entry: the
 * dialog has to show what is actually configured, and a value opencode no longer
 * offers is something the owner should *see*, not something to silently replace.
 */
export function groupModelChoices(list: ModelChoice[], storedModel: string): SelectGroup[] {
  const groups: SelectGroup[] = [];
  const byProvider = new Map<string, SelectOption[]>();
  for (const choice of list) {
    const options = byProvider.get(choice.provider) ?? [];
    options.push({ value: choice.id, label: modelOptionLabel(choice) });
    byProvider.set(choice.provider, options);
  }
  for (const [provider, options] of byProvider) groups.push({ provider, options });
  const known = list.some((choice) => choice.id === storedModel);
  if (storedModel && !known) {
    groups.unshift({
      provider: 'gespeichert',
      options: [{ value: storedModel, label: `${storedModel} — nicht in der Liste von opencode` }],
    });
  }
  return groups;
}