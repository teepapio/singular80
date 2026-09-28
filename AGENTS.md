# AGENTS.md — Singular 80

Godot-4-Spiel (Android) + Fastify-Backend + Web-Dashboard. Die App läuft offline
komplett; mit konfigurierter Server-Adresse holt sie Content und Vorschläge vom
Backend.

> **Achtung, gemeinsamer Arbeitsbaum:** Der Runner (`server/runner.ts`) startet für
> eingereichte Vorschläge einen zweiten Agenten im selben Verzeichnis. Vor dem
> Commit `git status` prüfen und nur die eigenen Dateien stagen — fremde, halb
> fertige Änderungen weder committen noch zurücksetzen. Zum Prüfen gegen HEAD
> eine Kopie in `/tmp` anlegen und dort die Suite laufen lassen.

> **Achtung, `git push` ist Pflicht, nicht Kür:** Ein Commit, der nur lokal
> existiert, ist für den Besitzer verloren — er sieht ihn nie, und dieser Zweig
> hier hat 54 Commits, 387 Dateien und rund 50.000 Zeilen angesammelt, ohne dass
> eines davon auf GitHub ankam. Details und die Branch-Frage unten.

## Nach dem Commit: pushen

`git push origin main` — **in derselben Sitzung, in der du committet hast.**

Ein Commit ist ein Versprechen an *diesen* Arbeitsbaum, nicht an den Besitzer.
Der Besitzer arbeitet mit GitHub, nicht mit `git log`: was er dort nicht sieht,
existiert für ihn nicht. Der Unterschied ist billig zu reparieren, solange er
noch da ist, und uninterreparabel, wenn der Rechner neu aufgesetzt wird.

- **Ein Push pro Sitzung reicht**, am Ende — nicht nach jedem Commit.
- **Vorher `git status`**: niemals `git add -A`, nur die eigenen Dateien (siehe
  oben). Was du nicht committen darfst, schiebst du auch nicht.
