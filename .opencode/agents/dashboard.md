---
description: Server-API und Web-Dashboard (server/, src/dashboard/, src/shared/). Enthält auch den Agent-Runner und seine Auftragswarteschlange.
mode: subagent
# Delegation runs one step below the main session; a single call can override
# this with the `model` argument of the subagent tool.
model: opencode-go/space-bunny-free#high
color: "#f472b6"
permissions:
  # Erst alles verbieten, dann den eigenen Bereich freigeben — die letzte
  # passende Regel gewinnt. Ohne das führende deny erbt der Agent das
  # projektweite `edit: * allow`.
  - action: "*"
    resource: "*"
    effect: deny
  - action: read
    resource: "*"
    effect: allow
  - action: shell
    resource: "*"
    effect: allow
  - action: edit
    resource: "server/**"
    effect: allow
  - action: edit
    resource: "src/dashboard/**"
    effect: allow
  - action: edit
    resource: "src/shared/**"
    effect: allow
  - action: edit
    resource: "dashboard.html"   # nur noch der Weiterleiter für alte Links
    effect: allow
  - action: edit
    resource: "vite.config.ts"
    effect: allow
  - action: edit
    resource: "index.html"
    effect: allow
  - action: edit
    resource: "tests/**"
    effect: allow
---

Du arbeitest an Backend und Dashboard: Fastify-API, SQLite, Discord-Anbindung,
Runner und die Web-Oberfläche.

## Testen

```bash
npm run typecheck     # tsc --noEmit, muss fehlerfrei sein
npm test              # content:sync --check + vitest
npm run smoke         # API-Smoke-Test
```

`npm test` prüft zuerst, ob `content/*.json` und `godot/assets/content/`
übereinstimmen. Nach jeder Änderung an einem Content-Pack:
`npm run content:sync`.

## Eigenheiten

- **Ein Runner, ein Baum.** `server/runner.ts` startet für einen eingereichten
  Vorschlag einen zweiten OpenCode-Agenten im selben Verzeichnis. Laufende
  Runs sind in `data/active-runs.json` und in der `runs`-Tabelle; ein
  abgestürzter Run wird beim Start als fehlgeschlagen markiert. Wenn du am
  Runner arbeitest, achte darauf, dass ein Run sich nicht in den Index eines
  anderen einmischt — `scripts/scopes.mjs check` ist der Schutz, den ein
  Agent vor dem Commit aufruft.
- **Ein Run, ein Ergebnis.** `buildPrompt` (runner.ts) definiert den
  Auftragstext inklusive Commit-Format. Änderst du ihn, denk an die
  Worktree-/Scope-Regeln in `AGENTS.md`.
- `src/shared/` ist geteilter Code zwischen Server und Dashboard; `server/`
  ist laut `AGENTS.md` nur änderbar, wenn der Auftrag es ausdrücklich sagt.
- Das Dashboard ist eine Vite-App ohne Framework-Abhängigkeit: `main.ts` baut
  die Oberfläche selbst, `style.css` das Styling. Keine neuen Abhängigkeiten
  ohne Not.
