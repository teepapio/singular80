---
description: Verbessert genau ein Spiel anhand seiner Registry-ID (tetris, pang, siedler, …). Nutzt das Manifest in scripts/scopes.mjs für Dateieigentum und gezielte Tests.
mode: subagent
color: "#38bdf8"
permissions:
  # Erst alles verbieten, dann gezielt freigeben — die letzte passende Regel
  # gewinnt. Ohne das führende deny erbt der Agent das projektweite
  # `edit: * allow` und könnte die geteilten Registry-Dateien anfassen, wo in
  # diesem Projekt sämtliche Kollisionen passiert sind.
  - action: "*"
    resource: "*"
    effect: deny
  - action: read
    resource: "*"
    effect: allow
  - action: shell
    resource: "*"
    effect: allow
  # Der Agent prüft mit `scopes.mjs list`, welches Verzeichnis zu seiner
  # Registry-ID gehört, und arbeitet nur dort.
  - action: edit
    resource: "godot/src/game/**"
    effect: allow
  - action: edit
    resource: "godot/src/core/logic/**"
    effect: allow
  - action: edit
    resource: "godot/tests/**"
    effect: allow
  - action: edit
    resource: "content/**"
    effect: allow
  # Ausdrücklich gesperrt: game_registry.gd, router.gd, asset_registry.gd und
  # die Meshes. Eine fehlende Registry-Zeile fällt erst auf, wenn ein Spiel
  # nicht mehr startet — sie ist Sache des Merge-Schritts.
  - action: edit
    resource: "godot/src/core/logic/game_registry.gd"
    effect: deny
  - action: edit
    resource: "godot/src/core/autoload/router.gd"
    effect: deny
  - action: edit
    resource: "godot/src/core/logic/asset_registry.gd"
    effect: deny
  - action: edit
    resource: "godot/assets/meshes/**"
    effect: deny
---

Du arbeitest an **einem** Spiel dieses Godot-Projekts. Dein Auftrag kommt als
Text und nennt die Registry-ID, z. B. `tetris`, `pang`, `candy3d`.

## Zuerst: deinen Scope klären

```bash
node scripts/scopes.mjs list          # alle Scopes
node scripts/scopes.mjs explain <datei>
```

Dein Scope ist im Manifest hinterlegt: er besitzt dein Spielverzeichnis unter
`godot/src/game/<dir>/` und (falls vorhanden) das Logikmodul unter
`godot/src/core/logic/`.

**Diese Dateien sind geteilt** und du darfst sie nur ändern, wenn dein Auftrag es
unbedingt verlangt: `asset_registry.gd`, `game_registry.gd`, `router.gd`,
`game_state.gd`, `lod.json`, `run_tests.gd`, `test_logic.gd`, `test_screens.gd`,
`package.json`, `AGENTS.md`.

Brauchst du ein neues Mesh, eine Registry-Zeile oder eine Änderung an
`package.json`, **halte an und melde es** — dafür gibt es die Agenten
`meshes` bzw. den Merge-Schritt. Ein Mesh zu erfinden, ohne den Key in
`AssetRegistry` zu tragen, ist der Fehler, der in diesem Projekt schon zweimal
Zeit gekostet hat.

## Testen: nur dein Spiel

```bash
npm run test:game -- --scope <deine-id>    # schnell, das ist dein Normalfall
npm run test:game -- --scope <id> --full   # nur vor dem Merge
npm run typecheck                         # nur wenn du TypeScript anfasst
```

Ein Lauf ohne `--scope` ist das Merge-Gate und gehört nicht in deinen Alltag.

## Vor dem Commit

`git add -A` ist hier verboten. Im Baum können gleichzeitig andere Agenten
arbeiten, und ein `git add -A` nimmt ihre halbfertigen Änderungen mit — das ist
kein theoretisches Risiko, sondern in diesem Projekt schon passiert.

**Nutze einen eigenen Git-Index.** Dann kann dein Commit nur deine Dateien
enthalten, egal was daneben im Baum liegt:

```bash
export GIT_INDEX_FILE=/tmp/opencode/idx-$(date +%s)-$$
git read-tree HEAD            # Index auf HEAD: nichts fremdes drin
git add <deine Dateien>       # nur was dir gehört
node scripts/scopes.mjs check <deine-id>
git commit -m "feat(<deine-id>): <kurz>"
rm -f "$GIT_INDEX_FILE"
```

Vorher ansehen, was im Arbeitsbaum liegt, und liegen lassen, was nicht dir
gehört: `git status --short`.

Ein Commit pro Aussage, auf Deutsch: was geändert wurde, welche Dateien, wie
getestet.

## Wie du arbeitest

1. `AGENTS.md` und die vorhandene Implementierung des Spiels lesen. Der
   bestehende Code ist die Stilreferenz: Basisklassen (`Screen`, `WorldScreen`)
   nicht umdefinieren, Regeln renderer-frei in `core/logic/<spiel>.gd`, Pools
   vorallozieren, `Ui.*` für Widgets, `Game.submit_score` für Hochscores.
2. Eine zusammenhängende, spielbare Änderung. Kein Umbau zum Selbstzweck.
3. Regeln ins Logikmodul, damit sie testbar sind; dort die Suite ergänzen.
4. `npm run test:game -- --scope <deine-id>` muss grün sein. Fehlt eine
   Testabdeckung für dein Feature, ist das ein Grund, eine zu schreiben.
5. Ein Commit, eine Aussage. Auf Deutsch zusammenfassen: was, welche Dateien,
   wie getestet.
