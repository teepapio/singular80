# Changelog

What was implemented, one or two lines each. Written by the runner when a run
succeeds, committed and pushed to GitHub in its own commit — see
`server/changelog.ts`.

## 2026-09-26

- **#1** The backend is now reachable from phone and tablet; before, every suggestion from the game stayed in its local queue and never arrived.
- **#2** Suggestions sent from inside the game now show up in Telegram instead of piling up offline.
- **#3** The chat can start OpenCode runs: `/run 12` in Telegram, and chat and dashboard share one queue.
- **#4** Telegram messages are down to the number and the suggestion — no emoji, no dashboard link.
- **#5** `CHANGELOG.md` gets a line for every implemented suggestion, committed and pushed on its own.
