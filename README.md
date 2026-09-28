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

# Backend + Dashboard im Browser (http://localhost:5173/)
npm run dev

# Android-APK bauen  →  build/singular80.apk
npm run godot:apk:release
adb install -r build/singular80.apk
```

Die App startet ohne Server im **Offline-Modus** mit den mitgelieferten Inhalten.
Damit Vorschläge und Live-Content funktionieren, unten auf `Server: offline`
tippen — oder das Zahnrad `⚙` in der Leiste jedes Bildschirms öffnen, wo die
Adresse neben Sprache, Ton und Touch-Steuerung steht — und die Adresse des
Backends eintragen (z. B. `http://192.168.1.20:8787`). Offline eingereichte
Vorschläge bleiben auf dem Gerät und gehen raus, sobald die Adresse eingetragen
ist oder wieder ein Server erreichbar wird — der Hauptbildschirm sagt beide
Male, wie viele warten.

## Drei Sprachen, ein Zahnrad

Das Spiel spricht **Deutsch, Englisch und Französisch**. Umgestellt wird über den
`⚙`-Knopf oben in der Leiste jedes Bildschirms — dort stehen neben der Sprache
auch Ton, Touch-Steuerung und die Server-Adresse. Jeder Bildschirm benennt sich
in der eingestellten Sprache, das Menü zeigt „Deutsch", „English",
„Français".

Die Texte liegen in `locale/*.json` und werden wie `content/` in die App
gespiegelt. Der Code selbst ist englisch, und `locale/en.json` wird aus ihm
erzeugt — Deutsch ist die Sprache, in der das Spiel ausgeliefert wird, und
genauso eine Übersetzung wie Französisch. Der ganze Apparat steht in
`AGENTS.md`.

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

## Das Dashboard baut mit

Das Web-Dashboard sammelt die Ideen, priorisiert sie und **setzt sie mit echten
OpenCode-Sitzungen um** — ohne Umweg über einen Menschen, der jeden Auftrag
freigibt:

- **Direkter Auftrag.** Auftrag ins Feld tippen, `🚀 Auftrag starten`: er landet
  sofort in der Warteschlange, mit Scope-Zuordnung, Wiederholungsregeln und
  Commit-Schutz wie ein Spieler-Vorschlag.
- **Mehrere Sitzungen gleichzeitig.** Standard sind drei Spuren, einstellbar bis
  acht. Zwei Agenten teilen sich den Arbeitsbaum nur, wenn ihre Scopes sich nicht
  überschneiden — ein zweiter Auftrag auf dasselbe Spiel wartet, statt in
  dieselben Dateien zu schreiben.
- **Ein Panel, alles drin.** Jede Spur mit eigener Konsole, Zeitlimit-Restzeit und
  Abbruch-Knopf; darunter Warteschlange, Historie und der Scope-Besitz aller
  Agenten.
- **Die Historie liegt im Repo.** `backup/dashboard.json` hält Vorschläge,
  Entscheidungen, Stimmen und Runs mit Commit-Hash — committet, also auf jeder
  Maschine da und mit `git show` auch ohne Server lesbar.

```bash
npm run backup            # Stand der Datei melden
npm run backup -- write   # Historie ins Repository schreiben
npm run backup -- read    # Datei einlesen und mit der Datenbank zusammenführen
```

## Qualitätssicherung

```bash
npm run typecheck   # Server + Dashboard
npm test            # Vitest (Server, Dashboard, Backup) + Content-Sync + Sprachkataloge
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
backup/           Dashboard-Historie als JSON (gehört ins Git)
content/          einzige Quelle der Spieldaten (wird in die App gespiegelt)
locale/           Sprachkataloge, einzige Quelle der Texte (wird in die App gespiegelt)
scripts/          Content-Sync, Sprachkataloge, Android-Template, API-Smoke, Blender-Meshes
tests/            Vitest für Server und Dashboard
```

Screens erben von genau zwei Basisklassen: `Screen` (2D) und `WorldScreen` (3D).
Beide bringen Top-Bar, Vorschlagsdialog, Theme, Kamera-Follow und Touch-Steuerung
mit — siehe `AGENTS.md` für den Erweiterungsweg.

## Lizenz

MIT
