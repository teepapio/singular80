# 06 — Closed Testing: 12 Tester, 14 Tage, Produktionsantrag

Die häufigste Ursache für „Play ist gesperrt" nach der Registrierung. Google
prüft bei persönlichen Konten, die **nach dem 13.11.2023** erstellt wurden, ob
ein geschlossener Test stattgefunden hat.

## Die Regel im Wortlaut

* **12 Tester** müssen dem closed test **beigetreten** sein.
* Sie müssen **14 Tage ununterbrochen** angemeldet bleiben — „opted in
  continuously for the preceding 14 days".
* Erst dann wird der Antrag auf Produktionszugriff gestellt.
* Erst danach ist der Track **Production** freigeschaltet.
* Zusätzlich prüft Google, ob die Tester die App **wirklich benutzt** haben —
  „insufficient tester engagement" ist ein Ablehnungsgrund für weitere Tests.

## Was „beigetreten" technisch heißt

* Einladung über den **Einladungslink** aus der Konsole (Google mailt den
  Opt-in-Link) oder per E-Mail-Liste.
* Der Tester muss die **Play-Store-Testerseite** öffnen und der
  Closed-Testing-Gruppe beitreten — erst dann zählt er.
* Ein Testergerät mit **Play-Diensten** (kein "Google Play"--abgeschaltetes
  Gerät, keine Sideload-only-Variante; „Sideload Apps" im Play Store reicht
  nicht, es muss die Testerseite erreichbar sein).
* **Kein Opt-Out, kein Deinstallieren.** Wer die App deinstalliert, bleibt
  eingetragen; wer sich abmeldet, beginnt am Tag des Wiedereintritts neu.
* Ein Tester, der 10 Tage drin war und dann raus, **zählt für diese 14 Tage
  nicht** — die Tage müssen durchgehend sein.

## Zeitplan

```text
Tag  0   Konto + Verifizierung abgeschlossen, App angelegt, Formulare gefüllt
Tag  1   AAB in Internal testing hochladen, 2–3 eigene Geräte testen
Tag  2   Pre-Launch-Report starten, Tester einladen
Tag  2–? 12 Opt-ins einsammeln (Frist: Opt-in + 14 volle Tage)
Tag 16+  14 Tage sind um, Antrag auf Produktionszugriff stellen
Tag 16.. Review (meist ≤ 7 Tage, gelegentlich länger)
         → Production freigeschaltet oder Rückfrage
```

Puffer einplanen: Das **Sammeln** der Opt-ins ist der Teil, den man nicht
kaufen kann. Wer erst am Tag 10 zwölf Leute hat, wartet bis Tag 24.

## Tester finden

Wirksam, in dieser Reihenfolge:

1. **Persönliches Netz** (12 Freunde/Familie) — der schnellste Weg. Bitte
   ausdrücklich **schriftlich bestätigen**, nicht nur mündlich zusagen.
2. **Discord**: Der Diskord-Bot des Projekts postet ohnehin Updates in den
   Server — dort gezielt um Beta-Tester bitten, plus einen Reminder nach einer
   Woche.
3. **Reddit / r/androidgaming, r/Godot**: „looking for 12 Android testers for
   an offline game collection" funktioniert erfahrungsgemäß.
4. **Fach-Communities**: Unity-/Godot-/Indie-Gruppen, Game-Jams, Hochschulen.
5. **Zehn Freunde-Prinzip**: zwei Tester akzeptieren erfahrungsgemäß eher, wenn
   sie wissen, dass andere mitmachen.

Wichtig für den Antrag: Die Tester sollten **zu deinem Zielpublikum passen**
und **möglichst viele Spiele ausprobieren** — genau danach fragt Google im
Antrag.

## Tester-Information schicken

Ein Text, den du versenden kannst (anpassen!):

