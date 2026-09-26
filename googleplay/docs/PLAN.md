# 01 — Plan: was wer macht und in welcher Reihenfolge

Stand: September 2026. Alle Regeln unten sind die aktuellen Google-Play-Vorgaben;
Links stehen am Seitenende der jeweiligen Kapitel.

## Die zwei Regeln, die den Zeitplan bestimmen

1. **Neue persönliche Play-Konten brauchen 12 Tester über 14 Tage**, bevor
   überhaupt ein Produktionsantrag möglich ist. Diese 14 Tage laufen erst, wenn
   der AAB hochgeladen und die Tester per Opt-in beitreten. Das ist die
   kritische Pfadlänge — alles andere ist Wochenarbeit, das hier nicht.
2. **Seit 31.08.2026 müssen neue Apps und Updates Android 16 / API 36
   targeten.** Der installierte Godot 4.5.1 liefert API 35; das ist in diesem
   Projekt bereits gelöst (siehe [`RELEASE.md`](RELEASE.md)).

## Zeitplan

| # | Schritt | Wer | Dauer | Abhängig von |
|---|---|---|---|---|
| 1 | Play-Konto anlegen ($25) + Identität verifizieren | du | 1–10 Tage (Ausweis, Zahlung) | — |
| 2 | Angaben zu Person/Firma/Backend liefern | du | — | — |
| 3 | Rechtstexte finalisieren (Impressum, Datenschutz, Nutzung, Moderation) | wir | 1 Tag | 2 |
| 4 | Store-Texte (de/en) + Screenshots + Icon + Feature Graphic | ich | 1 Tag | 3 |
| 5 | Toolchain: Android SDK 36, Template, bundletool | ich ✅ | erledigt | — |
| 6 | Upload-Keystore erzeugen und **sicher aufbewahren** | du | 15 Min | — |
| 7 | Signiertes AAB bauen und prüfen | ich ✅ | 10 Min | 5, 6 |
| 8 | App in der Konsole anlegen, Formulare ausfüllen | du | 1–2 h | 3, 4 |
| 9 | AAB in **internal testing** hochladen, Pre-Launch-Report | du + ich | 1 Tag | 7, 8 |
| 10 | 12 Tester in die **closed testing** Track einladen | du | Rekrutierung: 1–3 Wochen | 8 |
| 11 | 14 Tage closed test laufen lassen, dabei Bugs fixen | du (Testen) + ich (Fixes) | 14 Tage | 10 |
| 12 | Produktionsantrag mit Feedback-Zusammenfassung | du | Review ≤ 7 Tage | 11 |
| 13 | Production-Release (optional gestaffelt) | du | Tage | 12 |

**Realistisch: 4–6 Wochen**, davon 14 Tage reine Wartezeit plus die Zeit, bis
man 12 echte Tester findet. Der Engpass ist Schritt 1 (Konto) und Schritt 10
(Tester) — beides kann sofort laufen, während ich den Rest baue.

## Was ich ohne dich erledigen kann

* [x] Android-SDK 36 + Build-Tools 36 installieren
* [x] Godot-Gradle-Template auf compileSdk/targetSdk 36 heben (muss nach jedem
      `godot:android-template` erneut laufen — `npm run prepare` macht das)
* [x] `bundletool` bereitstellen, um das AAB-Manifest zurückzulesen
* [x] Export-Preset „Google Play (AAB)“ generieren und mit Godots eigenem
      Parser validieren
* [x] signiertes AAB bauen + gegen die Play-Pflichtregeln prüfen
* [ ] Screenshots aus echten Screens rendern (headless, `npm run screenshots`)
* [ ] Play-Icon 512×512 und Feature Graphic 1024×500 aus dem Vektor-Icon
* [ ] Store-Texte de/en inkl. Längen- und Verbotswort-Prüfung
* [ ] Datenschutz-/Nutzungs-/Moderationstexte als Entwurf
* [ ] IARC-Fragebogen und Data-Safety-Formular aus dem Code-Beispiel ausfüllen
* [ ] `npm run preflight` als Sammelprüfung (platzhalterfrei = abnahmebereit)
* [ ] während des closed test:Crash-Logs lesen, Updates bauen