- **Nur `main`, keine Branches** für normale Arbeit. Der Besitzer arbeitet nicht
  mit Pull Requests; ein Feature-Branch ohne Merge ist für ihn dasselbe wie
  nicht existent. Branches sind ausschließlich für *eine* Sache da: halbfertige
  Arbeit zu parken, die `main` grün hält (siehe „Parken statt Merge").
- **Vor dem Push prüfen**, dass keine Geheimnisse mitgehen: das Repo ist
  **öffentlich** (`teepapio/singular80`). `.env`, `*.pem`, `*.keystore`,
  Datenbanken und APK-Bauartefakte gehören nicht hinein — `.gitignore` deckt
  das ab, aber eine erzwungene `git add -f` umgeht es.
- **Schlägt der Push fehl** (kein Netz, falscher Schlüssel), ist das ein Blocker
  für den Abschluss der Sitzung, kein Detail: `git status -sb` muss am Ende
  `## main...origin/main` **ohne** `ahead` zeigen. Sonst steht die Arbeit
  wieder nur hier.

**Prüf-Befehl für den Besitzer:** `git status -sb | head -1`. Steht dort
`ahead`, ist etwas nicht auf GitHub.

### Parken statt Merge

Liegt fremde, halbfertige Arbeit im Baum (typisch nach einem abgebrochenen
Runner-Lauf) und lässt sie sich nicht sauber fertigstellen, wird sie **nicht
verworfen und nicht auf `main` gemischt**, sondern auf einen Neben-Branch
geparkt und der gepusht:

```bash
git stash push -u -m "WIP" -- <nur diese Dateien>   # oder: auf Branch committen
git switch -c wip/<kurze-beschreibung>
git push -u origin wip/<kurze-beschreibung>
```

So liegt die Arbeit auf GitHub, `main` bleibt grün, und sie ist später greifbar.
Vorher `npm run typecheck` laufen lassen — halbfertige Arbeit bricht erfahrungsgemäß
genau dort, und ein geparkter Branch ist der richtige Ort dafür, nicht `main`.

## Sprache im Code

**Kommentare auf Englisch.** Der Besitzer liest den Code nicht, aber er
bezahlt für ihn, und ein deutscher Kommentar in einer englischen Codebasis
sieht nach einer zweiten Sprache aus, die niemand mehr pflegt. Doc-Kommentare
(`## …`) und `//`-Zeilen auf Englisch, im Tonfall der vorhandenen englischen
Kommentare. **Die Oberfläche des Spiels bleibt deutsch** — das ist etwas
anderes: `Ui.label("Server: %s")`, `toast('Run gestartet')` und alle
Meldungstexte gehören dem Spieler, nicht dem Code.

Ausnahmen, in denen Deutsch im Kommentar richtig ist: ein Zitat aus dem
Spiel, ein deutscher Terminus technicus, oder ein Kommentar, der eine
deutsche Bedienoberfläche erklärt.

## Changelog

`CHANGELOG.md` bekommt **einen Eintrag mit ein bis zwei Zeilen pro
umgesetztem Vorschlag** — im Spiel, im Dashboard, in Telegram. Kein
Absatz, keine Liste von Dateien; die Zeile sagt, was sich für den Spieler
geändert hat, und der Commit-Hash dahinter sagt, wo.

Geschrieben wird die Datei **vom Runner**, nicht vom Agenten, der den
Vorschlag umgesetzt hat (`server/changelog.ts`, aufgerufen in `runner.ts` bei
`status === 'succeeded'`). Grund: nur der Runner weiß mit Sicherheit, dass
der Lauf erfolgreich war. Ein Agent, der sich selbst in die Changelog
lobt, kann das ebenso für einen Lauf tun, der fehlgeschlagen ist.

Der Commit **rührt nur `CHANGELOG.md` an**, mit ausdrücklichem Pfad
(`git commit -- CHANGELOG.md`) und wird gepusht. Ein `git add -A` hier würde
die halbfertige Arbeit einer fremden Sitzung mitnehmen — siehe oben. Ein
Fehlschlag ist eine fehlende Zeile, **kein** Anlass, einen guten Lauf als
fehlgeschlagen zu melden.

## Kurze Abschlussberichte

**Der Bericht am Ende einer Aufgabe ist kurz.** Höchstens fünf Stichpunkte,
und nur was eine Entscheidung ändert oder verlangt:

- Was geändert wurde — in einem Satz, nicht in einer Aufzählung von Dateien.
- Was der Besitzer tun muss, mit dem konkreten Befehl oder der Reihenfolge.
- Was **nicht** fertig ist oder warum etwas nicht ging.
- Ein Sicherheits- oder Datenverlustrisiko, wenn es eines gibt.

Kein "Ich habe X geprüft", kein "die Tests laufen durch", keine Wiederholung
desselben Punkts in zwei Formulierungen. Wer eine Datei oder Zeile braucht,
schaut in den Commit. Ein Bericht, den niemand liest, ist genauso wertlos
wie ein Changelog, das keiner pflegt.

## Vor der ersten Änderung

Drei Sekunden, die in dieser Sitzung einen halben Tag ersetzt haben:

1. **`git status` lesen.** Der Runner kann eine Arbeit halbfertig liegen lassen
   und dabei den Index ruinieren. Der Zustand, der hier auftrat: acht Dateien
   im Index als *gelöscht*, obwohl sie byte-identisch auf der Platte lagen, und
   vier Dateien mit gestaged Änderung, die im Arbeitsbaum exakt zurückgenommen
   war. Beides sieht harmlos aus und ist es nicht — `git add -A` nimmt es mit.
   Ist der Index veraltet: `git reset` (nichts geht verloren, es ändert nur den
   Index) und die Dateien neu stagen. **Nichts zurücksetzen, was dir nicht
   gehört.**
2. **`node scripts/scopes.mjs list`** — beendet sich mit Code 1 bei jedem
   Manifest-Fehler. Eine Suite, die in keinem Scope steht, läuft in einem
   Scoped-Lauf *stillschweigend nicht*: der Agent, der sie geschrieben hat,
   glaubt, sie sei geprüft.
3. **`godot --headless --path godot --import`**, sobald du eine neue Datei mit
   `class_name` angelegt hast. Siehe unten — das ist der teuerste Fehler
   überhaupt.

## Neue `class_name` → sofort importieren

`--script`-Modus erneuert den globalen Klassen-Cache **nicht**. Eine neue
`class_name` ist damit bis zum nächsten Import unbekannt, und der Fehler
verschiebt sich dorthin, wo man nicht suchen würde:

- `Screen`/`WorldScreen` parst nicht mehr, **jeder** Screen des Spiels lädt
  nicht mehr, der Router bleibt im Lobby-Screen. Ein Test meldet dann
  „Es ist der 2048-Screen nicht" und prüft dann Eigenschaften eines
  `Lobby3DScreen`.
- Die Suite **hängt** sich tot, weil der Absturz vor `quit()` passiert.

Beides hat in dieser Sitzung gleichzeitig ausgesehen wie „ein kaputter Bildschirm
und ein hängender Test". Nach jeder neuen `class_name` also einmal importieren;
bestehende Suites laden ihre Module bewusst per Pfad (`load("res://…")`) statt
per Klassenname, genau aus diesem Grund.

## Testsuite registrieren: zwei Stellen, nicht eine

Eine neue Suite `t.suite("…")` in `godot/tests/test_<id>.gd` ist **halb**
registriert, bis beides gilt:

- `SCOPE_SUITES` in `scripts/scopes.mjs` — sonst läuft sie in keinem
  Scoped-Lauf mit.
- `godot/tests/run_tests.gd` — sonst lädt der Runner die Datei nie und sie läuft
  auch im Volllauf nicht. GDScript kann die Dateien nicht selbst finden
  (unterschiedliche Parameterzahl, `await`-Probleme beim `call()`), der Runner
  bleibt deshalb handgepflegt; beide Prüfungen laufen über `npm test`.

`npm test` schlägt inzwischen fehl, wenn eine Suite in keinem Scope steht oder
eine `test_*.gd` nicht geladen wird — diese Lücke war lange offen und hat
gleichzeitig sechs nicht registrierte Suites und eine nie geladene Testdatei
durchgewunken.

## Exportieren und Artefakte prüfen

- **Relative Exportpfade zählen gegen `godot/`, nicht gegen das Repo-Root.**
  `build/x.apk` bedeutet `godot/build/x.apk` und der Export bricht mit
  „Target folder does not exist" ab. Immer absolut übergeben.
- **`exclude_filter` erreicht importierte Ressourcen nicht.** Godot wendet ihn
  auf Nicht-Ressourcen an, ein importiertes `.glb` ist aber eine Ressource:
  gemessen lagen mit `assets/meshes/med/*, assets/meshes/high/*` im Filter alle
  310 reicheren Meshes trotzdem im Paket. `export_filter="exclude"` ist
  schlimmer — es packt die Roh-`.glb`, und ein exportiertes Spiel kann eine
  Roh-`.glb` gar nicht laden. Was wirkt, ist eine `.gdignore` je Ordner.
- **„Export erfolgreich" ist kein Beweis.** Ein schlankes Build kann 120 MB
  wiegen und trotzdem korrekt exiten. `googleplay/scripts/build-apk-slim.mjs`
  prüft den Inhalt (Meshes, `lod.json`, keine Roh-`.glb`); für alles andere
  gilt: das Ergebnis messen, nicht behaupten.
- **Größenangaben in den Docs sind Messungen.** Wenn sich ein Preset ändert,
  neu bauen und die Zahl nachtragen.

## Was ein headless Test nicht sieht

`is_touchscreen_available()` ist unter `npm run test:game` false, es wird also
mit der Maus getestet. Gerätekonfiguration und Nur-Touch-Verhalten fallen
dadurch vollständig durch — echtes Beispiel: `pointing/emulate_mouse_from_touch`
stand auf `false`, und auf dem Tablet war **jeder Knopf des Spiels tot, weil
Godots `Button` auf `InputEventMouseButton` reagiert und ein Fingerdruck nur ein
`InputEventScreenTouch` liefert. Der VirtualStick funktionierte, weil er Touch
selbst auswertet; das Bildschirm-Logbuch sah „Joystick geht, Knöpfe nicht".

Wenn eine Eingabe auf dem Gerät nicht ankommt: erst `project.godot` unter
`[input_devices]` lesen, dann in `res://log/touch/` nach Screenshots schauen,
dann auf dem Gerät messen (`adb` + Logcat). Für das Anhängen von Bildern und
das Auswerten von Logcat gibt es die Agenten `apk` und `device-debug`.


## Befehle

- `npm run typecheck` — `tsc --noEmit`, muss fehlerfrei sein.
- `npm test` — prüft zuerst den Content-Sync, dann `vitest run` (Server/Dashboard).
- `npm run test:game` — **headless GDScript-Suite** (Regeln *und* echte Screens).
- `npm run build` — Vite-Build des Dashboards.
- `npm run content:sync` — `content/*.json` nach `godot/assets/content/` spiegeln
  (Pflicht vor jedem Godot-Build; `npm test` schlägt bei Abweichung fehl).
- `npm run godot:import` — Content spiegeln + Godot-Import der Assets.
- `npm run godot:apk` — Debug-APK, `npm run godot:apk:release` — signiertes Release.
- `npm run godot:android-template` — Godot-Android-Build-Template installieren
  (läuft in `godot:apk*` automatisch mit).
- `npm run smoke` — API-Smoke-Test.
- `npm run backup` — Dashboard-Historie als JSON ins Repository schreiben
  (`-- write`), von dort einlesen (`-- read`) oder nur den Stand melden.
- Reihenfolge für Änderungen: `typecheck` → `test` → `test:game` → `build` → `godot:apk`.

## Struktur

- `godot/` — das gesamte Spiel (GDScript). Siehe unten.
- `server/` — Fastify-API, SQLite, Discord, OpenCode-Runner. **Nicht ändern**,
  außer der Vorschlag verlangt es ausdrücklich.
- `src/dashboard/`, `index.html` — Web-Dashboard, möglichst unverändert. `/` ist
  das Dashboard; `dashboard.html` ist nur noch der Weiterleiter für alte Links.
- `src/shared/` — geteilte Typen/Sortierung. Nicht ändern.
- `content/*.json` — **einzige** Quelle für Spieldaten.
- `godot/assets/content/` — Spiegel davon für die App (nie direkt editieren).
- `scripts/blender/` — headless Blender-Generator für die 3D-Meshes.
- `backup/dashboard.json` — **gehört ins Git**: die Historie des Dashboards
  (Vorschläge, Entscheidungen, Stimmen, Runs mit Commit). Siehe unten.
- `log/` — JSONL-Log pro KI-Run (nicht committen).

## Agenten-Runner (Dashboard)

`server/runner.ts` startet für jeden Auftrag eine echte `opencode run`-Sitzung
im gemeinsamen Arbeitsbaum. Drei Dinge sind inzwischen wichtig.

**Spuren statt einer Schlange.** `maxParallelRuns` (Einstellungen im Dashboard,
1–8, Vorgabe 3) ist die Zahl der gleichzeitigen Sitzungen. Eine wartende Arbeit
startet nur, wenn eine Spur frei ist **und** kein laufender Run ihren Scope schon
beansprucht — die Regel ist `scopesConflict` in `server/scopes.ts` und sie
entscheidet nach dem *primären* Scope. Das ist Absicht und kein Versehen:
`scopeForSuggestion` hängt an jeden Spielauftrag noch die breite Kategorie
(`core`, `content`), und ein Vergleich der ganzen Scope-Liste würde Tetris und
Pang deshalb wieder hintereinander einreihen.

Was das offen lässt, wird nicht versteckt: Zwei verschiedene Spiele *dürfen* beide
auf `content/` oder `core/` zeigen. Der Scope-Audit meldet es pro Run
(`shared: [...]`), und das Panel beschriftet ein solches Paar
(`laneRisks` in `src/dashboard/queueControls.ts`). Ein Run ohne bekannten Scope
oder mit breitem primären Scope bekommt den Baum immer allein.

**Direkte Aufträge.** `POST /api/tasks` (im Panel: „Direkter Auftrag an OpenCode")
legt eine Empfehlung mit `source: 'operator'` an und stellt sie sofort in die
Schlange — ohne Abstimmung, ohne Spieler, ohne Discord. Sie bleibt eine
Empfehlung, damit Scope-Vorhersage, Wiederholung, Commit-Schutz und Historie
alles weiter funktionieren; nur `status` startet auf `approved`.

**Backup im Repository.** `backup/dashboard.json` enthält Vorschläge,
Entscheidungen, Stimmen und Runs und **gehört committet** — `data/` ist
ignoriert, und genau deshalb wäre die Historie sonst mit der Datenbank weg.
`npm run backup -- write` schreibt sie, `npm run backup -- read` führt sie als
Merge ein (neuere lokale Daten gewinnen, Ids bleiben, ein unfertiger Run aus der
Datei kommt als `cancelled` an). Der Prompt jedes Runs steht **nicht** in der
Datei: er ist aus Empfehlung und Einstellungen ableitbar und wird beim Import neu
gebaut.

## Godot-Spiel

```
godot/
├── main.tscn                 Einstieg → src/main.gd → Router.go_to("lobby")
├── project.godot             Autoloads, Eingaben, Renderer (gl_compatibility)
├── export_presets.cfg        Android-APK (arm64, minSdk 24, targetSdk 35)
├── assets/
│   ├── meshes/               Low-Poly-GLBs (+ med/, high/, lod.json)
│   ├── content/              gespiegelte content/*.json
│   └── fonts/                DejaVu Sans (normal + fett)
├── src/
│   ├── main.gd               Boot, Backend-Probe im Hintergrund
│   ├── core/
│   │   ├── autoload/         InputSetup, Game, Content, Sfx, Api, Router
│   │   ├── logic/            reine Spiellogik (Renderer-frei, testbar)
│   │   │   ├── asset_registry.gd    Mesh-Keys, Kategorien, LOD-Stufen
│   │   │   ├── game_registry.gd     Kategorien + alle Spiele
│   │   │   ├── mesh_gallery.gd      Galerie-Geometrie, Merkliste, Vorschlag
│   │   │   ├── suggestion_context.gd  Herkunft eines Vorschlags
│   │   │   ├── tetris_rules.gd      T-Spins, Punkte, B2B, Brettgefahr
│   │   │   ├── arena_runs.gd        Wellenvorschau, Boss-Ansage, Kill-Ketten
│   │   │   ├── lobby.gd             Geometrie der 3D-Lobby
│   │   │   ├── candy_match3.gd      Match-3: Züge, Spezialbonbons, 6 Welten × 40 Level
│   │   │   ├── inventory.gd         generisches Inventarsystem
│   │   │   └── …                    Karten, 2048, Merge, Kristall, Drache …
│   │   └── ui/                Screen/WorldScreen-Basis, Theme, Widgets,
│   │                          VirtualStick, Kartenrenderer, Dialoge
│   └── game/<spiel>/          ein Verzeichnis je Spiel (s. u.)
└── tests/                    TestKit, Regel-, Verbesserungs- und Screentests
```

### Ein Spiel hinzufügen

1. `godot/src/game/<name>/<name>_screen.gd` anlegen.
2. **2D:** `extends Screen`. **3D:** `extends WorldScreen`. Nichts anderes erben.
3. `Ui.*`-Helfer für Widgets benutzen, **keine** `.tscn` schreiben — jeder Screen
   baut seinen Baum in `_ready_game()` bzw. `_ready_world()`.
4. Eingabe ausschließlich über `Input`-Actions (siehe `InputSetup`) und
   `VirtualStick.combined(...)`; für 3D `add_stick()` / `add_action_button()`.
5. In `game_registry.gd` eintragen (id, name, icon, screen, accent, category,
   highscore_key) und in `router.gd` den Screen-Pfad mappen.
6. Logo-Icon: **DejaVuschrift** kann ♠♥♦♣♞☄✦◆▣▦◼ u. a. — keine Emojis.
7. Hochscore über `Game.submit_score(<key>, wert)`, niemals selbst speichern.

### Basisklassen

`Screen` (2D) und `WorldScreen` (3D) bringen Top-Bar, Vorschlagsdialog, Theme,
Kamera-Follow und Touch-Steuerung mit.

- **Namen der Basisklasse nicht überschreiben.** Ein Unterklasse, die
  `_build_hud`/`_build_environment`/`show_toast` selbst definiert, bricht die
  Basis. Eigene Einstiegspunkte heißen `_ready_game`, `_ready_world`,
  `_update_world`, `_build_ui`, `_build_panels`, `_build_scenery`.
- Für eine kurze Meldung im 3D `notify(text)` benutzen (nicht `show_toast`).
- `WorldScreen.mesh(key, …)` nimmt einen Registry-**Key** oder einen fertigen
  `res://`-Pfad (für die LOD-Stufen) und liefert `null`, wenn der Import fehlt.

### Level-Spiele (Sterne)

`Game.stars(game_id, key)`, `Game.submit_stars(game_id, key, wert)` und
`Game.star_map(game_id, keys)` speichern Sterne unter `number.stars/…`. Ein
Level-Schlüssel ist die globale Levelnummer (`"7"`), das Tageslevel `"daily:JJJJ-MM-TT"`.
`CandyMatch3.world_stars(levels, welt_id)` zählt die Sterne einer Welt, und
`world_bonus(stars)` übersetzt sie in Extras (Züge, Undo, Start-Farbbombe).
`star_max` im `GameRegistry`-Eintrag sagt der Lobby, wie viele Sterne es gibt.

### Vorschläge

`SuggestDialog.open(self, kontext)` bzw. `open_world(self, kontext)`. Ohne
`kontext` wird der aktive Bildschirm als Herkunft eingesetzt und dem Text
vorangestellt (`SuggestionContext.compose`), damit niemand „geht um Tetris“
tippen muss. `Api.submit_suggestion(text, author, kontext)` macht das gleiche für
Aufrufe außerhalb des Dialogs.

**Ohne eingetragene Server-Adresse geht ein Vorschlag nirgends hin**, er landet
in `user://` und wartet. Die Adresse ist deshalb über `ServerDialog`
(`godot/src/core/ui/server_dialog.gd`) von **jedem** Bildschirm aus erreichbar —
sie lag vorher nur im Menü des Arena-Spiels, also genau nicht dort, wo jemand
sie braucht, der Tetris spielt. `ServerDialog.apply()` setzt die Adresse **und
stößt die Warteschlange sofort an**; ohne das `Api.wake()` wartet die Idee noch
bis zu `BACKOFF_MAX` (5 Minuten), obwohl die Adresse längst stimmt. Der
Hauptbildschirm zeigt die wartende Zahl samt Grund an.

### Performance-Regeln

- Keine Allokationen im `_process`/`_update_world`: Pools vorallozieren
  (Arena: 220 Gegner, 400 Geschosse, 160 Kristalle; Drachen-RPG: 24 schwebende
  `Label3D` aus `_build_label_pool`).
- `_draw()` nur bei Änderung (`queue_redraw()`), nie im Takt neu aufbauen.
- 3D-Materialien entstehen einmalig über `WorldScreen.tint()` /
  `WorldScreen.standard_material()`; `StandardMaterial3D` nicht pro Frame anlegen.
- Meshes kommen **ausschließlich** über `AssetRegistry`/`WorldScreen.mesh()`.

### Meshes und Detailstufen

- Format: binäres glTF 2.0 (`.glb`), Godot importiert nativ.
- Erzeugen: `blender --background --python scripts/blender/make_mesh.py -- --out … --name <builder>`
  bzw. `scripts/blender/generate_rpg_meshes.py` für den Drachen-Pack.
- **Jedes neue Mesh braucht einen Key in `AssetRegistry.KEYS`** — zwei Tests
  schlagen fehl, wenn Liste und Ordner auseinanderlaufen.
- Fehlt ein Mesh, benutzt `WorldScreen.mesh()` ein prozedurales Primitiv;
  3D-Spiele starten dadurch nie mit leerer Szene.
- Jedes Mesh liegt in drei Stufen: `assets/meshes/<key>.glb` (Low, das benutzen
  die Spiele), `assets/meshes/med/<key>.glb` (~1.000 Dreiecke) und
  `assets/meshes/high/<key>.glb` (~10.000 Dreiecke, mit Displacement).
  Neu erzeugen:
  ```bash
  blender --background --python scripts/blender/generate_lod_meshes.py -- \
      --out godot/assets/meshes --stats godot/assets/meshes/lod.json
  ```
  Das Skript misst die Dreieckzahlen und schreibt sie nach `lod.json`; die
  Galerie zeigt sie an, der Test prüft `med ≥ low` und `high ≥ med`.
  **Nach jedem neuen Mesh erneut laufen lassen**, sonst fehlen die höheren Stufen.
- Die beiden reichen Stufen kosten zusammen rund 45 MB APK. Ohne sie wird das
  Release gut 80 MB kleiner — dafür zeigt die Galerie nur ein einziges Mesh.
- `include_filter="*.json"` im Export-Preset ist Pflicht: `.json` wird nicht
  importiert und käme sonst nicht ins Paket (die Galerie braucht `lod.json`).

### Android

- `project.godot`: `renderer/rendering_method = gl_compatibility` (breite
  Geräteabdeckung), `stretch/mode = canvas_items`, `aspect = expand`.
- `pointing/emulate_mouse_from_touch` **muss `true` bleiben.** Godots `Button`
  reagiert auf `InputEventMouseButton`; mit `false` liefert ein Fingerdruck nur
  ein `InputEventScreenTouch` und damit ist auf dem Tablet jeder Knopf tot,
  während der VirtualStick funktioniert, weil er Touch selbst auswertet. Der
  Fehler sieht aus wie „Bildschirm kaputt" und ist es nicht.
- 2D-Spiele mit festem Layout bauen in `stage()` (1280×720, zentriert);
  Menüs in `content_layer()` (füllt das Fenster) mit Containern.
- `config/name` muss ein gültiger Android-Identifier sein (kein Leerzeichen);
  der schöne Anzeigename steht in `package/name` im Export-Preset.
- Keine Godot-Editor-Komponenten zur Laufzeit; keine externen Dateien zur Laufzeit.

## Android-Testfarm

`tools/devfarm/` fährt echte Android-Instanzen hoch, mehrere parallel, und
steuert die App so, wie ein Spieler es tut. Ausführlich in
`tools/devfarm/README.md`.

```bash
npm run farm:doctor     # sagt, was fehlt, statt zu raten
npm run farm:bridge     # Schleife, läuft als eigener Prozess weiter
npm run farm:start      # Instanzen aufziehen
npm run farm:status
npm run farm:session -- --game tetris --audit --shots 2
npm run farm:sweep      # alle Spiele nacheinander
```

- **Nicht Waydroid.** Waydroid braucht `binder_ls` und `ashmem`; der
  Ubuntu-Mainline-Kernel hat sie nicht. Die Farm redet nur mit `adb` und ist
  damit backend-neutral — Emulator, Waydroid-Container oder ein Tablet an USB
  erfüllen dieselbe Schnittstelle.
- **Ein AVD, N Instanzen** über `-read-only`. Ohne das Flag teilen sich die
  Instanzen ein userdata-Image, und die erste schreibt darauf, während die
  zweite noch bootet — die Sorte Absturz, die man dem Werkzeug nicht anlasten
  will.
- **Ein eigenes Farm-APK** (`Android (Farm)`), weil das ausgelieferte arm64-only
  ist und ein x86_64-Emulator es mit „no matching ABI" ablehnt. Eigener
  Paketname `de.singular80.farm`, damit die Farm neben dem echten Spiel liegt
  und dessen Spielstand nicht anfasst.
- **Der Audit ist das Wichtigste.** Er schickt für jeden Knopf einen echten
  `InputEventScreenTouch` auf seine Mitte und prüft Fläche, Deckung und ob
  `pressed` kommt. Damit findet er zugedeckte und nicht verdrahtete Knöpfe —
  beides sieht im Screenshot tadellos aus und fällt im headless Test nie auf,
  weil dort `is_touchscreen_available()` false ist.
- **Eine Instanz pro Agent zur Zeit**, gehalten über `flock` auf einer Datei.
  `session.mjs` gibt die Lease im `finally` frei, und stirbt der Agent, gibt
  der Kernel sie frei. Ein Agent darf also drei Fehler an drei Spielen
  **gleichzeitig** suchen; sie landen auf drei Instanzen.
- Der Bericht ist `log/devfarm/<lauf>/<spiel>/report.json` — maschinenlesbar,
  damit ein Agent Zahlen liest, statt Bilder anzusehen.
