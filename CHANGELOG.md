# Changelog

What changed, one or two lines each. `**#12**` is a suggestion from the game or
the dashboard that an OpenCode run implemented; `**edi:**` is work from a normal
session. Written by the runner on success, or by
`npm run changelog -- "…"`, committed and pushed in its own commit — see
`server/changelog.ts`.

## 2026-09-26

- **#1** The backend is now reachable from phone and tablet; before, every suggestion from the game stayed in its local queue and never arrived.
- **#2** Suggestions sent from inside the game now show up in Telegram instead of piling up offline.
- **#3** The chat can start OpenCode runs: `/run 12` in Telegram, and chat and dashboard share one queue.
- **#4** Telegram messages are down to the number and the suggestion — no emoji, no dashboard link.
- **#5** `CHANGELOG.md` gets a line for every implemented suggestion, committed and pushed on its own.
- **edi:** Work from a normal session now gets its own changelog line, marked `edi:` so it stays apart from a suggestion number.

## 2026-09-28

- **#6** Slime langsamer: speed 55 auf 38 — `47740e5`
- **#7** Slime noch langsamer: speed 38 auf 32 — `b2110c6`
- **edi:** Changelog-Zeile für Aufträge aus Telegram ergänzt, die nach einem Server-Neustart sonst verloren gingen
- **#14** Ja. — `7191201`
- **edi:** Agenten arbeiten auf getrennten Worktrees statt im gemeinsamen Ordner; ein Merge-Gate prüft, merged… <!-- session:600c9e410f7a -->

## 2026-10-01

- **edi:** Die OpenCode-Sitzung läuft wieder im Panel rechts statt in einem Terminalfenster; die Konsole zeigt die Ausgabe des Laufs Zeile für Zeile.
- **edi:** Modell und Anstrengung lassen sich im Dashboard auswählen statt tippen: echte Liste aller Modelle mit Kontext und Preis, und je Modell nur die Anstrengungsstufen, die es wirklich hat.
- **edi:** Spuren sind nicht mehr pro Scope reserviert: mehrere Aufträge laufen auch dann gleichzeitig, wenn sie denselben Scope haben; blockiert heißt nur noch „keine freie Spur“.
- **edi:** Abgelaufene Läufe lassen sich aus dem Panel fortsetzen statt neu zu beginnen — der Agent behält seine Sitzung und macht weiter, wo er aufgehört hat.
- **edi:** Mehr Wiederholungen möglich (bis 20 statt 5, eingestellt auf 3), und die Warteschlange startet einen wartenden Auftrag jetzt auch ohne Ereignis — sie hing sonst trotz freier Spuren.
- **edi:** Ein gescheiterter Lauf nennt den Grund im Klartext: die letzte Fehlermeldung von OpenCode steht in der Notiz, statt nur „exit 1“.
- **edi:** Modell für neue Läufe auf `opencode-go/space-bunny-free` gestellt — das Standardmodell wurde vom Anbieter abgewiesen („This model is not available in your country“).
- **edi:** Die Prioritäts-Zahl ist weg — Score, Score-Zerlegung und Auto-Genehmigung nach Score gibt es nicht mehr; sortiert wird nach Stimmen, Neuheit oder Cluster.
- **#16** I'll start by checking the previous attempt's run log and the working tree state.Previous attempt l… — `6fd58ec` <!-- 16:run_mupy0eqn_a49cee -->
- **edi:** Vorschläge aus dem Spiel gehen wieder beim Besitzer an: sie gehen jetzt immer an den Telegram-Bot, und die vier Ideen, die auf dem Tablet hängen geblieben waren, sind zugestellt worden.

## 2026-10-02

- **#51** I'll start by reading the project structure and understanding the Siedler game.Clean tree. — `535a2be` <!-- 51:run_muq5rehc_7cb35a -->
- **#45** I'll start by researching the repository state and the suggestion.Let me check one thing — the sibl… <!-- 45:run_muq5rkgg_91bbe0 -->
- **#37** I'll start by reading the project docs and understanding the structure.Baseline is green. — `acfd1b0` <!-- 37:run_muq5rujl_fb7925 -->
- **#39** I'll start by reading AGENTS.md and understanding the lobby structure.Now setting up an isolated wo… <!-- 39:run_muq5rrvl_649374 -->
- **#38** es right now (lobby.gd modified 60s ago). <!-- 38:run_muq5rtp5_36b258 -->
