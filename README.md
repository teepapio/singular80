# Singular 80

Ein Spiel, das von seinen Spielern gebaut wird — **13 Spiele in einer Android-App**,
plus ein Web-Dashboard, das Ideen sammelt, priorisiert und zurück in das Spiel
spiegelt.

| | |
|---|---|
| **App** | Godot 4.5 (GDScript), Android 7.0+ (`arm64-v8a`), Release-APK ca. 73 MB |
| **Backend** | Fastify + SQLite, Content-Server, Discord-Bot, OpenCode-Runner |
| **Dashboard** | Vanilla-Web (Vite), bewusst nahezu unverändert |
| **Assets** | 78 Blender-GLBs, keine Texturen, keine Bilddateien — 2D wird prozedural gezeichnet |

## Die Spiele

**2D** — Arena-Survival · Tetris · Texas Hold'em · FreeCell · Dame · 2048 · Lobby-Liste
**3D** — begehbare Lobby · Crystal Jumper (3 Editionen) · Merge 3D (2 Editionen) ·
Pferde-Parcours 3D · Drachen-RPG 3D

Jedes Spiel ist per Thumbstick, On-Screen-Buttons, Tastatur **und** Gamepad
bedienbar. Die 3D-Lobby ist begehbar: zu einer Kategorie-Plaza laufen, an einen
Sockel stellen, `E` drücken.

## Schnellstart

```bash
npm install

# Backend + Dashboard im Browser (http://localhost:5173/dashboard.html)
npm run dev

# Android-APK bauen  →  build/singular80.apk
npm run godot:apk:release
adb install -r build/singular80.apk
```

Die App startet ohne Server im **Offline-Modus** mit den mitgelieferten Inhalten.
Damit Vorschläge und Live-Content funktionieren, im Hauptmenü auf
`Server: offline` tippen und die Adresse des Backends eintragen
(z. B. `http://192.168.1.20:8787`). Offline eingereichte Vorschläge werden
nachgeholt, sobald wieder ein Server erreichbar ist.

## Qualitätssicherung

```bash
npm run typecheck   # Server + Dashboard
npm test            # 54 Vitest-Tests + Content-Sync-Prüfung
npm run test:game   # 742 GDScript-Tests: Regeln *und* echte Screens
```

Die Spieltests fahren headless durch alle 13 Spiele, simulieren Züge
(Tetris, Dame, Karten, Arena inkl. Level-Up und Pause) und prüfen, dass die
Asset-Registry exakt zum Mesh-Ordner passt.

## Aufbau

```
godot/            das Spiel: Autoloads, reine Logik, UI-Basisklassen, 13 Screens
  assets/meshes/  78 GLBs (Blender-Generator in scripts/blender/)
server/           Fastify-API, SQLite, Discord, OpenCode-Runner
src/dashboard/    Web-Dashboard
content/          einzige Quelle der Spieldaten (wird in die App gespiegelt)
scripts/          Content-Sync, API-Smoke, Blender-Mesh-Generator
tests/            Vitest für Server und Dashboard
```

Screens erben von genau zwei Basisklassen: `Screen` (2D) und `WorldScreen` (3D).
Beide bringen Top-Bar, Vorschlagsdialog, Theme, Kamera-Follow und Touch-Steuerung
mit — siehe `AGENTS.md` für den Erweiterungsweg.

## Lizenz

MIT
