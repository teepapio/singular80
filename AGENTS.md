# AGENTS.md — Singular 80

Phaser 3 + TypeScript + Vite (Spiel) mit Fastify-Backend (API, SQLite, Discord, OpenCode-Runner).

## Commands

- Node **22+** ist Pflicht (`node:sqlite`); nvm-Standard ist v22, `start.sh` nutzt `~/.local/node`. Bei falscher Version zuerst `export PATH="$HOME/.local/node/bin:$PATH"`.
- `npm run dev` — Backend (`127.0.0.1:8787`) + Vite (`:5173`, proxyt `/api` → Backend). Läuft meist schon, NICHT erneut starten, keine Watcher starten.
- `npm run typecheck` — muss fehlerfrei sein (`tsc --noEmit`, strict).
- `npm test` — `vitest run`; Einzelfall: `npx vitest run tests/<name>.test.ts`.
- `npm run build` — `vite build` (Einstiege `index.html` + `dashboard.html`), muss durchlaufen.
- `npm run smoke` — API-Smoke-Test gegen Ephemeral-App mit Temp-`dataDir` (`scripts/smoke.ts`).
- Reihenfolge: `typecheck` → `test` → `build`.
- Manuell testen: Desktop-Starter `~/Desktop/Singular 80.desktop` bzw. `./start.sh` (startet Backend + Vite und öffnet Spiel & Dashboard im Browser).

## Structure

- `content/*.json` — datengetriebener Content (`enemies`, `weapons`, `upgrades`, `modes`, `mechanics`). Backend (`server/content.ts`) liest pro Request neu (mtime-Cache) → wirkt ohne Rebuild. Client lädt via `GET /api/content`, Fallback sind gebündelte Imports in `src/game/content.ts`.
- `src/game/` — `main.ts` (Phaser-Setup + `scene`-Array), `games.ts` (Lobby-Registry mit Kategorien), `lobby.ts` (Geometrie der 3D-Lobby), `scenes/` (`Boot`, `Lobby3DScene` als Key `Lobby`, `LobbyListScene` als Key `LobbyList`, `MainMenu`, `Game`, `GameOver`, `Tetris`), `mechanics/` (Code-Erweiterungspunkt), `stats.ts`, `textures.ts`, `content.ts`.
- `server/` — `app.ts` (alle Routen), `db.ts` (SQLite in `dataDir`), `content.ts`, `discord.ts`, `runner.ts`. Nicht ändern, außer ausdrücklich verlangt.
- `src/shared/` — `types.ts` + `sorting.ts` (Scoring/Clustering). Nicht ändern.
- `src/dashboard/` — Dashboard-UI. Env: `PORT`, `DATA_DIR`, `CONTENT_DIR`, `DISCORD_WEBHOOK_URL`, `DASHBOARD_URL` (siehe `.env.example`); `data/`, `dist/`, `.env`, `log/` sind gitignoriert.
- `log/` — pro KI-Run eine komplette JSONL-Datei (`suggestion-<id>_<YYYY-MM-DD>_<HH-MM-SS>.jsonl`): Meta-Header (Prompt/Modell), alle Roh-Events, Result-Footer mit `resultSummary`. Wird vom Runner in `server/runner.ts` geschrieben, nicht committen.
- `public/assets/` — von Blender erzeugte 3D-Meshes (`.glb`). Vite serviert `public/` unter `/`; im Build landen sie in `dist/assets/`.
- `scripts/blender/make_mesh.py` — headless Blender-Generator für 3D-Meshes (siehe unten).

## Content (bevorzugter Weg, kein Rebuild nötig)

- Enemy: `shape: circle | square | triangle | diamond | hexagon`, `behavior: chase | zigzag | orbit`. `weight: 0` = nie zufällig (Bosse, Split-Kinder). `boss: true` für Bosse. Split: `splitInto: "<enemy-id>"` + `splitCount` (Default 2).
- Weapon: `unlockWave: 0` = im Startmenü wählbar. `cooldown` in ms, effektives Minimum 70 (`stats.ts`: `effectiveCooldown`).
- Upgrade: `stat` muss numerisches Feld von `PlayerStats` in `src/game/stats.ts` sein (`maxHp`, `hp`, `moveSpeed`, `moveSpeedMult`, `damage`, `damageMult`, `fireRate`, `projectileSpeed`, `projectileCount`, `spread`, `pierce`, `pickupRadius`, `hpRegen`, `critChance`, `critMult`, `armor`, `xpMult` — kein `lifesteal`). `rarity: common | uncommon | rare | epic`. Sonderlogik in `applyUpgrade` beachten (`maxHp` heilt mit, `projectileCount` setzt `spread >= 0.12`, Caps: `critChance <= 0.9`, `fireRate <= 8`).
- Mode: `enemyHpMult`, `enemySpeedMult`, `spawnRateMult` (~0.5–2.0) + `duration`.
- Mechanic-Aktivierung: `{ "id": "<registry-id>", "name": "...", "description": "...", "enabled": true }` in `content/mechanics.json`.