> **Singular 80 — Beta-Test für Android**
>
> Ich brauche 12–20 Tester für eine geschlossene Google-Play-Beta. Es geht um
> eine App mit **18 Spielen** (Tetris, Poker, Dame, 2048, 3D-Lobby, Drachen-RPG
> …), die komplett **offline** läuft — keine Werbung, keine Käufe, kein Konto.
>
> Was du brauchst: ein Android-Handy mit Play Store (ab Android 7).
>
> Was du tust:
> 1. Link unten öffnen und der Beta-Gruppe beitreten (eine Bestätigung per
>    E-Mail, das dauert 1 Minute).
> 2. Die App aus dem Play Store installieren — die Opt-in-Bestätigung per Mail
>    ist wichtig, erst danach zählt der Tag.
> 3. **2–3 Wochen** in der Gruppe bleiben. Wer zwischendurch austritt, zählt
>    nicht mehr.
> 4. Ein paar Spiele ausprobieren und mir schriftlich sagen, was dir auffällt:
>    Absturz, Bedienung, Textfehler, Wünsche.
> 5. Feedback in Play selbst: Bewertung abgeben, oder mir schreiben.
>
> Belohnung: Alle neuen Spiele, die aus euren Vorschlägen entstehen, tragen eure
> Herkunft — und ihr seid ab Tag eins dabei.
>
> Hier beitreten: [[CLOSED_TESTING_LINK]]
> Fragen: [[CONTACT_EMAIL]]

## Der Antrag auf Produktionszugriff

Im Play Console auf dem **Dashboard** → *Apply for production*. Drei Abschnitte,
alle ehrlich beantworten:

**1. Über den closed test**
* Wie leicht waren die Tester zu finden? (Antwort auswählen + begründen.)
* Haben die Tester alle vorhandenen Funktionen genutzt? (Begründung: welche
  Spiele, wie lange, wie viele Geräte.)
* Hatte die Nutzung der Tester das Verhalten erwarteter Produktionsnutzer?
  Falls nein: woran lag es, z. B. Testgeräte waren nur mittelklassig.
* **Feedback zusammenfassen**: Die häufigsten Meldungen benennen, nicht
  „alles gut". Mindestens zwei konkrete Beispiele, die zu einer Änderung
  geführt haben — das ist der wichtigste Teil.

**2. Über die App/das Spiel**
* Zielgruppe so konkret wie möglich: „Casual players who want one offline app
  for several small games, plus players who like to shape the game via
  suggestions."
* Alleinstellungsmerkmal: „A game collection whose feature backlog is written by
  its players, and where every implemented suggestion shows up in the app."
* Erwartete Installationen im ersten Jahr: ehrlich schätzen. Eine kleine Zahl ist
  kein Nachteil — Play belohnt keine großen Versprechen.

**3. Über die Produktionsreife**
* Welche Änderungen kamen aus dem closed test? (Hier passt der Fortschritt aus
  `log/` und den Tester-Meldungen.)
* Worauf stützt sich die Einschätzung, dass die App produktionsreif ist?
  (Testmatrix: Geräte, Android-Versionen, `npm run test:game` als
  Screen-/Regel-Test, Crash-freie Testtage.)

Nach dem Absenden prüft Google, üblicherweise **innerhalb von 7 Tagen**, gelegentlich
länger. Kommt eine Ablehnung, steht dort konkret, was nicht gepasst hat — meist
zu wenige Tester oder zu geringe Nutzung.

## Regeln für den Testzeitraum

* **14 Tage sind 14 Tage.** Ein Build-Wechsel setzt die Tage **nicht** zurück —
  aber ein Build, der nicht startet, beendet die Nutzung. Erst testen, dann den
  closed test starten.
* **Pre-Launch Report** laufen lassen: Play testet auf ~50 realen Geräten und
  meldet Crashes, ANRs, Performance-Probleme und die unterstützte
  Geräteabdeckung. Bei einer arm64-only-App ist das der beste Weg, echte
  Geräteprobleme zu finden, bevor die 12 Tester sie finden.
* **Warteschlange:** Tester bekommen die App automatisch beim Beitritt. Wer
  später beitritt, zählt erst ab dem Beitrittstag.
* **Kündigen:** Wird der Test vor Ablauf beendet, beginnt die Zeit neu.

## Nach der Freischaltung

1. *Production*-Release mit **staged rollout** (5 %) starten, nicht auf 100 %.
2. Watchdog einrichten: Bewertungen beobachten, Storno-/Absturzquote im Blick
   behalten (Play Console → *Statistics* / *Vitality*).
3. Nächste Version: `version/versionCode` in `config/app.json` hochzählen,
   `npm run release`.
4. In den Release Notes von der Community und dem Testerkreis erzählen, was
   aus den Vorschlägen entstanden ist — das ist die stärkste Form von
   Marketing für diese App.

## Quellen

* Testanforderungen: <https://support.google.com/googleplay/android-developer/answer/14151465>
* Track einrichten: <https://support.google.com/googleplay/android-developer/answer/14151464>
* Pre-Launch report: <https://support.google.com/googleplay/android-developer/answer/9855338>
* Staged rollout: <https://support.google.com/googleplay/android-developer/answer/6345330>
