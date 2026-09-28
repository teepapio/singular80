import { describe, expect, it } from 'vitest';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

/**
 * A committed `.gdignore` in `med/`/`high/` would leave the repository in slim mode
 * forever: every later full build would quietly ship less mesh and the gallery would
 * offer only the low tier. The build script cleans up in a `finally` and on SIGINT,
 * but a hard kill skips both — hence this invariant, checked on every `npm test`.
 */
const root = join(import.meta.dirname, '..');
const meshRoot = join(root, 'godot', 'assets', 'meshes');

function gdignoreFiles(dir: string): string[] {
  if (!existsSync(dir)) return [];
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) out.push(...gdignoreFiles(full));
    else if (name === '.gdignore') out.push(full);
  }
  return out;
}

describe('Leichtes APK — .gdignore', () => {
  it('liegt im versionierten Mesh-Baum nicht', () => {
    const found = gdignoreFiles(meshRoot);
    expect(
      found.map((p) => p.replace(`${root}/`, '')),
      'Eine .gdignore-Datei im Mesh-Baum heißt: ein Build wurde unterbrochen. '
        + 'rm -f godot/assets/meshes/med/.gdignore godot/assets/meshes/high/.gdignore '
        + 'und danach "godot --headless --path godot --import".',
    ).toEqual([]);
  });

  it('hat beide Stufen-Ordner als Ziel, damit der Build sie auch findet', () => {
    // The script writes into exactly these two; a rename must change this too, loudly.
    for (const tier of ['med', 'high']) {
      expect(existsSync(join(meshRoot, tier)), `${tier}/ fehlt`).toBe(true);
    }
  });
});

describe('Leichtes APK — Export-Presets', () => {
  const cfgPath = join(root, 'godot', 'export_presets.cfg');
  const cfg = readFileSync(cfgPath, 'utf8');

  /**
   * The `[preset.N]` block of one preset, up to the next `[preset.M]`.
   *
   * The options live in a sibling section `[preset.N.options]`, which also starts
   * with `[preset.` — so the boundary has to be the bare header.
   */
  function section(name: string): string {
    const headers = [...cfg.matchAll(/^\[preset\.\d+\]$/gm)];
    expect(headers.length, 'Keine Preset-Sections in export_presets.cfg').toBeGreaterThan(0);
    const start = cfg.indexOf(`name="${name}"`);
    expect(start, `Preset "${name}" fehlt in export_presets.cfg`).toBeGreaterThan(-1);
    // The header owning the name is the last one before it, not the first.
    let header: (RegExpMatchArray & { index?: number }) | undefined;
    for (const candidate of headers) {
      if ((candidate.index ?? 0) < start) header = candidate;
    }
    expect(header, `Kein [preset.N]-Header für "${name}"`).toBeDefined();
    const from = header?.index ?? 0;
    const next = headers.find((h) => (h.index ?? 0) > from);
    return cfg.slice(from, next?.index ?? undefined);
  }

  it('gibt dem schlanken Preset einen eigenen Ausgabepfad', () => {
    // Deliberately not the concrete filename: it has churned between "leicht" and
    // "slim", and pinning the spelling breaks on a rename without catching a real
    // defect. What must hold is that the two artifacts cannot overwrite each other.
    const preset = section('Android (Leicht)');
    const path = /export_path="([^"]+)"/.exec(preset)?.[1] ?? '';
    expect(path, 'kein export_path im schlanken Preset').not.toBe('');
    expect(path.endsWith('.apk')).toBe(true);
    const fullPath = /export_path="([^"]+)"/.exec(section('Android'))?.[1] ?? '';
    expect(path, 'beide Presets schreiben in dieselbe Datei').not.toBe(fullPath);
  });

  it('exportiert mit all_resources — "exclude" packt die Roh-GLB mit', () => {
    // `export_filter="exclude"` packs the raw `.glb`. An exported game cannot load
    // one — importing happens in the editor — so the meshes would be in the package
    // and still invisible.
    for (const name of ['Android', 'Android (Leicht)', 'Google Play (AAB)']) {
      expect(section(name), name).toContain('export_filter="all_resources"');
      expect(section(name), name).not.toContain('export_files=');
    }
  });

  it('lässt das volle Preset unangetastet', () => {
    const full = section('Android');
    expect(full).toContain('export_path="/home/edi/singular80/build/singular80.apk"');
    expect(full).toContain('gradle_build/export_format=0');
  });

  it('nutzt in beiden Presets dieselbe minSdk/targetSdk und nur arm64', () => {
    for (const name of ['Android', 'Android (Leicht)']) {
      const preset = section(name);
      expect(preset, name).toContain('gradle_build/min_sdk="24"');
      expect(preset, name).toContain('architectures/arm64-v8a=true');
      expect(preset, name).toContain('architectures/armeabi-v7a=false');
      expect(preset, name).toContain('architectures/x86=false');
      expect(preset, name).toContain('architectures/x86_64=false');
    }
  });

  it('schließt Tests und Wegwerf-Harness in beiden Presets aus', () => {
    for (const name of ['Android', 'Android (Leicht)']) {
      const preset = section(name);
      expect(preset, name).toContain('exclude_filter=');
      expect(preset, name).toContain('tests/*');
      // `_*` also catches the generated GDScript files.
      expect(preset, name).toMatch(/exclude_filter="[^"]*_/);
    }
  });

  it('hat in beiden Presets Kommentare mit ";" — ConfigFile bricht bei "#" ab', () => {
    // A `#` comment containing `=` is not a comment to Godot's ConfigFile; that
    // mistake once made the Play preset invisible.
    for (const line of cfg.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed.startsWith('#')) continue;
      // Only comment lines are forbidden; a `#` inside a value is fine.
      expect(trimmed, `Keine "#"-Kommentare in export_presets.cfg: ${trimmed}`).not.toMatch(/^#/);
    }
  });
});
