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
- **#34** I'll start by reading the project docs and locating the Crystal Jumper game.Now let me measure the … — `fda2ee2` <!-- 34:run_muq5rxr5_d1c5a6 -->
- **#35** I'll start by reading AGENTS.md and understanding the scope.Let me measure the actual ball behavior… — `b7a4f69` <!-- 35:run_muq5rweh_2a9bbf -->
- **#40** Die Lobby-Mitte ist weg: kein Podest, kein Rand, kein Lagerfeuer und keine Felsen, Büsche… — `33c22c8`
- **#33** I'll start by understanding the current state of the Crystal Jumper game and the scope boundaries.N… — `af1c267` <!-- 33:run_muq5ryho_b0c66f -->
- **#32** I'll start by reading the project documentation and understanding the current state of the Jumper g… — `ee821aa` <!-- 32:run_muq5s081_780f33 -->
- **#31** I'll start by reading AGENTS.md and understanding the FreeCell implementation.Foreign work is in th… — `05fc178` <!-- 31:run_muq5s0xs_b3b924 -->
- **#26** I'll start by reading the project structure and understanding the flying mechanic.The tree is dirty… — `22b46c5` <!-- 26:run_muq5s57a_e95d14 -->
- **#28** I'll start by reading AGENTS.md and understanding the repository structure.Now let me research Merg… — `6cd4bf7` <!-- 28:run_muq5s39v_1a6b9e -->
- **#29** I'll start by reading the project structure and understanding the scope.Now let me write a probe to… — `7537a0e` <!-- 29:run_muq5s2gw_65b489 -->
- **#22** I'll start by researching the repository structure and the dragon breeding feature.Now I have the f… — `e0b9ef5` <!-- 22:run_muq5s9el_65aca9 -->
- **#25** I'll start by reading the project documentation and understanding the structure.Now I'll make the c… — `49abbfc` <!-- 25:run_muq5s60i_e65bbf -->
- **#27** I'll start by reading the key files to understand the lobby structure.Now let me research the Godot… — `78734ce` <!-- 27:run_muq5s4ec_b25bba -->
- **#23** I'll start by reading the project documentation and understanding the current state.Now I have hard… — `99a6d02` <!-- 23:run_muq5sasa_d79c5f -->
- **#24** I'll start by reading AGENTS.md and researching the repository structure.Let me research the actual… — `8035169` <!-- 24:run_muq5s7m2_14447b -->
- **#43** I'll start by understanding the current state of the repository and the mesh gallery implementation… <!-- 43:run_muq5sger_b58697 -->
- **#49** I'll start by researching the current state — the run log, the working tree, and the actual golem m… <!-- 49:run_muq7q7nh_c68c99 -->
- **#41** I'll start by investigating the previous failed attempt and the current state of the worktree.Workt… <!-- 41:run_muq8gw3a_c43cbd -->
- **#40** I'll start by understanding the current state — the previous attempt, the working tree, and the lob… — `7635625` <!-- 40:run_muq8hme3_c6b983 -->
- **#47** ow update the stale sign note in the shared primitive, since the second pack now uses it.Now rebuil… — `b43ebc3` <!-- 47:run_muq7q973_b920e6 -->
- **#21** I'll start by understanding the current state: the run log, the working tree, and the previous atte… — `35dd97a` <!-- 21:run_muqcihqb_b6201e -->
