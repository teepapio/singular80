# Android-Testfarm

Automatisierte Spiele-Tests auf echten Android-Instanzen, mehrere parallel.
Der Zweck ist nicht „die App startet", sondern **„so spielt ein Mensch, und
danach ist die Maschine in einem Zustand, in dem man etwas ändern kann"**.

## Warum nicht Waydroid

Waydroid braucht die Kernel-Module `binder_ls` und `ashmem`. Der
Ubuntu-Mainline-Kernel liefert sie nicht, und `waydroid` steht nicht einmal in
den Quellen. `npm run farm:doctor` prüft das nach, statt es zu behaupten:

```
✗ Waydroid möglich      weder /dev/binder* noch Modul binder_ls
```

Die Farm ist trotzdem **laufzeitneutral** gebaut: sie spricht ausschließlich
`adb` an. Jedes Backend, das sich so anreden lässt, erfüllt dieselbe
Schnittstelle — der Emulator ist der, der auf dieser Maschine läuft, ein
Waydroid-Container käme über `tools/devfarm/lib/waydroid.mjs` dazu, sobald der
Kernel es hergibt. Ein echtes Tablet an USB ebenso (`adb devices`).

## Warum der Emulator

`/dev/kvm` ist da, damit läuft eine Instanze in Echtzeit statt in
Interpretation. Und `-read-only` erlaubt **N Instanzen aus einem einzigen
AVD**: ohne das Flag teilen sich die Instanzen ein userdata-Image, die erste
schreibt darauf, während die zweite noch bootet, und man bekommt genau die Art
Absturz, die man dem Testwerkzeug nicht anlasten will. Mit dem Flag bekommt
jede Instanz eine eigene Kopie im Arbeitsspeicher — es kostet RAM statt
Festplatte, und vier Instanzen passen bequem nebeneinander.

## Das Farm-APK ist ein eigenes

Das ausgelieferte APK ist **arm64-only**. Ein x86_64-Emulator lehnt es mit
„no matching ABI" ab, und die Meldung sieht nach einem kaputten Emulator aus
statt nach einer Architekturfrage. Deshalb gibt es `Android (Farm)`:

| | arm64-v8a | x86_64 | Paketname |
|---|---|---|---|
| `Android` (ausgeliefert) | ✓ | — | `de.singular80.game` |
| `Android (Leicht)` | ✓ | — | `de.singular80.game` |
| `Android (Farm)` | ✓ | ✓ | `de.singular80.farm` |

Eigener Paketname heißt: Die Farm-App installiert **neben** dem echten Spiel
und kann weder dessen Spielstand noch die Highscores anfassen.

## Loslegen

```bash
npm run farm:doctor      # sagt, was fehlt
npm run farm:bridge      # Schleife; laeuft weiter, im Hintergrund
npm run farm:start       # Instanzen aufziehen (~90 s Boot pro Instanz)
npm run farm:status
```

Beide Dienste sind **eigene Prozesse** und überstehen den Agenten: eine
Emulator-Instanz braucht ~90 s bis zum Boot und danach eine Grundlast, die man
nicht pro Subthread neu bezahlen will. Die Subthreads mieten sie nur für die
Dauer ihres Laufs.

## Ein Lauf

```bash
npm run farm:session -- --game tetris --audit --shots 2
npm run farm:sweep -- --shots 1          # alle Spiele nacheinander
npm run farm:session -- --list-games
```

Der Bericht liegt unter `log/devfarm/<lauf>/<spiel>/`:

| Datei | Inhalt |
|---|---|
| `report.json` | Funde, Messwerte, Fehlerzeilen — **das braucht ein Agent** |
| `logcat.txt` | Rohdaten des Laufs |
| `shot-*.png` | Bildschirmfotos |

## Was ein Agent wissen muss

Ein Lauf ist eine Miete, kein Besitz: `session.mjs` belegt eine Instanz über
`flock` und gibt sie im `finally` wieder frei. Ein abgestürzter Agent blockiert
die Farm also nicht — der Kernel gibt die Sperre frei, sobald der Prozess weg
ist. Genau darum ist es `flock` und keine Flagge in einer JSON-Datei: eine
Flagge bräuchte eine Aufräumroutine, die genau dann fehlt, wenn es kracht.

Wenn ein Agent drei Fehler an drei verschiedenen Spielen sucht, startet er
**drei Sessions gleichzeitig** — sie landen auf drei Instanzen und stören sich
nicht. Für alle Spiele nacheinander auf *einer* Instanz ist `--sweep` da.

## Die Brücke

Kommandos gehen über HTTP an die App, und die App führt sie mit denselben
Eingaben aus, die auch ein Spieler benutzt. Es gibt also keinen Testkanal, der
am Spiel vorbeiführt und deshalb etwas anderes prüft als das Ausgelieferte.

```
POST /register           {"id":"…"}
GET  /next?id=…          {"op":"audit","args":{}}
POST /event              {"id":…,"type":"audit","data":{…}}
POST /command            {"id":…,"op":"goto","args":{"screen":"tetris"}}
GET  /events?id=…&type=audit
GET  /health
```

Befehle: `goto`, `audit`, `tap`, `tap_button` (tippt den Knopf mit dieser
Beschriftung — Bildschirmkoordinaten stimmen zwischen Geräten nicht), `key`,
`soak`, `metrics`, `shot`, `quit`.

Die App liest das nur, wenn sie mit `--devfarm` startet; sonst ist das
Autoload sofort inert. Im ausgelieferten Spiel kostet es eine leere Zeile.

## Der Audit ist das Wichtigste

`audit` schickt für **jeden** Knopf einen echten `InputEventScreenTouch` auf
seine Mitte und prüft, ob `pressed` kommt. Vorher prüft es, ob die Fläche
überhaupt stimmt und ob etwas darüber liegt.

Damit werden genau die zwei Fehler gefunden, die Screenshot und headless Test
übersehen:

- **Zugedeckt.** Ein `MOUSE_FILTER_STOP`/`PASS`, das später im Baum hängt,
  schluckt jeden Tipp. Der Knopf ist sichtbar, richtig positioniert und tot.
- **Nicht verdrahtet.** `Ui.button()` verbindet nur
  `if on_press.is_valid()` — fehlt der Callback, ist der Knopf ebenfalls tot.

Deshalb ist `soak` absichtlich **kein** Zufallssturm: die Aktionen kommen aus
dem InputMap des geöffneten Spiels, also die Eingaben, die dort etwas bewirken.
Ein Sturm aus beliebigen Tasten findet nichts und produziert nur Rauschen.
