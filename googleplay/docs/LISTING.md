# 04 — Store-Listing: Texte, Grafiken, Screenshots

## Was Play braucht

| Asset | Pflicht | Maß | Hinweis |
|---|---|---|---|
| App-Icon | ja | 512×512, 32-Bit PNG mit Alpha, max. 1 MB | höherwertige Version als das Launcher-Icon |
| Feature Graphic | ja | 1024×500, JPEG oder 24-Bit PNG **ohne** Alpha | wird überall als Teaser genutzt |
| Screenshots | ja, min. 2 | Kürzeste Seite 320 px, längste 3840 px, 16:9 oder 9:16 | **Spielecht**, keine Mock-ups |
| Kurzbeschreibung | ja | max. 80 Zeichen | erscheint zuerst |
| Vollbeschreibung | nein, aber ohne sie findet dich niemand | max. 4000 Zeichen | |
| Video | freiwillig, für Spiele empfohlen | YouTube-URL | muss öffentlich/gelistet, werbefrei sein |

Alles unter *Grow users → Main store listing*. Für jede Sprache ein eigener
Eintrag; `config/app.json → app.languages` legt fest, welche gepflegt werden.

## Texte

Quelle: `listing/en-US.md` und `listing/de-DE.md`. Das Format ist
maschinenlesbar (eine `##`-Überschrift pro Formularfeld), damit
`npm run preflight` die Grenzen und die verbotenen Begriffe prüfen kann.

Geprüft wird unter anderem:

* Kurzbeschreibung ≤ 80, Vollbeschreibung ≤ 4000, Screenshot-Caption ≤ 80
* **Verboten** sind Leistungsversprechen und Aufrufe: „Best", „#1", „Top",
  „New", „Free", „Sale", „Download now", „Install now", „Play now",
  Millionen-Downloads-Angaben
* keine Emojis, keine Sternchen-Symbole, keine wiederholten Satzzeichen
* keine GROSSBUCHSTABEN zur Betonung, keine Zeitangaben („jetzt", „neu")
* App-Name ≤ 30 Zeichen und identisch mit `config/app.json`

Die Werbesprache ist bewusst nüchtern: Play prüft das bei jedem Review neu, und
Rankings entstehen ohnehin nicht aus dem Listing-Text.

### Über den Rahmen hinaus sinnvoll

* **Was die App *nicht* ist** sagen (keine Werbung, kein Konto, offline) —
  das ist im Play-Bereich ein echtes Alleinstellungsmerkmal.
* Konkrete Spielnamen nennen, statt „viele Spiele" zu schreiben.
* Die Vorschlags-Funktion erwähnen: sie erklärt, warum die App bei Spielern
  ein eigenes Leben hat, und begründet die UGC-Deklaration (siehe
  [`COMPLIANCE.md`](COMPLIANCE.md)).
* Der Screenshot-Bereich zeigt Captions von bis zu 80 Zeichen — die hier
  vorbereiteten Captions sind im Listing-Formular in der richtigen Reihenfolge
  einzutragen.

## Grafiken

`npm run assets` erzeugt aus `godot/icon.svg` ohne Fremdbibliotheken:

| Datei | Größe | Verwendung |
|---|---|---|
| `assets/generated/icon-512.png` | 512×512 RGBA | Store-Icon |
| `assets/generated/feature-graphic-1024x500.png` | 1024×500 RGB | Feature Graphic |
| `assets/generated/icon-192.png` | 192×192 | Launcher (ohne adaptive icons) |
| `assets/generated/adaptive-background-432.png` | 432×432 | adaptive Icon, Hintergrundebene |
| `assets/generated/adaptive-foreground-432.png` | 432×432 | adaptive Icon, Vordergrundebene |
| `assets/generated/adaptive-monochrome-432.png` | 432×432 | Icon mit Farbschema des Systems |

Zwei bewusste Entscheidungen:

* Das Store-Icon ist **randlos gefüllt** (keine runden Ecken, kein Alpha am
  Rand). Play schneidet je nach Oberfläche Kreis oder Squircle zu — so wird
  immer nur Hintergrund abgeschnitten, nie das Motiv.
* Das adaptive Vordergrundbild hält das Motiv in der **mittleren
  Sicherheitszone** (66 %), weil Android adaptive Icons zusätzlich auf
  beliebige Formen zuschneiden kann.

Die vier Icon-Dateien lassen sich zusätzlich im Export-Preset verdrahten
(`launcher_icons/…`), dann bekommt die App auf dem Gerät ein echtes
adaptives Icon statt des exportierten Projekt-Icons.

Alternativ in GIMP/Blender/Inkscape nachbearbeiten: Der Generator ist nur die
Basis, `assets/` ist ausdrücklich für eigene Dateien gedacht.

## Screenshots

**Auf dieser Maschine nicht headless erzeugbar:** Godot nutzt im Headless-Modus
den Dummy-Renderer, der keine Frames zeichnet. `npm run screenshots` sagt das
sofort und mit Alternativen, statt minutenlang zu warten. Der Harness
(`scripts/playstore_shots.gd`) ist fertig und funktioniert auf jedem Rechner mit
Grafik:

```bash
npm run screenshots                      # Games: 2D, 3D, Lobby, Vorschlagsdialog
npm run screenshots lobby,tetris,dragonrpg:level=3
npm run screenshots -- --frames 12       # mehr Zeit zum Aufbau
```

Ohne Grafik: echte Screenshots auf dem Gerät aufnehmen

```bash
adb install -r ../build/singular80.apk
adb shell am start -n de.singular80.game/.GodotApp     # oder einfach starten
adb exec-out screencap -p > /tmp/shots/tetris.png
npm run screenshots -- --import /tmp/shots
```

Der Import normalisiert auf 1280×720 (16:9 quer), polstert statt zu beschneiden
— Play sieht lieber vollständige Screenshots —, entfernt Alpha und prüft die
Maße. Empfehlung: 3–4 Screenshots von verschiedenen Spielen plus Lobby; Google
zeigt Spiele bevorzugt mit drei 16:9-Bildern in der Empfehlungsleiste.

Reihenfolge der Motive für den ersten Eindruck:

1. begehbare 3D-Lobby (stärkster Wiedererkennungswert)
2. Tetris oder 2048 (sofort verständliche Mechanik)
3. Drachen-RPG (3D, Tiefe, Fortschritt)
4. Vorschlagsdialog (die Besonderheit erklären)

## Checkliste Store-Listing

- [ ] Icon 512×512 hochgeladen
- [ ] Feature Graphic 1024×500 hochgeladen
- [ ] Screenshots: mindestens 2, besser 3–4, 16:9
- [ ] Captions aus `listing/*.md` eingetragen
- [ ] Kurzbeschreibung aus `listing/*.md`
- [ ] Vollbeschreibung aus `listing/*.md`
- [ ] Kontakt-E-Mail öffentlich
- [ ] Datenschutz-URL erreichbar (Pflicht, sonst nicht speicherbar)
- [ ] *External marketing* geprüft: steht die App in Google-Empfehlungen, die
      an Kinder gerichtet sind? Bei Spielen mit Pokern besser aus
- [ ] `npm run preflight` läuft grün

## Quellen

* Preview-Assets: <https://support.google.com/googleplay/android-developer/answer/9866151>
* Store-Listing verwalten: <https://support.google.com/googleplay/android-developer/answer/9859152>
* Metadata-Richtlinie: <https://support.google.com/googleplay/android-developer/answer/9898843>
