# AGENTS.md — Singular 80

Godot-4-Spiel (Android) + Fastify-Backend + Web-Dashboard. Die App läuft offline
komplett; mit konfigurierter Server-Adresse holt sie Content und Vorschläge vom
Backend.

> **Achtung, gemeinsamer Arbeitsbaum:** Der Runner (`server/runner.ts`) startet für
> eingereichte Vorschläge einen zweiten Agenten im selben Verzeichnis. Vor dem
> Commit `git status` prüfen und nur die eigenen Dateien stagen — fremde, halb
> fertige Änderungen weder committen noch zurücksetzen. Zum Prüfen gegen HEAD
> eine Kopie in `/tmp` anlegen und dort die Suite laufen lassen.

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
- Reihenfolge für Änderungen: `typecheck` → `test` → `test:game` → `build` → `godot:apk`.

## Struktur

- `godot/` — das gesamte Spiel (GDScript). Siehe unten.
- `server/` — Fastify-API, SQLite, Discord, OpenCode-Runner. **Nicht ändern**,
  außer der Vorschlag verlangt es ausdrücklich.
- `src/dashboard/`, `dashboard.html` — Web-Dashboard, möglichst unverändert.
- `src/shared/` — geteilte Typen/Sortierung. Nicht ändern.
- `content/*.json` — **einzige** Quelle für Spieldaten.
- `godot/assets/content/` — Spiegel davon für die App (nie direkt editieren).
- `scripts/blender/` — headless Blender-Generator für die 3D-Meshes.
- `log/` — JSONL-Log pro KI-Run (nicht committen).

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
- 2D-Spiele mit festem Layout bauen in `stage()` (1280×720, zentriert);
  Menüs in `content_layer()` (füllt das Fenster) mit Containern.
- `config/name` muss ein gültiger Android-Identifier sein (kein Leerzeichen);
  der schöne Anzeigename steht in `package/name` im Export-Preset.
- Keine Godot-Editor-Komponenten zur Laufzeit; keine externen Dateien zur Laufzeit.
