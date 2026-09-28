# AGENTS.md — Singular 80

Godot-4-Spiel (Android) + Fastify-Backend + Web-Dashboard. Die App läuft offline
komplett; mit konfigurierter Server-Adresse holt sie Content und Vorschläge vom
Backend.

> **Achtung, gemeinsamer Arbeitsbaum:** Der Runner (`server/runner.ts`) startet für
> eingereichte Vorschläge einen zweiten Agenten im selben Verzeichnis. Vor dem
> Commit `git status` prüfen und nur die eigenen Dateien stagen — fremde, halb
> fertige Änderungen weder committen noch zurücksetzen. Zum Prüfen gegen HEAD
> eine Kopie in `/tmp` anlegen und dort die Suite laufen lassen.

> **Achtung, `git push` ist Pflicht, nicht Kür:** Ein Commit, der nur lokal
> existiert, ist für den Besitzer verloren — er sieht ihn nie, und dieser Zweig
> hier hat 101 Commits, 1269 Dateien und rund 76.000 Zeilen angesammelt, ohne dass
> eines davon auf GitHub ankam. Details und die Branch-Frage unten.

## Nach dem Commit: pushen

`git push origin main` — **in derselben Sitzung, in der du committet hast.**

Ein Commit ist ein Versprechen an *diesen* Arbeitsbaum, nicht an den Besitzer.
Der Besitzer arbeitet mit GitHub, nicht mit `git log`: was er dort nicht sieht,
existiert für ihn nicht. Der Unterschied ist billig zu reparieren, solange er
noch da ist, und uninterreparabel, wenn der Rechner neu aufgesetzt wird.

- **Ein Push pro Sitzung reicht**, am Ende — nicht nach jedem Commit.
- **Vorher `git status`**: niemals `git add -A`, nur die eigenen Dateien (siehe
  oben). Was du nicht committen darfst, schiebst du auch nicht.
