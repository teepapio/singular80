# 03 — Release: AAB, Signatur, Versionen

## Was Play für neue Apps verlangt

| Anforderung | Stand | Umsetzung in diesem Projekt |
|---|---|---|
| **AAB statt APK** | Pflicht seit August 2021 | `gradle_build/export_format=1` im Play-Preset |
| **targetSdk ≥ 36** (Android 16) | Pflicht seit 31.08.2026 | Gradle-Template auf compileSdk/targetSdk 36 gehoben |
| **minSdk ≥ 21** | seit August 2021 | 24 (Android 7.0) |
| **Play App Signing** | Pflicht | Upload-Key aus `npm run keystore` |
| **Signatur** | Pflicht | `keystore/release*` im Preset, AAB wird mit RSA-4096 signiert |
| **Versioncode streng steigend** | Pflicht | `version/code` in `config/app.json` |
| **Basis-Modul < 200 MB** | Pflicht | aktuell 77,5 MB (AAB komprimiert besser als das 124-MB-APK) |

### Wie die API-36-Anforderung gelöst wurde

Godot 4.5.1 (installiert) bringt ein Android-Build-Template mit
`compileSdk 35 / targetSdk 35` mit. `scripts/prepare-toolchain.mjs`

1. installiert `platforms;android-36` und `build-tools;36.0.0` via `sdkmanager`,
2. setzt in `godot/android/build/config.gradle` `compileSdk`, `targetSdk` und
   `buildTools` auf die konfigurierten Werte,
3. ergänzt `android.suppressUnsupportedCompileSdk=36` in `gradle.properties`
   (das AGP 8.6.1 des Templates kennt API 36 noch nicht offiziell),
4. lädt `bundletool` für die Manifest-Prüfung.

**Wichtig:** `npm run godot:android-template` entpackt das Template neu und
setzt die Werte auf 35 zurück. Deshalb ruft `npm run build` `prepare` jedes Mal
vor dem Export auf. Wer die Reihenfolge umstellt, baut ein AAB mit targetSdk 35
— und Play lehnt den Upload ab.

Alternative: Godot auf 4.7 aktualisieren (4.7.2 ist seit 18.08.2026 stabil und
bringt API 36 nativ mit). Das ist ein separates Projekt mit Breaking Changes
zwischen 4.5 und 4.7 — sinnvoll als eigener Schritt, nicht nebenbei.

## Signierung

Play App Signing ist Pflicht. Es gibt zwei Schlüssel:

| Schlüssel | Wo | Folge bei Verlust |
|---|---|---|
| **Upload-Key** | deine Datei (`npm run keystore`) | Ohne ihn keine Uploads mehr. Reset über den Play-Support möglich, dauert Tage. |
| **App-Signatur-Key** | bei Google | Wird von Google verwahrt, Google erzeugt ihn beim ersten Upload. |

`npm run keystore` erzeugt einen RSA-4096-Schlüssel mit 10 000 Tagen Gültigkeit
unter `~/.android/play-upload.keystore`. Das Passwort wird interaktiv
abgefragt und steht in keiner Datei. `config/app.json` nennt die
Umgebungsvariablen:

```bash
export PLAY_KEYSTORE_PATH=~/.android/play-upload.keystore
export PLAY_KEYSTORE_USER=singular80-upload
export PLAY_KEYSTORE_PASSWORD=…      # aus dem Passwortmanager
npm run build
```

**Das Passwort steht kurzzeitig in `godot/export_presets.cfg`** — dort holt
Godot es sich. `build-aab.mjs` schreibt es vor dem Export in das Preset und
räumt es danach (und auch bei Abbruch) wieder aus, weil die Datei versioniert
ist. `npm run check` warnt, falls dort ein Passwort steht.

Optional lässt sich zusätzlich der Fingerabdruck prüfen:

```bash
keytool -list -v -keystore ~/.android/play-upload.keystore -alias singular80-upload
export PLAY_KEYSTORE_SHA256=<SHA-256 des Zertifikats>
npm run verify
```

Der gleiche Wert steht in der Konsole unter *Release → Setup → App integrity*.

## Versionierung

