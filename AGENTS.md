# AGENTS.md — Singular 80

Godot-4-Spiel (Android) + Fastify-Backend + Web-Dashboard. Die App läuft offline
komplett; mit konfigurierter Server-Adresse holt sie Content und Vorschläge vom
Backend.

## Befehle

- `npm run typecheck` — `tsc --noEmit`, muss fehlerfrei sein.
- `npm test` — prüft zuerst den Content-Sync, dann `vitest run` (Server/Dashboard).
- `npm run test:game` — **742 GDScript-Tests** (headless, Regeln + echte Screens).
- `npm run build` — Vite-Build des Dashboards.
- `npm run content:sync` — `content/*.json` nach `godot/assets/content/` spiegeln
  (Pflicht vor jedem Godot-Build; `npm test` schlägt bei Abweichung fehl).
- `npm run godot:import` — Content spiegeln + Godot-Import der Assets.
- `npm run godot:apk` — Debug-APK, `npm run godot:apk:release` — signiertes Release.
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
│   ├── meshes/               78 Blender-GLBs (+ rpg/-Unterordner)
│   ├── content/              gespiegelte content/*.json
│   └── fonts/                DejaVu Sans (normal + fett)
├── src/
│   ├── main.gd               Boot, Backend-Probe im Hintergrund
│   ├── core/
│   │   ├── autoload/         InputSetup, Game, Content, Sfx, Api, Router
│   │   ├── logic/            reine Spiellogik (Renderer-frei, testbar)
│   │   │   ├── asset_registry.gd   zentrale Mesh-Liste (Key → Pfad)
│   │   │   ├── game_registry.gd    Kategorien + alle 13 Spiele
│   │   │   ├── lobby.gd            Geometrie der 3D-Lobby
│   │   │   ├── inventory.gd        generisches Inventarsystem
│   │   │   ├── checkers/cards/holdem/twenty48/merge3d/
│   │   │   ├── crystal_tower/dragon_rpg/horse_runner
│   │   │   └── mechanics/          Mechanik-Registry + Dash
│   │   └── ui/                Screen/WorldScreen-Basis, Theme, Widgets,
│   │                          VirtualStick, Kartenrenderer, Dialoge
│   └── game/<spiel>/          ein Verzeichnis je Spiel (s. u.)
└── tests/                    TestKit + Regel- und Screentests
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

### Performance-Regeln

- Keine Allokationen im `_process`/`_update_world`: Pools vorallozieren
  (Arena: 220 Gegner, 400 Geschosse, 160 Kristalle).
- `_draw()` nur bei Änderung (`queue_redraw()`), nie im Takt neu aufbauen.
- 3D-Materialien entstehen einmalig über `WorldScreen.tint()` /
  `WorldScreen.standard_material()`; `StandardMaterial3D` nicht pro Frame anlegen.
- Meshes kommen **ausschließlich** über `AssetRegistry`/`WorldScreen.mesh()`.

### Meshes

- Format: binäres glTF 2.0 (`.glb`), Godot importiert nativ.
- Erzeugen: `blender --background --python scripts/blender/make_mesh.py -- --out … --name <builder>`
  bzw. `scripts/blender/generate_rpg_meshes.py` für den Drachen-Pack.
- Jedes neue Mesh braucht einen Key in `AssetRegistry.KEYS` — der Test
  `Asset-Registry` schlägt fehl, wenn Liste und Ordner auseinanderlaufen.
- Fehlt ein Mesh, benutzt `WorldScreen.mesh()` ein prozedurales Primitiv;
  3D-Spiele starten dadurch nie mit leerer Szene.

### Android

- `project.godot`: `renderer/rendering_method = gl_compatibility` (breite
  Geräteabdeckung), `stretch/mode = canvas_items`, `aspect = expand`.
- 2D-Spiele mit festem Layout bauen in `stage()` (1280×720, zentriert);
  Menüs in `content_layer()` (füllt das Fenster) mit Containern.
- Keine Godot-Editor-Komponenten zur Laufzeit; keine externen Dateien zur Laufzeit.