## Was nur du erledigen kannst

Diese Punkte brauchen deine Identität, deine Zeit oder deine Entscheidung —
ich kann sie nicht stellvertreten, nur vorbereiten:

1. **Play-Konto und Verifizierung.** $25 Einzahlung, Ausweis/Rechtsformular,
   offizielle Adresse, Telefon. Google prüft persönliche Konten von Hand; das
   dauert Tage, manchmal Wochen.
2. **Upload-Keystore.** `npm run keystore` erzeugt die Datei, aber das
   Passwort musst du selbst wählen und im Passwortmanager ablegen. Wer den
   Schlüssel verliert, kann ohne Google-Freigabe nie wieder ein Update
   hochladen.
3. **12 Tester.** Freunde, Familie, Kollegen, Discord, Reddit, Forum — mit
   **Schriftbestätigung** (Play schickt den Opt-in-Link per E-Mail). Du musst
   die Leute einladen und 14 Tage dranhalten.
4. **Rechtstexte abnehmen.** Ich schreibe Entwürfe, aber Haftung, Impressum
   und Verantwortlichkeit für den Inhalt liegen bei dir. Wenn es um echtes Geld
   oder um Personen unter 18 geht, bitte anwaltlich prüfen lassen.
5. **Backend öffentlich erreichbar machen.** Die App funktioniert offline, aber
   Vorschläge gehen nur an einen Server. Für den closed test braucht es eine
   öffentliche **HTTPS**-Adresse, sonst sieht die Hälfte der Tester ein
   funktionsloses Feature.
6. **Fertig!**-Entscheidung im Review-Prozess. Wenn Play nachfragt, antwortest
   du — mit den Fakten aus [`CLOSED-TEST.md`](CLOSED-TEST.md).

## Entscheidungen, die ich von dir brauche (Blocker)

| Frage | Warum blockierend | Default, wenn du nicht antwortest |
|---|---|---|
| Persönliches oder Organisations-Konto? | Bestimmt Verifikationsweg, Zahlungsprofil, öffentliche Angaben | persönlich |
| Welche Paket-ID final? `de.singular80.game` ist im Repo schon belegt und **nicht** änderbar | Play identifiziert die App daran | bleibt `de.singular80.game` |
| Realer Name / Firma / Land für die Konsole | Pflichtfeld, wird öffentlich angezeigt | Platzhalter bleiben sichtbar |
| Kontakt-E-Mail (öffentlich) + privat | Support-Anfragen + Google-Kontakt | Platzhalter |
| Welche Sprachen für den Store? | Mindestens eine, `en-US` + `de-DE` ist sinnvoll | beide |
| Zielgruppe 13+ oder 18+? | bestimmt Altersfreigabe und ob die Families-Policy greift | 13+ (Poker → ESRB Teen) |
| Backend-URL öffentlich? | Vorschlags-Funktion im Test | Platzhalter, Spiel läuft offline |
| Nur arm64 oder auch armeabi-v7a? | 32-Bit-Geräte (Android 7/8) sind sonst ausgeschlossen | nur arm64 |
| Nur API-36-Patch oder Godot auf 4.7 aktualisieren? | 4.7 bringt native API-36-Unterstützung, aber Breaking Changes | API-36-Patch (bewiesen lauffähig) |

## Nächster konkreter Schritt

```bash
cd googleplay
npm run preflight        # zeigt, was fehlt
npm run keystore         # Upload-Key erzeugen (Passwort selbst wählen)
```

Danach im Play Console: Konto, Verifizierung, App anlegen
([`PLAY-CONSOLE.md`](PLAY-CONSOLE.md)) — und parallel 12 Tester organisieren.
