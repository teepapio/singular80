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
| APK, arm64, 3 LOD-Stufen | **81,3 MB** | Release, native Bibliothek komprimiert |
| APK ohne `med/` + `high/` | **29,0 MB** | Galerie zeigt nur die Low-Poly-Meshes |
| AAB, arm64, 3 LOD-Stufen | 77,5 MB | vor der Kompression gemessen; Play liefert pro ABI |

Play liefert pro Gerät nur die passende ABI aus. Deshalb wiegt ein AAB mit
arm64-Vorrat weniger als ein APK mit derselben Menge — die 200-MB-Grenze für
das Basis-Modul ist also kein Problem.

**Optional später:** Die beiden reicheren LOD-Stufen liegen in
`godot/assets/meshes/med/` und `…/high/` (zusammen ~45 MB). Wenn die
Installationsgröße zum Problem wird (Tester mit wenig Speicher), die
Verzeichnisse aus dem Export nehmen — dann zeigt die Galerie nur ein Mesh pro
Modell. Das ist eine Produktentscheidung, keine Play-Pflicht.

## Das schlanke APK (ohne med/ und high/)

`npm run build:apk` baut eine zweite, kleinere Variante: dieselbe App, aber ohne
die beiden reicheren Mesh-Stufen. Spielstand, HiScores und Cloud sind identisch
— es fehlen nur Dateien.

```bash
cd googleplay
npm run build:apk                 # → ../build/singular80-leicht.apk
adb install -r ../build/singular80-leicht.apk
```

**Warum ein Preset und kein Löschen der Ordner:** `AssetRegistry` und zwei
Tests vergleichen die Mesh-Ordner mit der Registry, und in diesem Baum arbeitet
ein zweiter Agent. Ein `exclude_filter` auf *einer* Exportvariante lässt das
Projekt unangetastet.

Ausschluss (im Preset `Android (Leicht)`): zwei Wege, beide gemessen

| Weg | Wirkung | Risiko |
|---|---|---|
| `exclude_filter=…, assets/meshes/med/*, assets/meshes/high/*` | Export filtert die Stufen heraus: 0/155 med, 0/155 high im Paket | keins — der Baum wird nicht angefasst |
| `.gdignore` in `med/` und `high/` | Editor sieht die Ordner nicht, Exporter packt sie nicht | mutiert den versionierten Baum; ein `SIGKILL` lässt ihn dauerhaft dünn |

`build-apk-slim.mjs` nutzt derzeit `.gdignore` mit `finally` +
SIGINT/SIGTERM-Handler, einer Eintrittsprüfung auf liegengebliebene Marker und
dem Wächter `tests/lightApk.test.ts`. Der `exclude_filter` braucht diese
Vorkehrungen nicht — er ist die robustere Wahl, falls sich der Baum
irgendwann nicht mehr ändert.

### Gemessen, nicht angenommen

Geprüft wird Datei für Datei. Ein importiertes Mesh liegt als
`assets/.godot/imported/<name>.glb-<md5>.scn` im Paket, und `<name>` ist in
allen drei Stufen identisch — ein namensbasierter Vergleich wäre grün, obwohl
die Stufen mitdriften. Verglichen werden deshalb die **md5-Summen** aus den
`.import`-Dateien:

| APK | low | med | high |
|---|---|---|---|
| schlank | 155/155 | **0/155** | **0/155** |
| voll | 155/155 | 155/155 | 155/155 |

Beide Zeilen sind an den ausgelieferten APKs gemessen, nicht geschätzt.

**Die Dateigröße ist dabei kein Beweis.** Zwei schlanke Builds mit identischem
Inhalt wogen 73,1 MB und 27,6 MB; der Unterschied waren ausschließlich die
`libgodot_android.so` (66,7 MiB deflatet statt gespeichert, `extractNativeLibs`),
nicht die Meshes. Aussagekräftig ist allein der md5-Vergleich.

Was im schlanken Build verändert ist:

| | voll | schlank |
|---|---|---|
| Größe (gemessen, Release) | 81,3 MB | **29,0 MB** (−52,3 MB, −64 %) |
| Low-Poly-Meshes | 155 | 155 |
| Galerie | drei Detailstufen | nur „Low Poly" |
| `lod.json` | ja | ja (nur die Low-Zahlen sind sichtbar) |
| Signatur | Debug-Key | Debug-Key — `adb install -r` aktualisiert über die bestehende Installation |

## Wo die Größe wirklich steckt

Zwei Hebel, und der zweite war der größere:

| | voll | schlank |
|---|---|---|
| `libgodot_android.so` | 23,2 MB (von 70,0 MB) | 23,2 MB |
| Meshes (465 bzw. 155 Stufen) | 53,5 MB | 1,4 MB |
| `classes.dex`, Skripte, `res` | ~4 MB | ~4 MB |

`gradle_build/compress_native_libraries=true` lässt die native Bibliothek
deflaten: 70,0 auf 23,2 MB, **47,7 MB (37 %) kleiner**. Das ist mehr, als die
beiden reicheren Mesh-Stufen zusammen gekostet haben.

Der Preis steht nicht im Preset, sondern hier: Android entpackt die Bibliothek
beim Installieren. Das Gerät belegt damit APK **plus** entpackte `.so`, wo es
vorher nur das APK belegte — der Download sinkt um 47,7 MB, der Speicherbedarf
steigt. Wer den Speicher wichtiger findet, dreht genau diese eine Zeile zurück.

Nebenbei gemessen und deshalb als Hebel tauglich, aber nicht als Ziel: das
Release-Template ist mit 70,0 MB nur 6 MB kleiner als das Debug-Template
(76,0 MB). `--export-release` lohnt sich aus Gründen der Korrektheit.

Zum Vergleich: der erste Debug-Build ohne Kompression und mit allen drei Stufen
wog 135,6 MB. Gegenüber dem sind das −40 % (voll) bzw. −79 % (schlank).

Die Galerie beschriftet die tatsächlich gezeigte Stufe. Früher stand dort die
gewählte Stufe samt Dreieckszahl, also „Mittel — 1.000 Dreiecke" über einem
200er-Mesh, wenn `med/` fehlt. Jetzt fällt sie pro Mesh auf die nächstfeinere
vorhandene Stufe zurück und schreibt das dazu.

**Für Play ist das nicht gedacht:** Dort gilt die AAB-Pflicht, und die AAB
enthält bewusst alle drei Stufen (77,5 MB sind unkritisch). Der schlanke Build
ist für Sideloading, Geräte mit wenig Speicher und für Tester ohne Download.

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

Das Manifest im AAB ist binäres Protobuf. Gelesen wird es auf zwei Wegen:

1. mit `bundletool dump manifest` — dafür muss die **vollständige**
   `bundletool-all-<version>.jar` (nicht die Bibliotheksvariante) in
   `build/tools/` liegen,
2. sonst aus dem Gradle-Merge **desselben Builds**
   (`godot/android/build/build/intermediates/…/AndroidManifest.xml`).

Variante 2 ist eine Falle: das Manifest auf der Platte gehört zu *einem*
Export. Nach `npm run build:apk` ist es das des APK-Builds, und eine Prüfung
damit würde die falsche Datei bestätigen. Deshalb akzeptiert das Skript nur ein
Manifest, das höchstens zwei Minuten vor dem AAB geschrieben wurde — sonst
verweigert es die Freigabe mit dem Hinweis, das AAB neu zu bauen. Das ist
Absicht: lieber „nicht prüfbar“ als „geprüft“ für etwas anderes.

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