`version/code` ist der **versionCode** (Ganzzahl) und muss bei jedem Upload
**streng größer** sein als alle bisher hochgeladenen. `version/name` ist die
für Menschen sichtbare Version.

Regeln:

* `config/app.json` → `version.versionCode` / `version.versionName` hochzählen,
* `npm run build` baut die neue Version,
* `npm run verify` prüft, ob Manifest und Config übereinstimmen,
* Hochgeladene Codes kann man nicht wiederverwenden, auch nicht nach Löschen
  eines Release.

Vorschlag: Code 1 = erste interne, 2 = erste geschlossene Beta, ab dann pro
Upload hochzählen. Versionname `1.0.0`, `1.0.1`, …

## App-Größe

| Variante | Größe | Hinweis |
|---|---|---|
| AAB, arm64, 3 LOD-Stufen | **77,5 MB** | aktueller Stand, ein Basis-Modul |
| APK (alt, im Repo gebaut) | 124 MB | nicht mehr Play-tauglich |
| AAB ohne `med/` + `high/` | ~32 MB | Galerie zeigt nur die Low-Poly-Meshes |

Play liefert pro Gerät nur die passende ABI aus. Deshalb wiegt ein AAB mit
arm64-Vorrat weniger als ein APK mit derselben Menge — die 200-MB-Grenze für
das Basis-Modul ist also kein Problem.

**Optional später:** Die beiden reicheren LOD-Stufen liegen in
`godot/assets/meshes/med/` und `…/high/` (zusammen ~45 MB). Wenn die
Installationsgröße zum Problem wird (Tester mit wenig Speicher), die
Verzeichnisse aus dem Export nehmen — dann zeigt die Galerie nur ein Mesh pro
Modell. Das ist eine Produktentscheidung, keine Play-Pflicht.

## 32-Bit-Geräte

`config/app.json` → `android.architectures` ist auf `arm64-v8a` gesetzt.
Geräte ohne ARM64-Unterstützung (alte 32-Bit-Handys) können die App dann nicht
installieren. Für den closed test mit aktuellen Telefonen unproblematisch.
`armeabi-v7a: true` dreht es um — kostet Größe und Testzeit.

## Was `npm run verify` prüft

* Datei ist ein AAB, mit Basis-Modul und arm64-Libs
* `targetSdkVersion` ≥ 36, `minSdkVersion` wie konfiguriert
* Paketname und `versionCode` stimmen mit `config/app.json`
* nur erwartete Permissions (INTERNET, VIBRATE), keine sensiblen
* Signatur gültig (jarsigner), optional gegen `PLAY_KEYSTORE_SHA256`
* Manifest als Spiel deklariert (`isGame`/`appCategory=game`)

Das Manifest liest das Skript aus der Gradle-Zwischendatei
`godot/android/build/build/intermediates/bundle_manifest/…/AndroidManifest.xml`
desselben Builds, weil das Manifest im AAB binäres Protobuf ist. Mit einem
vollständigen `bundletool-all.jar` in `build/tools/` wird stattdessen das
Bundle selbst gelesen.

## Rollout

1. **Internal testing** — 100 Testerplätze, sofort verfügbar. Erst hier
   hochladen, Pre-Launch-Report laufen lassen, Geräte-Checkpoint beachten.
2. **Closed testing** — 12 Tester, 14 Tage. Nach jeder Änderung, die unter 14
   Tagen alt ist, eine **neue Version** hochladen: Play zählt die 14 Tage ab
   dem Opt-in, nicht ab dem letzten Build — aber Tester müssen eine funktionierende
   Version haben.
3. **Production** — erst nach erfolgreichem Antrag. Staged rollout 5 → 20 → 100 %.

## Quellen

* Target API: <https://support.google.com/googleplay/android-developer/answer/11926878>
* AAB-Pflicht: <https://support.google.com/googleplay/android-developer/answer/9859152>
* Play App Signing: <https://support.google.com/googleplay/android-developer/answer/9842756>
* Version-Codes: <https://support.google.com/googleplay/android-developer/answer/9845334>
* Godot Android-Export: <https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_android.html>
