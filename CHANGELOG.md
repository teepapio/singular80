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
