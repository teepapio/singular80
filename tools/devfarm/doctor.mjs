#!/usr/bin/env node
/**
 * Prüft, ob die Testfarm auf dieser Maschine überhaupt laufen kann — und sagt
 * ausdrücklich, warum nicht, wenn nicht.
 *
 *   npm run farm:doctor
 *
 * Ein Testwerkzeug, das sich nicht selbst prüfen kann, produziert die
 * unangenehmste aller Fehlermeldungen: „kein Gerät gefunden", während in
 * Wahrheit das SDK fehlt. Deshalb wird jede Voraussetzung einzeln benannt.
 */
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { listDevices, loadConfig, readJson, run, tryRun } from './lib/core.mjs';

const cfg = loadConfig();
const checks = [];
const add = (name, ok, detail, hint = '') => checks.push({ name, ok, detail, hint });

// --- Voraussetzungen ---------------------------------------------------------

add('adb vorhanden', existsSync(cfg.adb), cfg.adb);
add('Emulator vorhanden', existsSync(cfg.emulator), cfg.emulator,
  'sdkmanager "emulator"');
add('avdmanager vorhanden', existsSync(cfg.avdmanager), cfg.avdmanager);

const kvm = existsSync('/dev/kvm');
add('KVM (/dev/kvm)', kvm, kvm ? 'Hardwarebeschleunigung vorhanden' : 'nicht vorhanden',
  'Ohne KVM startet der Emulator nicht brauchbar. Auf einem/cloud Kernel '
  + 'muss /dev/kvm durchgereicht werden.');

// Waydroid wird nicht empfohlen, aber geprüft, damit die Aussage belegt ist.
const binder = tryRun('sh', ['-c', 'ls /dev/binder* 2>/dev/null || modinfo binder_ls >/dev/null 2>&1']);
const waydroidPossible = binder.ok;
add('Waydroid möglich', waydroidPossible,
  waydroidPossible ? 'binder vorhanden' : 'weder /dev/binder* noch Modul binder_ls',
  'Waydroid braucht binder_ls und ashmem. Der Ubuntu-Mainline-Kernel hat sie '
  + 'nicht — dafür ist der Emulator der Weg.');

const avdHome = join(cfg.sdk, '.android', 'avd');
const avdPresent = existsSync(join(avdHome, `${cfg.avd}.avd`));
add(`AVD ${cfg.avd}`, avdPresent, avdPresent ? 'angelegt' : 'fehlt (wird beim Start erzeugt)');

// --- Laufzeit ----------------------------------------------------------------

const devices = listDevices(cfg);
const farmDevices = devices.filter((d) => d.serial.startsWith('emulator-'));
add('Farm-Instanzen', farmDevices.length > 0,
  farmDevices.length > 0 ? `${farmDevices.length} online` : 'keine online (farmd start)',
  'npm run farm:start');

const physical = devices.filter((d) => !d.serial.startsWith('emulator-'));
if (physical.length > 0) {
  add('Physische Geräte', true, physical.map((d) => `${d.serial} (${d.state})`).join(', '));
}

// --- Brücke -----------------------------------------------------------------

const bridge = tryRun('sh', ['-c', `curl -s -m 2 http://127.0.0.1:${cfg.bridgePort}/health`]);
add('Bridge', bridge.ok, bridge.ok ? bridge.out.trim().slice(0, 80) : 'nicht erreichbar',
  'npm run farm:bridge');

// --- Farm-APK ----------------------------------------------------------------

add('Farm-APK', existsSync(cfg.apkPath), cfg.apkPath,
  'wird beim ersten Lauf gebaut');

/**
 * Das Farm-Preset muss `x86_64` mitbringen.
 *
 * Das ausgelieferte APK ist absichtlich arm64-only. Ein x86_64-Emulator lehnt
 * es mit „no matching ABI" ab, und die Meldung führt auf eine falsche Fährte —
 * sie sieht nach einem kaputten Emulator aus und nicht nach einer
 * Architekturfrage.
 */
function farmPresetOk() {
  const file = 'godot/export_presets.cfg';
  if (!existsSync(file)) return { ok: false, detail: 'godot/export_presets.cfg fehlt' };
  const text = readFileSync(file, 'utf8');
  const start = text.indexOf(`name="${cfg.apkPreset}"`);
  if (start < 0) return { ok: false, detail: `Preset "${cfg.apkPreset}" fehlt` };
  const from = text.lastIndexOf('[preset.', start);
  // Die Grenze muss eine echte Preset-Überschrift sein: `[preset.3.options]`
  // beginnt ebenfalls mit `[preset.` und würde den Block genau dort abschneiden,
  // wo die Architektur-Einstellungen stehen.
  const rest = text.slice(start);
  const match = /\n\[preset\.\d+\]/.exec(rest);
  const block = match ? text.slice(from, start + match.index) : text.slice(from);
  const hasX86 = /architectures\/x86_64=true/.test(block);
  const hasArm = /architectures\/arm64-v8a=true/.test(block);
  if (!hasX86) {
    return {
      ok: false,
      detail: `Preset "${cfg.apkPreset}" ohne architectures/x86_64=true`,
    };
  }
  return {
    ok: true,
    detail: hasArm ? 'x86_64 und arm64' : 'nur x86_64',
  };
}

const preset = farmPresetOk();
add('Farm-Preset', preset.ok, preset.detail,
  'muss architectures/x86_64=true enthalten, sonst installiert das APK nicht');

// --- Ausgabe ----------------------------------------------------------------

const pad = Math.max(...checks.map((c) => c.name.length));
console.log('\nTestfarm — Doctor\n');
for (const check of checks) {
  const mark = check.ok ? '✓' : '✗';
  console.log(`  ${mark} ${check.name.padEnd(pad)}  ${check.detail}`);
  if (!check.ok && check.hint) {
    for (const line of check.hint.match(/.{1,74}(\s|$)/g) ?? []) {
      console.log(`      ${line.trim()}`);
    }
  }
}

const failed = checks.filter((c) => !c.ok && !c.name.startsWith('Physische'));
console.log('');
if (failed.length === 0) {
  console.log('Alles bereit. Start: npm run farm:start && npm run farm:bridge');
  process.exit(0);
}
console.log(`${failed.length} Voraussetzung(en) fehlen. Die Instanz-Zeile ist erst nach "farm:start" erfüllbar.`);