## Mechanic (Code-Weg)

1. `src/game/mechanics/<id>.ts` mit `Mechanic`-Interface aus `mechanics/types.ts` anlegen.
2. In `src/game/mechanics/index.ts` in `MECHANICS` registrieren.
3. In `content/mechanics.json` aktivieren.
- Hooks: `init`, `update(host, dt)`, `movementOverride`, `onFire(host, shot)`, `onEnemyKilled(host, enemy)`, `onLevelUp`, `hud`. Host (`MechanicHost`): `stats`, `content`, `elapsed`, `keys`, `inputDirection()`, `aimDirection()`, `isInvulnerable()`, `grantInvulnerability(ms)`, `addHint(text)`.

## 3D-Assets mit Blender (headless)

- Blender 4.5 LTS liegt unter `~/.local/blender`; `blender` ist über `~/.local/bin` im PATH (sonst `export PATH="$HOME/.local/bin:$PATH"`).
- Mesh erzeugen und als binäres glTF exportieren:
  `blender --background --python scripts/blender/make_mesh.py -- --out public/assets/<name>.glb --name <builder>`
  Verfügbare Builder: `crystal`, `ship`; weitere Funktionen in `BUILDERS` (`scripts/blender/make_mesh.py`) registrieren.
- Mesh-Pack für ein ganzes Spiel: `scripts/blender/generate_rpg_meshes.py` erzeugt den kompletten Drachen-RPG-Pack (Drachen, Props, Loot, Ritter, ~50 `.glb`) in einem Blender-Lauf nach `public/assets/rpg/`; neue Builder dort in `BUILDERS` registrieren. `--only name1,name2` baut einzelne Meshes.
- Die `.glb`-Dateien liegen in `public/assets/`; three.js lädt sie per `GLTFLoader` (Beispiel: `src/game/scenes/CrystalJumperScene.ts`). URLs der Meshes zentral in `src/game/assets.ts` registrieren — so lassen sich Assets in mehreren Spielen wiederverwenden.
- three.js nur **dynamisch** importieren (`await import('three')`), damit der Lobby-Bundle klein bleibt.
- Meshes low-poly halten (wenige hundert Tris) — schont Build-Größe. `.glb`-Binärdateien mitcommitten, aber nicht zusätzlich extern herunterladen.

## Subgame (Lobby-Weg)

1. Szene `src/game/scenes/<Name>.ts` mit eigenem Key (`super('<Key>')`).
2. In `src/game/main.ts` importieren + ins `scene`-Array.
3. `GameEntry` in `src/game/games.ts` ergänzen (`{ id, name, description, icon, scene, accent, category, highscoreKey? }`). `category` ist eine `GameCategoryId` (`action | adventure | board | cards | puzzle`) — die 3D-Lobby baut daraus automatisch eine Plaza (`src/game/lobby.ts`), die Listen-Lobby gruppiert danach. Zurück: `this.scene.start('Lobby')` (3D) bzw. `'LobbyList'`.
- Nur Arena-Gameplay ändern? Dann Content-/Mechanic-Weg statt neuem Subgame.

## Arbeitsweise

- Findest du beim Arbeiten einen Fehler/Bug, behebe ihn direkt im selben Durchgang statt ihn nur zu melden — sofern er zum Auftrag passt und kein unverhältnismäßiges Risiko entsteht.

## Constraints

- Strict TS, kein `any`. Spieltexte Deutsch, Code/Kommentare Englisch.
- Perf: keine Allokationen im `update`-Loop; Pools/Gruppen in `src/game/scenes/GameScene.ts` nutzen; Limits einhalten (`MAX_ENEMIES 220`, `MAX_BULLETS 400`, `MAX_GEMS 160`).
- Keine externen Assets herunterladen — Texturen prozedural in `textures.ts`, 3D-Meshes headless mit Blender erzeugen (`scripts/blender`). Keine neuen npm-Deps ohne Zwang (three.js ist für 3D-Spiele gesetzt). Ports/Konfig nicht ändern.

## Done

`npm run typecheck` → `npm test` → `npm run build`, dann `git add -A && git commit -m "feat(suggestion-<id>): <kurz>"` (Format verlangt der Runner-Prompt in `server/runner.ts`).