- **Nur `main`, keine Branches** für normale Arbeit. Der Besitzer arbeitet nicht
  mit Pull Requests; ein Feature-Branch ohne Merge ist für ihn dasselbe wie
  nicht existent. Branches sind ausschließlich für *eine* Sache da: halbfertige
  Arbeit zu parken, die `main` grün hält (siehe „Parken statt Merge").
- **Vor dem Push prüfen**, dass keine Geheimnisse mitgehen: das Repo ist
  **öffentlich** (`teepapio/singular80`). `.env`, `*.pem`, `*.keystore`,
  Datenbanken und APK-Bauartefakte gehören nicht hinein — `.gitignore` deckt
  das ab, aber eine erzwungene `git add -f` umgeht es.
- **Schlägt der Push fehl** (kein Netz, falscher Schlüssel), ist das ein Blocker
  für den Abschluss der Sitzung, kein Detail: `git status -sb` muss am Ende
  `## main...origin/main` **ohne** `ahead` zeigen. Sonst steht die Arbeit
  wieder nur hier.

**Prüf-Befehl für den Besitzer:** `git status -sb | head -1`. Steht dort
`ahead`, ist etwas nicht auf GitHub.

### Parken statt Merge

Liegt fremde, halbfertige Arbeit im Baum (typisch nach einem abgebrochenen
Runner-Lauf) und lässt sie sich nicht sauber fertigstellen, wird sie **nicht
verworfen und nicht auf `main` gemischt**, sondern auf einen Neben-Branch
geparkt und der gepusht:

```bash
git stash push -u -m "WIP" -- <nur diese Dateien>   # oder: auf Branch committen
git switch -c wip/<kurze-beschreibung>
git push -u origin wip/<kurze-beschreibung>
```

So liegt die Arbeit auf GitHub, `main` bleibt grün, und sie ist später greifbar.
Vorher `npm run typecheck` laufen lassen — halbfertige Arbeit bricht erfahrungsgemäß
genau dort, und ein geparkter Branch ist der richtige Ort dafür, nicht `main`.

## Sprache im Code

**Code und Kommentare auf Englisch — und mit ihnen jeder spielersichtbare Text
in der Quelle.** Der Besitzer liest den Code nicht, aber er bezahlt für ihn, und
ein deutscher Kommentar in einer englischen Codebasis sieht nach einer zweiten
Sprache aus, die niemand mehr pflegt. Doc-Kommentare (`## …`) und `//`-Zeilen
auf Englisch, im Tonfall der vorhandenen englischen Kommentare.

Die Oberfläche des Spiels ist **genauso** englisch:
`Ui.label(Loc.f("Points: %s", [score]))`, `toast("Not enough gold")` und alle
Meldungstexte sind Quelltext, aus dem `locale/en.json` erzeugt wird. **Deutsch
ist die Sprache, in der das Spiel ausgeliefert wird** — für den Besitzer und
für die Spieler, die es so wollen — und wird als Übersetzung in
`locale/de.json` gepflegt, nicht im Code. Der ganze Apparat steht unter
„Sprache"; hier nur die drei Regeln, die man beim Schreiben trifft.

Ausnahmen, in denen Deutsch im Kommentar richtig ist: ein Zitat aus dem
Spiel, ein deutscher Terminus technicus, oder ein Kommentar, der eine
deutsche Bedienoberfläche erklärt.

- **Ein neuer spielersichtbarer String wird auf Englisch geschrieben** und
  bekommt seinen Katalogeintrag über `npm run locale:sync`. Ein deutsches
  Literal bedeutet nicht „deutsche Oberfläche", sondern *übersetzbarer String
  ohne Übersetzung*: Er steht in `en.json` unter seinem deutschen Text, und
  `npm run locale:check` nennt ihn beim nächsten Lauf — samt String, damit die
  Meldung jemanden erreicht, der ihn wiedererkennt.
- **Was nicht durch `Loc` geht, braucht eine ausdrückliche Auflösung.**
  `label.text = "…"` per Zuweisung, ein `Label3D`, `draw_string(…)` und
  `LineEdit.placeholder_text` setzen ihren Text direkt am Knoten. Der Extraktor
  in `scripts/locale.mjs` findet solche Stellen, `Ui.label`/`Ui.button`/
  `Ui.title`/`Loc.resolve` finden sie zur Laufzeit nicht. Also
  `Ui.label(Loc.f("Points: %s", [n]))` oder `node.text = Loc.resolve("…")`
  schreiben, nie `node.text = "…"` mit einem Satz darin. Eine Prüfung 2026 fand
  26 Beschriftungen in genau dieser Form; mehrere davon standen bereits im
  Katalog und wurden zur Laufzeit trotzdem ignoriert.

## Sprache

Das Spiel liefert **auf Deutsch, Englisch und Französisch** aus. Das ist eine
Eigenschaft des Produkts, kein Werkzeug — aber die Art, wie sie gebaut ist, ist
eine Entscheidung, die man nicht täglich neu trifft, sondern nur einmal richtig
oder einmal falsch.

**Die Quellsprache ist Englisch, und das heißt: jedes Literal in `godot/src`
ist englisch.** `content/*.json` ist englisch, die Doc-Kommentare sind
englisch, und `Ui.label(Loc.f("Points: %s", [score]))` ist englisch.
`locale/en.json` wird von `npm run locale:sync` aus genau diesen Literalen
erzeugt und **nie von Hand editiert**; `de.json` und `fr.json` sind Übersetzungen
und werden von Hand gepflegt. Die Richtung war vorher umgekehrt, und das war
falsch: ein gettext-Katalog ist eine Liste von msgids, die alle im Projekt lesen
können — eine msgid, die keiner lesen kann, ist eine, die keiner reparieren
kann. Wer aus einem deutschen Schlüssel übersetzt, muss erraten, was der Satz
heißen soll, und die Wahrheit liegt in einer Datei, die der Rest des
Repositories nicht lesen kann.

Damit ist Deutsch eine Sprache des Spiels wie jede andere: `de.json` ist
genauso eine Übersetzung wie `fr.json`, und es ist die, die der Besitzer
ausgeliefert bekommt. Stand heute:

```
de  Deutsch    100.0 %   918/918 übersetzt  ·  123 gleich  ·  0 offen  (keys 217/217, text 701/701)
en  Quelle   1041 Einträge
fr  Français   100.0 %   927/927 übersetzt  ·  114 gleich  ·  0 offen  (keys 216/216, text 711/711)
```

**Es gibt zwei Arten von Schlüssel, und die Wahl ist nicht Geschmack.** `keys`
sind handgeschriebene Bezeichner (`ui.close`, `legal.reason.insult`): stabil,
wenn der Satz umformuliert wird, und *eine* Übersetzung je Kontext — nötig
überall dort, wo derselbe Satz zweimal anders gesagt werden muss oder wo sich
der Wortlaut noch ändert. `text` sind **die englischen Quellstrings als
Schlüssel** (`"◀ Lobby"`, `"Points: %s"`). Genau das ist der Grund, warum die
rund 550 Aufrufstellen von `Ui.label`, `Ui.title`, `Ui.button`, `show_toast`
und `notify` übersetzen, ohne dass eine einzige umgeschrieben wurde:
`Ui.label` läuft durch `Loc.resolve`, und das schlägt den übergebenen String im
`text`-Abschnitt nach.

Neue **Bezeichner** legt man von Hand in die `keys`-Karte aller drei Kataloge;
`npm run locale:check` sagt „Kennung '…' wird benutzt, fehlt aber in en.json",
wenn eine davon fehlt. Ein reiner Anzeigetext braucht keinen Bezeichner, er ist
selbst einer — das spart die Entscheidung, wie er später heißen soll.

**`Loc.t` für Bezeichner, `Loc.f` für Vorlagen, und die Bedingung bleibt
draußen.** `Loc.f` übersetzt die Vorlage und formatiert *danach*;
`Loc.f("Points: %s", [n])` ist richtig, `Ui.label("Points: %s" % n)` ist es
nicht, weil dort der Katalog einen fertigen Satz mit eingebackener Zahl führen
müsste. Der Fehler, den die Regel wirklich verhindert, ist ein anderer. In
`"TEMP" % n if n > 0 else "OTHER"` bindet `%` stärker als die Bedingung; wer
das `%` in die Argumentliste von `Loc.f` zieht, reicht einem `%d` einen String
und Godot meldet zur Laufzeit `String formatting error: a number is required` —
mitten im Level, in der Sprache, die der Spieler gerade gewählt hat. Eine
Datei, die parst, ist keine Datei, die formatiert. `scripts/locale.mjs` zählt
deshalb die Platzhalter einer `Loc.f`-Vorlage gegen ihre Werte, hängt die
Meldung an `check` und damit an `npm test`. Und ehrlich gesagt: genau diese
Bedingungsform sieht der Lint nicht, er überspringt sie absichtlich, weil ein
Zweig je einen anderen Aufbau haben kann und das keine Frage ist, die ein
Prüfprogramm beantworten kann. Die Suite deckt es nicht ab, also bleibt das
Augenmaß.

**Eine Sprache hinzuzufügen** ist eine Datei und ein Durchlauf:

1. `locale/<code>.json` anlegen: `code`, `name`, `native`, `numbers`, `keys`,
   `text`.
2. `npm run locale:check` nennt jede Kennung und jeden Quellstring, der fehlt —
   die Liste, mit der man arbeitet.
3. Die Einträge füllen. Alles, was absichtlich der Quelle gleich bleiben soll,
   nicht übersetzen, sondern in Schritt 4 markieren.
4. `npm run locale:lock` schreibt `locale/identical.json` neu: alles, was noch
   gleich ist, kommt auf die Liste. Die Liste ist je Sprache, weil „Bonbonland"
   der französische Name der Candy-Welt ist und „Candy Land" der englische —
   eine gemeinsame Liste müsste eines von beidem als unübersetzt melden. Nach
   einer Übersetzung gehört der Eintrag wieder von der Liste, sonst ist sie ein
   Versteck für einen Satz, den niemand übersetzt hat.
5. `npm run locale:sync` — schreibt den Katalog, spiegelt nach
   `godot/assets/locale/` und ergänzt die anderen Kataloge um den neuen Stand.
6. Committen, Spiegel mit.

Bei Schritt 1 ist `native` Pflicht und nicht Kosmetik: die Sprachauswahl zeigt
den Namen, den sich die Sprache selbst gibt — „Deutsch", „English",
„Français". `fr` auf einer französischen Oberfläche hilft niemandem. Und keine
Flagge: `⚑` steht in DejaVu Sans, `🌐` nicht, und ein Emoji, das die Schrift
nicht hat, ist auf dem Gerät ein leeres Kästchen.

**Nicht übersetzt wird**, und jeweils aus einem Grund, den man nicht wegargumentieren
kann:

- `REASONS`, `report_subject`, `report_body` in `app_legal.gd`. Sie gehen in
  die Melde-Mail an die Moderationsadresse, und das ist ein internes Dokument,
  kein Spieltext. Was der Spieler im Menü liest, ist `REASON_LOC_KEYS` plus
  `reason_label()` — dieselbe Liste zweimal, weil der Postfach-Eingang sie
  sorbieren und klassifizieren muss.
- `"Anonym"` in `suggest_dialog.gd` und `suggestion_queue.gd`. Das ist ein Wert
  für das Backend, kein Satz; übersetzt wäre er eine andere Person im
  Dashboard.
- Ein Satz, den ein Kommentar zitiert, um eine Zeile GDScript zu erklären.
- Alles in `locale/exclude.json`. Der Generator kann das nicht entscheiden: ein
  einzelner Buchstabe wie `"W"` ist in der U-Bahn ein Linienzeichen und in
  „Vorschlag" ein Wortanfang, und eine Übersetzung wäre beides falsch. Jede
  Zeile dort ist eine bewusste Entscheidung, kein Versehen.

**Es gibt zwei Suiten, und sie prüfen verschiedene Dinge.**
`godot/tests/test_loc.gd` (16 Suites: die sieben klassischen — Kataloge,
Auflösung, Platzhalter, Plural, Zahlen, Wechsel, Oberfläche — plus Idempotenz
gesamt, Pluralformen, Spielerdatei, Vorlagenvertrag, Platzhalterverworfen,
Abfrage, Zahlenränder, Kaltstart, Übersetzungen) prüft die *Laufzeit*.
`tests/locale.test.ts` (28 Tests) prüft die *Daten und den Extraktor*. Die zweite
Suite gibt es, weil
die erste beweist, dass der Motor richtig läuft, und **nichts** bemerken würde,
wenn ein Katalog einen Commit hinterher ist, eine Übersetzung einen Platzhalter
verloren hat oder ein Filter plötzlich Mesh-Kennungen als Sätze einreiht.

**`run_tests.gd` pinnt die Sprache auf `de`, und diese Zeilen zu löschen sieht
nach Aufräumen aus, ist aber keines.** `Loc` folgt beim ersten Start dem
Gerät, und die halbe Suite prüft deutsche Strings — die Warteschlangen-Anzeige,
der Melde-Dialog, die Dateipfade. Auf einem französischen Laptop schlüge sie an
einem Grund fehl, der mit dem Code nichts zu tun hat, und die Suite wäre genau
auf der Maschine grün, auf der sie geschrieben wurde. `Loc.reset()` und
`Loc.set_code("de")` stehen deshalb ganz oben, vor allem anderen. Nebenbei ein
zweiter Grund, sie nicht anzufassen: `Loc` schreibt in einem `--script`-Lauf
nicht in `user://singular80.cfg`, sonst hätte ein grüner Lauf dem Entwickler
Sprache, Ton, Serveradresse und Hochscores hinter dem Rücken überschrieben.

`godot/src/main.gd` ruft `Loc.boot()`, bevor es den ersten Screen gibt, und
`SettingsDialog` — Sprache, Ton, Touch-Steuerung, Serveradresse, wartende
Vorschläge, erreichbar über den `⚙`-Knopf in der Top-Bar jedes Screens — ist
der einzige Ort, an dem `Loc.set_code` aufgerufen wird. Ein Wechsel rendert den
aktuellen Screen nur dann sofort neu, wenn `Router.rebuild_safe()` das erlaubt:
`REBUILD_SAFE` kennt `lobby`, `lobby_list`, `main_menu`, `mesh_gallery`,
`pang_menu` und `dragonflight`. Alles andere nimmt die neue Sprache beim
nächsten Bildschirmwechsel mit, und der Dialog sagt dem Spieler vorher, welche
von beiden gerade gilt.

## Changelog

`CHANGELOG.md` bekommt **einen Eintrag mit ein bis zwei Zeilen pro
umgesetztem Vorschlag** — im Spiel, im Dashboard, in Telegram. Kein
Absatz, keine Liste von Dateien; die Zeile sagt, was sich für den Spieler
geändert hat, und der Commit-Hash dahinter sagt, wo.

Geschrieben wird die Datei **vom Runner**, nicht vom Agenten, der den
Vorschlag umgesetzt hat (`server/changelog.ts`, aufgerufen in `runner.ts` bei
`status === 'succeeded'`). Grund: nur der Runner weiß mit Sicherheit, dass
der Lauf erfolgreich war. Ein Agent, der sich selbst in die Changelog
lobt, kann das ebenso für einen Lauf tun, der fehlgeschlagen ist.

Der Commit **rührt nur `CHANGELOG.md` an**, mit ausdrücklichem Pfad
(`git commit -- CHANGELOG.md`) und wird gepusht. Ein `git add -A` hier würde
die halbfertige Arbeit einer fremden Sitzung mitnehmen — siehe oben. Ein
Fehlschlag ist eine fehlende Zeile, **kein** Anlass, einen guten Lauf als
fehlgeschlagen zu melden.

## Auftrag ausführen, nicht vorschlagen

**Ein Auftrag wird ausgeführt, nicht zur Diskussion gestellt.** Der Besitzer
gibt einen Auftrag und erwartet ein Ergebnis, keine Rückfrage. Bis die Aufgabe
erledigt ist, wird weitergearbeitet — auch wenn zwischendurch eine Frage
aufkommt.

**Entscheidungen sind meine.** Wenn eine Wahl offen ist, entscheide ich sie
und arbeite weiter. Eine Entscheidung, die der Besitzer nicht bemerkt, ist
falsch — deshalb steht sie als Stichpunkt im Bericht, sobald etwas schiefging
oder unerwartet lief. Nachfragen gibt es nur, wenn eine Antwort **nicht
ersetzbar** ist, das heißt wenn ein Fehler ein reales Risiko ist:

- Ein Auftrag würde Daten löschen, überschreiben oder zurücksetzen, und es gibt
  keinen Hinweis darauf, dass genau das gemeint ist.
- Zwei Lesarten führen zu **unumkehrbar** verschiedenen Ergebnissen und es
  gibt keinen Weg, es später zu korrigieren.
- Eine Berechtigung, ein Geheimnis oder ein Zugang fehlt.

Sonst nicht. „Soll ich?", „Möchtest du?" und „Ich könnte …" sind im Bericht
**keine** Zulieferung. Typische Fälle, die ohne Rückfrage entschieden werden:

- **Aufraeumen statt fragen:** zwei fast gleiche Auftraege werden zu einem
  zusammengefasst und das als Stichpunkt genannt — nicht, den Besitzer zwischen
  ihnen entscheiden zu lassen.
- **Fehlendes Werkzeug:** Ist `adb` nicht da, wird der Grund genannt und der
  nächstbeste Weg versucht, statt die Arbeit abzubrechen.
- **Unklare Formulierung:** Die naheliegendste Lesart wählen. Nur wenn etwas
  offen blieb oder unerwartet lief, kommt sie als Stichpunkt in den Bericht.
- **Zweiter Weg vorhanden:** functionierenden Weg nehmen, anderen erwaehnen.

**Nicht abgeben.** Der Auftrag endet nicht mit „ich habe vorbereitet", „der Rest
ist manuell" oder „bitte ausfuehren". Fertig heisst: laeuft, getestet,
committet, gepusht. Was nicht erreichbar war, wird benannt — aber nicht als
Uebergabe, sondern als Befund.

Wenn ein Schritt scheitert, zuerst den Grund beheben und neu versuchen. Ein
Fehlschlag ist ein Ergebnis des Wegs, kein Grund, ihn dem Besitzer zu
ueberlassen.

## Kurze Abschlussberichte

**Der Bericht am Ende einer Aufgabe ist eine Liste von Stichpunkten.** Was
implementiert wurde, ein Stichpunkt je Punkt. Mehr nicht.

- Nur was **fertig** ist.
- Ein Satz je Stichpunkt. Kein Dateiname, kein Commit-Hash, kein Teststatus.
- Nichts über Prüfungen, nichts über Entscheidungen, nichts über Begründungen.

**Zusätzliche Information nur, wenn etwas nicht sauber fertig wurde.** Dann
und nur dann kommen ein bis drei weitere Stichpunkte dazu:

- Was offen geblieben ist und warum.
- Ein Fehlversuch, ein Risiko, verlorene Daten.

Ein Bericht, der nur Stichpunkte hat, ist der Normalfall und kein Mangel. Ein
Satz „Die Tests laufen durch" ist überflüssig, weil der Besitzer nichts daran
ändern kann; ein Satz „3 Tests schlagen fehl, Ursache ist X" ist es nicht.

Beispiel für einen fertigen Auftrag:

> - Telegram: `/task` nimmt freie Aufträge an und startet sie sofort
> - Changelog: Zeile pro Auftrag, eigener Commit, wird gepusht
> - Löschen: Knopf im Dashboard, verweigert bei laufendem Run

Beispiel für denselben Auftrag mit einem offenen Punkt:

> - Telegram: `/task` nimmt freie Aufträge an und startet sie sofort
> - Changelog: Zeile pro Auftrag, eigener Commit, wird gepusht
> - `npm run typecheck` schlägt fehl: die neue `scripts/locale.d.mts` steht
>   noch nicht in `tsconfig.json` — das ist die Aufgabe der Sitzung, die sie
>   geschrieben hat
> - Offen: der Android-Build ist nicht neu, der neue Dialog ist im Gerät noch
>   nicht sichtbar

## Vor der ersten Änderung

Vier Sekunden, die in dieser Sitzung einen halben Tag ersetzt haben:

1. **`git status` lesen.** Der Runner kann eine Arbeit halbfertig liegen lassen
   und dabei den Index ruinieren. Der Zustand, der hier auftrat: acht Dateien
   im Index als *gelöscht*, obwohl sie byte-identisch auf der Platte lagen, und
   vier Dateien mit gestaged Änderung, die im Arbeitsbaum exakt zurückgenommen
   war. Beides sieht harmlos aus und ist es nicht — `git add -A` nimmt es mit.
   Ist der Index veraltet: `git reset` (nichts geht verloren, es ändert nur den
   Index) und die Dateien neu stagen. **Nichts zurücksetzen, was dir nicht
   gehört.**
2. **`node scripts/scopes.mjs list`** — beendet sich mit Code 1 bei jedem
   Manifest-Fehler. Eine Suite, die in keinem Scope steht, läuft in einem
   Scoped-Lauf *stillschweigend nicht*: der Agent, der sie geschrieben hat,
   glaubt, sie sei geprüft.
3. **`godot --headless --path godot --import`**, sobald du eine neue Datei mit
   `class_name` angelegt hast. Siehe unten — das ist der teuerste Fehler
   überhaupt.
4. **Ein neuer spielersichtbarer String:** englisch schreiben, dann
   `npm run locale:sync`, und den Spiegel unter `godot/assets/locale/` mit
   committen. Ohne den Spiegel übersetzt das Gerät einen Katalog, den das
   Repository nicht hat — und `npm run locale:check` fällt bei genau dem
   Unterschied um. Steht man dabei als Agent in einer Unterteilung, ist
   `sync` Sache der Leitsitzung: siehe „Tests gehören der Leitsitzung".

## Keine Prozesse nach Namensmuster töten

**Ein `kill` mit einem Namensmuster ist ein `kill` gegen den Besitzer.** Getan
worden, mitten in dieser Sitzung: `pkill -f "bin/opencode --auto"` sollte die
Läufe des Runners beenden und hat das **eigene offene Fenster des Besitzers**
mitgenommen, weil dessen Prozess auf dieselbe Zeichenkette passt. Der Dienst
hinter dem Fenster blieb, der Verlauf war nicht verloren — aber das Fenster
schloss sich mitten in seinem Satz.

Ein Namensmuster ist keine Unterscheidung, sondern eine Vermutung. Gilt:

- **Nur töten, was eine Datei benennt.** Der Runner schreibt seine pid nach
  `run/terminal/<runId>.pid`; diese pids sind zweifelsfrei die eigenen. Abbrechen
  läuft ohnehin über `POST /api/runs/:id/cancel`, und das ist der richtige Weg.
- **Ein Muster, das `opencode`, `node`, `python` oder `npm` enthält, ist verboten.**
  Auf dieser Maschine laufen der Dienst des Besitzers, seine Fenster, der
  Dev-Server und Vite gleichzeitig; sie unterscheiden sich nicht über ihre
  Befehlszeile hinweg zuverlässig.
- **Vor dem Töten nachsehen, wer der Besitzer ist.** `ps -o pid,ppid,args` und
  die Elternkette ansehen. Ein Prozess, dessen Eltern ein Terminal des
  Besitzers ist, gehört ihm.
- **Im Zweifel nicht töten und im Bericht sagen, was noch läuft.** Ein
  hängender Prozess ist ein Ärgernis; ein zerstörtes Fenster des Besitzers ist
  ein Vertrauensverlust.

## Tests gehören der Leitsitzung

**Ein Agent aus einer Unterteilung prüft nichts. Das Testen ist die Arbeit der
Leitsitzung, die den Auftrag verteilt hat.**

Das ist keine Formalie, und der Grund ist nicht die Laufzeit. Der Arbeitsbaum
wird geteilt, und zwei Prüfungen desselben Baums sind keine zwei Prüfungen,
sondern ein Rennen:

- **Die Suites sind überschneidend.** Zwei Agenten, die zur selben Zeit
  `npm run test:game` starten, sehen beide denselben Zwischenstand — auch wenn
  beide nur ihre *eigenen* Dateien geändert haben. Der Fehlschlag, den der eine
  meldet, gehört dann zu der halben Arbeit des anderen, und beide Teile
  verlieren Zeit an derselben Diagnose.
- **Zwei der Werkzeuge schreiben.** `npm run locale:sync` überschreibt
  `godot/assets/locale/`, und `npm run locale:lock` schreibt
  `locale/identical.json`. Ein Agent, der `lock` nebenbei laufen lässt, während
  jemand anderes gerade übersetzt, schreibt den unübersetzten englischen Satz
  auf die Liste der absichtlich gleichen Einträge — und der Zähler, der ihn
  eben noch als offen gemeldet hat, meldet danach 100 %. Das ist die
  gefährlichste Folge: aus einer echten Lücke wird eine grüne Zahl, und niemand
  hat etwas kaputtgemacht, es ist nur unsichtbar geworden.
- **Ein Fehlschlag, den man nicht verursacht hat, wird zum Auftrag.** Der Agent,
  der ihn sieht, fängt an, fremden Code zu reparieren, und beide Änderungen
  landen am Ende in einem Commit, den niemand mehr zuordnen kann.

**Was ein Agent stattdessen tut:** die eigene Änderung liest, den Pfad und die
Zeile nennt, und im Bericht **den Befehl aufschreiben, den die Leitsitzung
fahren soll** — nicht das Ergebnis behaupten. „`Loc.f` in
`mesh_gallery_screen.gd:409` ist jetzt aufgelöst, `npm run locale:check` war
vor dieser Änderung grün und sollte es danach auch sein" ist ein brauchbarer
Befund. „Der Test ist grün" ist keiner, wenn drei andere Agenten zur selben
Zeit am selben Baum arbeiten.

Ausgenommen ist das **Lesen** von Dateien und das Nachschlagen in Ausgaben,
die schon da sind: `git status`, `git diff`, `git log`, `grep`, und das Lesen
eines Katalogs. Das kostet niemanden etwas und verändert nichts. Die Grenze
verläuft genau dort, wo ein Befehl den Baum anfasst — und `sync` und `lock`
fassen ihn an, auch wenn sie nach Kontrolle aussehen.

**Die Leitsitzung prüft einmal, am Ende, für alle.** Das ist nicht nur billiger,
sondern das einzige, was eine Aussage wert ist: ein Lauf, der nach allen
Agenten kommt, sieht einen Baum, den niemand mehr anfasst. Wer die Prüfungen
verstreut, bekommt am Ende fünf Teilergebnisse, von denen keines aussagt, ob der
Stand als Ganzes stimmt.

## Neue `class_name` → sofort importieren

`--script`-Modus erneuert den globalen Klassen-Cache **nicht**. Eine neue
`class_name` ist damit bis zum nächsten Import unbekannt, und der Fehler
verschiebt sich dorthin, wo man nicht suchen würde:

- `Screen`/`WorldScreen` parst nicht mehr, **jeder** Screen des Spiels lädt
  nicht mehr, der Router bleibt im Lobby-Screen. Ein Test meldet dann
  „Es ist der 2048-Screen nicht" und prüft dann Eigenschaften eines
  `Lobby3DScreen`.
- Die Suite **hängt** sich tot, weil der Absturz vor `quit()` passiert.

Beides hat in dieser Sitzung gleichzeitig ausgesehen wie „ein kaputter Bildschirm
und ein hängender Test". Nach jeder neuen `class_name` also einmal importieren;
bestehende Suites laden ihre Module bewusst per Pfad (`load("res://…")`) statt
per Klassenname, genau aus diesem Grund.

## Testsuite registrieren: zwei Stellen, nicht eine

Eine neue Suite `t.suite("…")` in `godot/tests/test_<id>.gd` ist **halb**
registriert, bis beides gilt:

- `SCOPE_SUITES` in `scripts/scopes.mjs` — sonst läuft sie in keinem
  Scoped-Lauf mit.
- `godot/tests/run_tests.gd` — sonst lädt der Runner die Datei nie und sie läuft
  auch im Volllauf nicht. GDScript kann die Dateien nicht selbst finden
  (unterschiedliche Parameterzahl, `await`-Probleme beim `call()`), der Runner
  bleibt deshalb handgepflegt; beide Prüfungen laufen über `npm test`.

`npm test` schlägt inzwischen fehl, wenn eine Suite in keinem Scope steht oder
eine `test_*.gd` nicht geladen wird — diese Lücke war lange offen und hat
gleichzeitig sechs nicht registrierte Suites und eine nie geladene Testdatei
durchgewunken.

**Beide Stellen eintragen und dann aufhören.** Der Lauf, der bestätigt, dass die
Suite angekommen ist, ist Sache der Leitsitzung — siehe „Tests gehören der
Leitsitzung". Wer als Agent in einer Unterteilung `npm test` fährt, prüft einen
Baum, an dem gerade jemand anderes arbeitet, und lernt daraus nichts über die
eigene Suite.

## Exportieren und Artefakte prüfen

- **Relative Exportpfade zählen gegen `godot/`, nicht gegen das Repo-Root.**
  `build/x.apk` bedeutet `godot/build/x.apk` und der Export bricht mit
  „Target folder does not exist" ab. Immer absolut übergeben.
- **`exclude_filter` erreicht importierte Ressourcen nicht.** Godot wendet ihn
  auf Nicht-Ressourcen an, ein importiertes `.glb` ist aber eine Ressource:
  gemessen lagen mit `assets/meshes/med/*, assets/meshes/high/*` im Filter alle
  310 reicheren Meshes trotzdem im Paket. `export_filter="exclude"` ist
  schlimmer — es packt die Roh-`.glb`, und ein exportiertes Spiel kann eine
  Roh-`.glb` gar nicht laden. Was wirkt, ist eine `.gdignore` je Ordner.
- **„Export erfolgreich" ist kein Beweis.** Ein schlankes Build kann 120 MB
  wiegen und trotzdem korrekt exiten. `googleplay/scripts/build-apk-slim.mjs`
  prüft den Inhalt (Meshes, `lod.json`, keine Roh-`.glb`); für alles andere
  gilt: das Ergebnis messen, nicht behaupten.
- **Größenangaben in den Docs sind Messungen.** Wenn sich ein Preset ändert,
  neu bauen und die Zahl nachtragen.

## Was ein headless Test nicht sieht

`is_touchscreen_available()` ist unter `npm run test:game` false, es wird also
mit der Maus getestet. Gerätekonfiguration und Nur-Touch-Verhalten fallen
dadurch vollständig durch — echtes Beispiel: `pointing/emulate_mouse_from_touch`
stand auf `false`, und auf dem Tablet war **jeder Knopf des Spiels tot, weil
Godots `Button` auf `InputEventMouseButton` reagiert und ein Fingerdruck nur ein
`InputEventScreenTouch` liefert. Der VirtualStick funktionierte, weil er Touch
selbst auswertet; das Bildschirm-Logbuch sah „Joystick geht, Knöpfe nicht".

Wenn eine Eingabe auf dem Gerät nicht ankommt: erst `project.godot` unter
`[input_devices]` lesen, dann in `res://log/touch/` nach Screenshots schauen,
dann auf dem Gerät messen (`adb` + Logcat). Für das Anhängen von Bildern und
das Auswerten von Logcat gibt es die Agenten `apk` und `device-debug`.


## Befehle

- `npm run typecheck` — `tsc --noEmit`, muss fehlerfrei sein.
- `npm test` — prüft zuerst den Content-Sync, dann `locale:check` (Kataloge
  gegen den Code, Platzhalter gegen Werte, Spiegel gegen Quelle), dann
  `vitest run` (Server/Dashboard).
- `npm run test:game` — **headless GDScript-Suite** (Regeln *und* echte Screens).
- `npm run build` — Vite-Build des Dashboards.
- `npm run content:sync` — `content/*.json` nach `godot/assets/content/` spiegeln
  (Pflicht vor jedem Godot-Build; `npm test` schlägt bei Abweichung fehl).
- `npm run locale:sync` — `locale/*.json` erzeugen/ergänzen und nach
  `godot/assets/locale/` spiegeln. **`locale/en.json` wird dabei überschrieben
  und darf nie von Hand editiert werden.**
- `npm run locale:check` — Drift, Platzhalter, Struktur, Spiegel, `identical`;
  Teil von `npm test`.
- `npm run locale:list` — Deckung je Sprache, der Stand zum Zitieren.
- `npm run locale:lock` — schreibt `locale/identical.json`: die Einträge, die
  absichtlich der Quelle gleich bleiben, je Sprache.
- `npm run godot:import` — Content **und** Locale spiegeln, dann Godot-Import
  der Assets. Ohne den Locale-Schritt überlebt ein veralteter Spiegel den
  Import, und das Gerät übersetzt einen Katalog, den das Repository nicht hat.
- `npm run godot:apk` — Debug-APK, `npm run godot:apk:release` — signiertes Release.
- `npm run godot:android-template` — Godot-Android-Build-Template installieren
  (läuft in `godot:apk*` automatisch mit).
- `npm run smoke` — API-Smoke-Test.
- `npm run backup` — Dashboard-Historie als JSON ins Repository schreiben
  (`-- write`), von dort einlesen (`-- read`) oder nur den Stand melden.
- Reihenfolge für Änderungen: `typecheck` → `test` → `test:game` → `build` → `godot:apk`.

## Struktur

- `godot/` — das gesamte Spiel (GDScript). Siehe unten.
- `server/` — Fastify-API, SQLite, Discord, OpenCode-Runner. **Nicht ändern**,
  außer der Vorschlag verlangt es ausdrücklich.
- `src/dashboard/`, `index.html` — Web-Dashboard, möglichst unverändert. `/` ist
  das Dashboard; `dashboard.html` ist nur noch der Weiterleiter für alte Links.
- `src/shared/` — geteilte Typen/Sortierung. Nicht ändern.
- `content/*.json` — **einzige** Quelle für Spieldaten.
- `godot/assets/content/` — Spiegel davon für die App (nie direkt editieren).
- `locale/*.json` — Sprachkataloge, **einzige** Quelle für die Texte; `en.json`
  wird erzeugt, `de.json`/`fr.json` von Hand gepflegt (siehe „Sprache").
- `godot/assets/locale/` — Spiegel davon für die App (nie direkt editieren).
- `scripts/blender/` — headless Blender-Generator für die 3D-Meshes.
- `backup/dashboard.json` — **gehört ins Git**: die Historie des Dashboards
  (Vorschläge, Entscheidungen, Stimmen, Runs mit Commit). Siehe unten.
- `log/` — JSONL-Log pro KI-Run (nicht committen).

## Agenten-Runner (Dashboard)

`server/runner.ts` startet für jeden Auftrag eine echte `opencode run`-Sitzung
im gemeinsamen Arbeitsbaum. Drei Dinge sind inzwischen wichtig.

**Spuren statt einer Schlange.** `maxParallelRuns` (Einstellungen im Dashboard,
1–8, Vorgabe 3) ist die Zahl der gleichzeitigen Sitzungen. Eine wartende Arbeit
startet nur, wenn eine Spur frei ist **und** kein laufender Run ihren Scope schon
beansprucht — die Regel ist `scopesConflict` in `server/scopes.ts` und sie
entscheidet nach dem *primären* Scope. Das ist Absicht und kein Versehen:
`scopeForSuggestion` hängt an jeden Spielauftrag noch die breite Kategorie
(`core`, `content`), und ein Vergleich der ganzen Scope-Liste würde Tetris und
Pang deshalb wieder hintereinander einreihen.

Was das offen lässt, wird nicht versteckt: Zwei verschiedene Spiele *dürfen* beide
auf `content/` oder `core/` zeigen. Der Scope-Audit meldet es pro Run
(`shared: [...]`), und das Panel beschriftet ein solches Paar
(`laneRisks` in `src/dashboard/queueControls.ts`). Ein Run ohne bekannten Scope
oder mit breitem primären Scope bekommt den Baum immer allein.

**Scopes der Sprachschicht.** Der `core`-Scope besitzt
`godot/src/core/logic/loc.gd`, `godot/src/core/ui/**` (also
`settings_dialog.gd` mit), `godot/tests/test_loc.gd` sowie `locale/**` und
`godot/assets/locale/**`; der `tooling`-Scope besitzt `scripts/locale.mjs` und
`scripts/locale.d.mts`. Zwei Agenten dürfen deshalb nie gleichzeitig an
Katalog und Werkzeug arbeiten — aber sie dürfen es auch nicht versuchen,
`locale/**` zu fassen, um an `content/` zu kommen: das sind zwei verschiedene
Bäume.

**Direkte Aufträge.** `POST /api/tasks` (im Panel: „Direkter Auftrag an OpenCode")
legt eine Empfehlung mit `source: 'operator'` an und stellt sie sofort in die
Schlange — ohne Abstimmung, ohne Spieler, ohne Discord. Sie bleibt eine
Empfehlung, damit Scope-Vorhersage, Wiederholung, Commit-Schutz und Historie
alles weiter funktionieren; nur `status` startet auf `approved`.

**Backup im Repository.** `backup/dashboard.json` enthält Vorschläge,
Entscheidungen, Stimmen und Runs und **gehört committet** — `data/` ist
ignoriert, und genau deshalb wäre die Historie sonst mit der Datenbank weg.
`npm run backup -- write` schreibt sie, `npm run backup -- read` führt sie als
Merge ein (neuere lokale Daten gewinnen, Ids bleiben, ein unfertiger Run aus der
Datei kommt als `cancelled` an). Der Prompt jedes Runs steht **nicht** in der
Datei: er ist aus Empfehlung und Einstellungen ableitbar und wird beim Import neu
gebaut.

## Godot-Spiel

```
godot/
├── main.tscn                 Einstieg → src/main.gd → Router.go_to("lobby")
├── project.godot             Autoloads, Eingaben, Renderer (gl_compatibility)
├── export_presets.cfg        Android-APK (arm64, minSdk 24, targetSdk 35)
├── assets/
│   ├── meshes/               Low-Poly-GLBs (+ med/, high/, lod.json)
│   ├── content/              gespiegelte content/*.json
│   ├── locale/               gespiegelte locale/*.json (Kataloge)
│   └── fonts/                DejaVu Sans (normal + fett)
├── src/
│   ├── main.gd               Boot, Loc.boot(), Backend-Probe im Hintergrund
│   ├── core/
│   │   ├── autoload/         InputSetup, Game, Content, Sfx, Api, Router
│   │   ├── logic/            reine Spiellogik (Renderer-frei, testbar)
│   │   │   ├── asset_registry.gd    Mesh-Keys, Kategorien, LOD-Stufen
│   │   │   ├── game_registry.gd     Kategorien + alle Spiele
│   │   │   ├── loc.gd               Sprachkataloge, Loc.t/tn/f/resolve, Zahlen
│   │   │   ├── mesh_gallery.gd      Galerie-Geometrie, Merkliste, Vorschlag
│   │   │   ├── suggestion_context.gd  Herkunft eines Vorschlags
│   │   │   ├── tetris_rules.gd      T-Spins, Punkte, B2B, Brettgefahr
│   │   │   ├── arena_runs.gd        Wellenvorschau, Boss-Ansage, Kill-Ketten
│   │   │   ├── lobby.gd             Geometrie der 3D-Lobby
│   │   │   ├── candy_match3.gd      Match-3: Züge, Spezialbonbons, 6 Welten × 40 Level
│   │   │   ├── item_inventory.gd    generisches Inventarsystem
│   │   │   └── …                    Karten, 2048, Merge, Kristall, Drache …
│   │   └── ui/                Screen/WorldScreen-Basis, Theme, Widgets,
│   │                          VirtualStick, Kartenrenderer, Dialoge und
│   │                          settings_dialog.gd (Sprache, Ton, Touch,
│   │                          Serveradresse — der ⚙-Knopf jedes Screens)
│   └── game/<spiel>/          ein Verzeichnis je Spiel (s. u.)
└── tests/                    TestKit, Regel-, Verbesserungs- und Screentests
```

### Ein Spiel hinzufügen

1. `godot/src/game/<name>/<name>_screen.gd` anlegen.
2. **2D:** `extends Screen`. **3D:** `extends WorldScreen`. Nichts anderes erben.
3. `Ui.*`-Helfer für Widgets benutzen, **keine** `.tscn` schreiben — jeder Screen
   baut seinen Baum in `_ready_game()` bzw. `_ready_world()`.
4. Eingabe ausschließlich über `Input`-Actions (siehe `InputSetup`) und
   `VirtualStick.combined(...)`; für 3D `add_stick()` / `add_action_button()`.
5. In `game_registry.gd` eintragen (id, name, icon, screen, accent, category,
   highscore_key) und in `router.gd` den Screen-Pfad mappen.
6. Logo-Icon: **DejaVuschrift** kann ♠♥♦♣♞☄✦◆▣▦◼ u. a. — keine Emojis.
7. Hochscore über `Game.submit_score(<key>, wert)`, niemals selbst speichern.

### Basisklassen

`Screen` (2D) und `WorldScreen` (3D) bringen Top-Bar, Vorschlagsdialog, Theme,
Kamera-Follow und Touch-Steuerung mit.

- **Namen der Basisklasse nicht überschreiben.** Ein Unterklasse, die
  `_build_hud`/`_build_environment`/`show_toast` selbst definiert, bricht die
  Basis. Eigene Einstiegspunkte heißen `_ready_game`, `_ready_world`,
  `_update_world`, `_build_ui`, `_build_panels`, `_build_scenery`.
- Für eine kurze Meldung im 3D `notify(text)` benutzen (nicht `show_toast`).
- `WorldScreen.mesh(key, …)` nimmt einen Registry-**Key** oder einen fertigen
  `res://`-Pfad (für die LOD-Stufen) und liefert `null`, wenn der Import fehlt.

### Level-Spiele (Sterne)

`Game.stars(game_id, key)`, `Game.submit_stars(game_id, key, wert)` und
`Game.star_map(game_id, keys)` speichern Sterne unter `number.stars/…`. Ein
Level-Schlüssel ist die globale Levelnummer (`"7"`), das Tageslevel `"daily:JJJJ-MM-TT"`.
`CandyMatch3.world_stars(levels, welt_id)` zählt die Sterne einer Welt, und
`world_bonus(stars)` übersetzt sie in Extras (Züge, Undo, Start-Farbbombe).
Sterne zählt der Lobby aus `CandyMatch3.total_level_count()`; ein `star_max`
-Feld im Registry-Eintrag gab es und wurde entfernt, weil nichts es gelesen hat.

### Vorschläge

`SuggestDialog.open(self, kontext)` bzw. `open_world(self, kontext)`. Ohne
`kontext` wird der aktive Bildschirm als Herkunft eingesetzt und dem Text
vorangestellt (`SuggestionContext.compose`), damit niemand „geht um Tetris“
tippen muss. `Api.submit_suggestion(text, author, kontext)` macht das gleiche für
Aufrufe außerhalb des Dialogs.

**Ohne eingetragene Server-Adresse geht ein Vorschlag nirgends hin**, er landet
in `user://` und wartet. Die Adresse ist deshalb über den `⚙`-Knopf in der
Top-Bar **jedes** Screens erreichbar, und der Knopf öffnet `SettingsDialog`
(`godot/src/core/ui/settings_dialog.gd`) — dort steht sie neben Sprache, Ton
und Touch-Steuerung. Vorher lag sie nur im Menü des Arena-Spiels, also genau
nicht dort, wo jemand sie braucht, der Tetris spielt. `ServerDialog.apply()`
setzt die Adresse **und stößt die Warteschlange sofort an**; ohne das
`Api.wake()` wartet die Idee noch bis zu `BACKOFF_MAX` (5 Minuten), obwohl die
Adresse längst stimmt. Der Hauptbildschirm zeigt die wartende Zahl samt Grund
an, `SettingsDialog` dieselbe Zahl.

### Performance-Regeln

- Keine Allokationen im `_process`/`_update_world`: Pools vorallozieren
  (Arena: 220 Gegner, 400 Geschosse, 160 Kristalle; Drachen-RPG: 24 schwebende
  `Label3D` aus `_build_label_pool`).
- `_draw()` nur bei Änderung (`queue_redraw()`), nie im Takt neu aufbauen.
- 3D-Materialien entstehen einmalig über `WorldScreen.tint()` /
  `WorldScreen.standard_material()`; `StandardMaterial3D` nicht pro Frame anlegen.
- Meshes kommen **ausschließlich** über `AssetRegistry`/`WorldScreen.mesh()`.

### Meshes und Detailstufen

- Format: binäres glTF 2.0 (`.glb`), Godot importiert nativ.
- Erzeugen: `blender --background --python scripts/blender/make_mesh.py -- --out … --name <builder>`
  bzw. `scripts/blender/generate_rpg_meshes.py` für den Drachen-Pack.
- **Jedes neue Mesh braucht einen Key in `AssetRegistry.KEYS`** — zwei Tests
  schlagen fehl, wenn Liste und Ordner auseinanderlaufen.
- Fehlt ein Mesh, benutzt `WorldScreen.mesh()` ein prozedurales Primitiv;
  3D-Spiele starten dadurch nie mit leerer Szene.
- Jedes Mesh liegt in drei Stufen: `assets/meshes/<key>.glb` (Low, das benutzen
  die Spiele), `assets/meshes/med/<key>.glb` (~1.000 Dreiecke) und
  `assets/meshes/high/<key>.glb` (~10.000 Dreiecke, mit Displacement).
  Neu erzeugen:
  ```bash
  blender --background --python scripts/blender/generate_lod_meshes.py -- \
      --out godot/assets/meshes --stats godot/assets/meshes/lod.json
  ```
  Das Skript misst die Dreieckzahlen und schreibt sie nach `lod.json`; die
  Galerie zeigt sie an, der Test prüft `med ≥ low` und `high ≥ med`.
  **Nach jedem neuen Mesh erneut laufen lassen**, sonst fehlen die höheren Stufen.
- Die beiden reichen Stufen kosten zusammen rund 45 MB APK. Ohne sie wird das
  Release gut 80 MB kleiner — dafür zeigt die Galerie nur ein einziges Mesh.
- `include_filter="*.json"` im Export-Preset ist Pflicht: `.json` wird nicht
  importiert und käme sonst nicht ins Paket (die Galerie braucht `lod.json`).

### Android

- `project.godot`: `renderer/rendering_method = gl_compatibility` (breite
  Geräteabdeckung), `stretch/mode = canvas_items`, `aspect = expand`.
- `pointing/emulate_mouse_from_touch` **muss `true` bleiben.** Godots `Button`
  reagiert auf `InputEventMouseButton`; mit `false` liefert ein Fingerdruck nur
  ein `InputEventScreenTouch` und damit ist auf dem Tablet jeder Knopf tot,
  während der VirtualStick funktioniert, weil er Touch selbst auswertet. Der
  Fehler sieht aus wie „Bildschirm kaputt" und ist es nicht.
- 2D-Spiele mit festem Layout bauen in `stage()` (1280×720, zentriert);
  Menüs in `content_layer()` (füllt das Fenster) mit Containern.
- `config/name` muss ein gültiger Android-Identifier sein (kein Leerzeichen);
  der schöne Anzeigename steht in `package/name` im Export-Preset.
- Keine Godot-Editor-Komponenten zur Laufzeit; keine externen Dateien zur Laufzeit.
