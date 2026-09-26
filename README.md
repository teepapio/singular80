# Singular 80

Ein Spiel, das von seinen Spielern gebaut wird — **18 Spiele in einer Android-App**,
plus ein Web-Dashboard, das Ideen sammelt, priorisiert und zurück in das Spiel
spiegelt.

| | |
|---|---|
| **App** | Godot 4.5 (GDScript), Android 7.0+ (`arm64-v8a`), Release-APK 81 MB — schlank 29 MB |
| **Backend** | Fastify + SQLite, Content-Server, Discord-Bot, OpenCode-Runner |
| **Dashboard** | Vanilla-Web (Vite), bewusst nahezu unverändert |
| **Assets** | 168 Blender-GLBs in drei Auflösungen, keine Texturen — 2D wird prozedural gezeichnet |

## Die Spiele

**2D** — Arena-Survival · Tetris · Texas Hold'em · FreeCell · Dame · 2048 · Lobby-Liste
**3D** — begehbare Lobby · Mesh-Galerie · Candy Crush (6 Welten, 240 Level) ·
Crystal Jumper (3 Editionen) · Merge 3D (2 Editionen) · Pferde-Parcours 3D ·
Drachen-RPG 3D · Drachenflug · Metropol 3D · Pang 3D · Siedler 3D

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

## Vorschläge sagen von selbst, woher sie kommen

Jeder Vorschlag trägt den Bildschirm, aus dem er abgeschickt wurde — im Dialog
sichtbar als „Aus: Tetris“ und im Text als `Tetris: …`. Niemand muss mehr
tippen, welches Spiel gemeint ist, und das Dashboard kann die Ideen nach Herkunft
sortieren.

## Die Mesh-Galerie

In der Lobby führt ein Lichtring in einen runden Raum mit einem Sockel je Mesh.
Dort lässt sich jedes mitgelieferte Mesh in drei Auflösungen ansehen:

| Stufe | Dreiecke | Zweck |
|---|---|---|
| Low Poly | ~200 | die Fassung, die die Spiele benutzen |
| Mittel | ~1.000 | mehr Rundung, echte Kanten |
| Hoch | ~10.000 | zusätzlich mit Oberflächenrelief |

Ein Mesh vormerken, eine Notiz dazu schreiben, und alles zusammen geht als ein
**fertig ausgefüllter** Vorschlag ans Dashboard — inklusive Mesh-Schlüssel,
deutschem Namen, betrachteter Detailstufe und Dreieckzahl.

Die reicheren Stufen sind keine eigenen Modelle, sondern aus den Low-Poly-Meshes
abgeleitet (`scripts/blender/generate_lod_meshes.py`), damit die Geometrie in allen
drei Stufen identisch bleibt. Sie kosten zusammen rund 45 MB APK.

## Qualitätssicherung

```bash
npm run typecheck   # Server + Dashboard
npm test            # 54 Vitest-Tests + Content-Sync-Prüfung
npm run test:game   # GDScript-Suite: Regeln *und* echte Screens, headless
```

Die Spieltests fahren headless durch alle Screens, simulieren Züge (Tetris, Dame,
Karten, Arena inkl. Level-Up und Pause), prüfen die Asset-Registry exakt gegen den
Mesh-Ordner, die LOD-Stufen gegen ihre Dreieckbudgets und die Mesh-Galerie als
kompletten Durchlauf vom Vormerken bis zum abgeschickten Vorschlag.

## Aufbau

```
godot/            das Spiel: Autoloads, reine Logik, UI-Basisklassen, alle Screens
  assets/meshes/  GLBs in drei Stufen (Blender-Generator in scripts/blender/)
server/           Fastify-API, SQLite, Discord, OpenCode-Runner
src/dashboard/    Web-Dashboard
content/          einzige Quelle der Spieldaten (wird in die App gespiegelt)
scripts/          Content-Sync, Android-Template, API-Smoke, Blender-Meshes
tests/            Vitest für Server und Dashboard
```

Screens erben von genau zwei Basisklassen: `Screen` (2D) und `WorldScreen` (3D).
Beide bringen Top-Bar, Vorschlagsdialog, Theme, Kamera-Follow und Touch-Steuerung
mit — siehe `AGENTS.md` für den Erweiterungsweg.

## Lizenz

MIT
