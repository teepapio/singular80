# Singular 80 → Google Play (closed beta)

Dieses Verzeichnis ist alles, was für den Play-Auftritt von **Singular 80**
nötig ist: eine signierte AAB, die Store-Texte, die Grafiken, die Rechtstexte
und eine Checkliste, die genau sagt, was noch fehlt.

Es ist bewusst ein **eigenes Projekt** und keine Erweiterung von `godot/`:

* `godot/` bleibt die Spiel-Quelle — hier wird nur *ein* Export-Preset
  dazugeschrieben (idempotent, von `scripts/install-export-preset.mjs`).
* Alles Play-Spezifische (Keystore-Pfade, Store-Texte, Screenshots, Rechtstexte)
  liegt hier und wird **nicht** committet.
* Kein `npm install` nötig: alle Skripte sind abhängigkeitsfrei.

```
googleplay/
├── config/app.json          einzige Wahrheit: Paketname, Version, SDK-Level, URLs
├── docs/                    der Weg in acht Kapiteln (hier beginnen)
├── listing/                 Store-Texte (en-US, de-DE) + Asset-Maße
├── legal/                   Datenschutz, Nutzungsbedingungen, Moderation
├── scripts/                 Werkzeuge (Umgebung, Build, Prüfung, Grafiken)
└── build/                   Artefakte (git-ignoriert): AAB, Screenshots, bundletool
```

## Schnellstart

```bash
cd googleplay
npm run check      # Werkzeugkette prüfen (Godot, JDK 17, Android SDK, Keystore)
npm run prepare    # Android-SDK 36 + bundletool + Godot-Template auf API 36
npm run keystore   # Upload-Key erzeugen (Passwort wird interaktiv abgefragt)
npm run build      # signierte AAB bauen  →  build/singular80-play.aab
npm run verify     # AAB gegen die Play-Pflichtregeln prüfen
npm run assets     # Icon + Feature Graphic erzeugen
npm run preflight  # Gesamtzustand inkl. Platzhaltern und Pflichtdokumenten
```

`npm run build` erzeugt **kein** APK, sondern ein Android App Bundle (AAB).
Google Play nimmt für neue Apps seit August 2021 ausschließlich AAB an.

Zwei Dinge, die man wissen sollte:

* **API 36 ist Pflicht.** Seit 31.08.2026 müssen neue Apps Android 16
  targeten. Godot 4.5.1 liefert 35, deshalb hebt `npm run prepare` das
  Gradle-Template an — und zwar bei *jedem* Build, weil
  `godot:android-template` das Verzeichnis sonst überschreibt.
* **Screenshots brauchen eine Grafik.** Godot rendert headless mit dem
  Dummy-Renderer, der keine Frames zeichnet. Auf dieser Maschine geht es
  nicht; `npm run screenshots -- --import <Ordner>` normalisiert stattdessen
  echte Aufnahmen vom Gerät.

## Die drei harten Blöcke

| Block | Wer | Warum |
|---|---|---|
| 1. Technisch sauberes AAB (API 36, signiert) | **ich** | `npm run prepare && npm run build && npm run verify` |
| 2. Rechtstexte, Store-Texte, Grafiken, Ratings | **wir zusammen** | Ich habe die Entwürfe und Prüfskripte, du die Angaben zu Person, Firma, Backend, Land |
| 3. Play-Konto, Verifizierung, 12 Tester, 14 Tage | **du** | Persönliche Identität, Ausweis, Konto, Tester-Organising |

Details, Reihenfolge und Zeitplan: [`docs/PLAN.md`](docs/PLAN.md).

## Kurzreferenz

| Frage | Datei |
|---|---|
| Wie lange dauert das und wer macht was? | [`docs/PLAN.md`](docs/PLAN.md) |
| Konto anlegen, Identität verifizieren, App erstellen | [`docs/PLAY-CONSOLE.md`](docs/PLAY-CONSOLE.md) |
| AAB, Signierung, Version-Codes, Upgrades | [`docs/RELEASE.md`](docs/RELEASE.md) |
| Texte, Icons, Screenshots, was Google ablehnt | [`docs/LISTING.md`](docs/LISTING.md) |
| Zielgruppe, Altersfreigabe, Datenschutz, UGC | [`docs/COMPLIANCE.md`](docs/COMPLIANCE.md) |
| 12 Tester, 14 Tage, Produktionsantrag | [`docs/CLOSED-TEST.md`](docs/CLOSED-TEST.md) |
| Was ist fertig, was fehlt? | [`docs/CHECKLIST.md`](docs/CHECKLIST.md) |

## Eingriff in `godot/` — und was dabei repariert wurde

Alles bleibt in diesem Verzeichnis, mit **einer** Ausnahme: `npm run preset`
schreibt einen zweiten Export-Preset (`Google Play (AAB)`) in
`godot/export_presets.cfg`. Godot liest Presets nur von dort.

Dabei ist ein Fehler im Bestand aufgefallen und behoben: Godots `ConfigFile`
behandelt `#` **nicht** als Kommentar, sondern klebt die Zeile an die nächste
und schluckt dabei den Schlüssel. In `export_presets.cfg` hat das
`include_filter` und `exclude_filter` des APK-Presets verschluckt — die
Testskripte waren also im Release-APK enthalten, und der Godot-Exporter
protokollierte bei jedem Build:

```
ERROR: Couldn't find the given section "preset.0" and key "include_filter"
```

`install-export-preset.mjs` schreibt die `#`-Zeilen zu `;` um, prüft das
Ergebnis anschließend mit Godots eigenem Parser und bricht ab, wenn das
Preset danach nicht auffindbar ist.

Stand der Recherche: September 2026. Die Regeln, die gerade greifen:
Target-API 36 seit 31.08.2026, 12 Tester × 14 Tage für neue persönliche
Konten, AAB-Pflicht, Play App Signing, Datenschutz-Formular, IARC-Fragebogen.
