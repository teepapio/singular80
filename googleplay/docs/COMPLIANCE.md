# 05 — Compliance: Zielgruppe, Freigabe, Datenschutz, UGC

Recherche-Stand September 2026. Jede Aussage unten ist mit dem Quellenhinweis am
Abschnittende belegt; die Zahlen und Fristen ändern sich, die Policy-Dokumente
nicht.

## Überblick der Pflichtangaben

| Bereich | Was Play verlangt | Antwort für Singular 80 |
|---|---|---|
| Zielgruppe & Inhalt | Altersgruppen | 13+ und 18+ (siehe unten) |
| Inhaltsbewertung | IARC-Fragebogen | ESRB Teen erwartet |
| Datenschutz | Data-Safety-Formular + URL | 1 Datentyp, verschlüsselt, Löschung möglich |
| Datenschutz | Nutzungsbedingungen (bei UGC) | `legal/terms-of-use.en.md` |
| UGC | Moderation, Meldeweg | `legal/moderation.md` — **Lücke: nicht in der App** |
| Werbung | Deklaration | keine |
| In-App-Käufe | Deklaration | keine |
| Be为目标Zugangsdaten | Test-Zugangsdaten | nicht nötig (kein Login) |

## 1. Zielgruppe und Inhalt (Target Audience and Content)

Im Play Console anzukreuzen, **vor** dem ersten Upload.

**Vorschlag: nur „13 and under" + „18 and under", nichts darunter.**

* **Poker ist der Grund.** Texas Hold'em und FreeCell gelten im IARC-Fragebogen
  als *simuliertes Glücksspiel*. ESRB vergibt dafür „Teen (13+)"; in der EU
  führt das typischerweise zu PEGI 12/16, und die Spielbankaufsicht sieht
  Glücksspiel-Simulationen ohnehin kritisch.
* **Keine Altersgruppe unter 13 anzukreuzen.** Sobald „Children" Teil der
  Zielgruppe ist, greift die **Families-Policy**: neutrale Altersabfrage,
  zertifizierte Werbe-SDKs, keine personalisierte Werbung, zusätzliche
  Datenschutzpflichten, und „Glücksspiel-Simulationen" sind dort ein
  ausdrücklicher Policy-Verstoß. Das wäre die größte Fehlerentscheidung, die
  man in diesem Formular treffen kann.
* Ein Spiel ohnehin mit „Poker" im Titel und auf dem Feature Graphic sichtbar zu
  bewerben und dann „9 and under" anzukreuzen, wäre eine
  Fehldeklaration — Google prüft die Bilder gegen die Angaben.

**Weitere Antworten im selben Formular:**

| Frage | Antwort | Begründung |
|---|---|---|
| Enthält die App Werbung? | Nein | keine Ad-SDKs im Projekt, keine Werbeflächen |
| In-App-Käufe? | Nein | keine Billing-Bibliothek, keine Käufe |
| App teilen/übertragen? | Ja | Screenshots und Feature Graphic |
| Standort sammeln? | Nein | keine Location-Permission, `permissions/*` ist leer |
| Verschlüsselte Kommunikation? | Teilweise | nur wenn der konfigurierte Server HTTPS nutzt → **HTTPS vorschreiben** |
| Nutzerinteraktion? | **Teilen/Verschieben erlaubt** | die Spieler tauschen Texte über den Backend-Dienst; das Formular fragt das ab, es ist keine Täuschungsoption |
| Nutzergenerierte Inhalte? | **Ja** — siehe Abschnitt 3 |
| Spiel mit Glücksspiel-Elementen? | **Ja, simuliert** — siehe Abschnitt 2 |

## 2. Inhaltsbewertung (IARC)

Der Fragebogen ist ein einziger Fragebogen für alle Altersregionen; Google
zeigt davon abhängig ESRB (US), PEGI (EU), USK (DE/AT), IARC und einzelne
Länderlogos an.

Zu erwartende Antworten, abgeleitet aus dem, was im Code nachweisbar ist:

| Kategorie | Frage | Antwort |
|---|---|---|
| Violence | Blut, Gewalt gegen Figuren, zerstörbare Umgebung | **Nein** (keine Waffen, kein Blut, abstrakte Gegner) |
| Sexuality | Sexueller Inhalt, nudity | **Nein** |
| Language | Vulgäre Sprache, Humor | **Nein** (alle Texte in der App sind gepflegt) |
| Controlled Substances | Alkohol, Tabak, Drogen | **Nein** |
| Gambling | Echtes Geld | **Nein** |
| Gambling | **Simuliertes Glücksspiel** | **Ja** — Poker und Kartenspiele |
| Miscellaneous | Benutzerinteraktion | **Ja** — Vorschläge |
| Miscellaneous | **Nutzergenerierte Inhalte** | **Ja** — Textvorschläge |
| Miscellaneous | Standort teilen | Nein |
| Miscellaneous | Digitale Käufe | Nein |

Folge: **ESRB Teen** (13+), was die Zielgruppenangabe „13 and under" stützt.
Antworten zu USK/PEGI nicht selbst festlegen — Google lässt die
Rating-Agentur darüber entscheiden.

Wichtig: Die Antworten müssen mit dem übereinstimmen, was tatsächlich im Build
ist. `npm run preflight` prüft nicht den IARC-Fragebogen (der wird im Browser
ausgefüllt), aber es prüft Permissions und Paketname — die Grundlage der
Deklaration.

## 3. Nutzergenerierte Inhalte (UGC)

Die App nimmt **Textvorschläge** entgegen und legt sie in einem internen
Dashboard ab. Damit ist sie eine UGC-App im Sinne der Play-Policy.

Was Play verlangt und der Stand in diesem Projekt:

| Anforderung | Status |
|---|---|
| Nutzer akzeptieren die Bedingungen, **bevor** sie hochladen | Bedingungen existieren; die App muss den Dialog-Zustimmungstext ergänzen — **noch offen** |
| Bedingungen definieren verbotene Inhalte | ✅ `legal/terms-of-use.en.md` §4 |
| Laufende Moderation | ✅ manueller Prüfprozess, `legal/moderation.md` |
| **Meldesystem in der App** | ❌ **Lücke** — bisher nur per E-Mail |
| Blockierfunktion | entfällt: keine 1:1-Interaktion, keine Nutzerkonten, kein öffentlicher Feed |
| Keine Monetarisierung von problematischem Verhalten | ✅ keine Werbung, keine Käufe |
| Sexueller Inhalt standardmäßig ausgeblendet | entfällt: nicht zu erwarten, Moderation greift vorher |

**Zwei Wege, die Lücke zu schließen (Empfehlung: Weg 2 für den closed test):**

1. Meldefunktion im Dashboard ergänzen (dort, wo die Vorschläge stehen) —
   kurzer Aufwand, ehrlich, aber nicht in der App selbst.
2. **Für den closed test die Vorschlagsfunktion ausliefern, aber nicht aktiv.**
   Die App startet ohne Server-Adresse im Offline-Modus; die Vorschläge bleiben
   lokal in der Queue. Damit wird im Test öffentlich gar kein UGC
   eingesammelt, die UGC-Antwort lautet wahrheitsgemäß „Nein", und vor dem
   öffentlichen Launch werden Meldefunktion und Zustimmungstext ergänzt.
   **Das ist die sauberste Variante für den ersten Release.**

Wer die Funktion schon im closed test aktiv haben will, braucht Antwort 1 und
muss die UGC-Fragen mit „Ja" beantworten.

## 4. Datenschutz (Data safety)

Pflicht für **jede** App, auch ohne Datenerhebung, und ausgefüllt auf der Seite
*App content*. Ohne abgegebene Formulare blockiert Play Updates.

Vorgesehene Antworten (Code-Beleg):

| Frage | Antwort | Beleg im Projekt |
|---|---|---|
| Werden Daten gesammelt/geteilt? | **Ja** | `Api.submit_suggestion()` sendet Text + Autor-Name an den Server |
| Datentyp | **Other user-generated content** (freier Text) | `api_client.gd` |
| Zweck | **App functionality** (die Vorschlagsfunktion) | `Api` |
| Optional oder Pflicht? | **Optional** — die App funktioniert ohne, der Nutzer entscheidet pro Vorschlag | Offline-Modus |
| Verschlüsselt unterwegs? | **Ja**, sobald der Server HTTPS ist → **als Bedingung festhalten** | — |
| Löschung möglich? | **Ja**, per Anfrage | `legal/privacy-policy.en.md` §7 |
| Weitergabe an Dritte? | **Nein** | keine Werbe-/Analyse-SDKs |
| Werden Daten aus dem Gerät entfernt? | **Ja**, beim Deinstallieren | `user_data_backup/allow=false` |
| Werden personenbezogene Daten aus Kindern gesammelt? | **Nein** | Zielgruppe 13+, siehe oben |

Wichtige Zusätze:

* **Klartext-HTTP vermeiden.** Die App erlaubt jede Server-Adresse. Für den
  Test unproblematisch, aber die Datenschutzantwort „verschlüsselt" stimmt nur
  mit HTTPS-Server. `config/app.json → urls.backend` ist deshalb als `https://`
  auszufüllen, und `npm run preflight` weist `http://` ab.
* **Keine Identifier.** Das Projekt nutzt weder AAID noch ein Analytics-SDK;
  das vereinfacht das Formular erheblich.
* Das Formular lässt sich als CSV exportieren und importieren
  (App content → Data safety → Export/Import), falls das Ausfüllen im Browser
  nervt.

## 5. Weitere Erklärungen im Formular

* **Government app / Finance / Health** → alle **Nein**.
* **Content guidelines** (Konten, Speicher, Werbung) → alle **Nein**.
* **App access**: alle Funktionen sind ohne Login erreichbar → keine
  Test-Zugangsdaten nötig. Das beschleunigt Reviews, weil niemand auf ein
  Konto warten muss.
* **Target audience and content → News**: **Nein**. News-Apps bekommen
  zusätzliche Prüfungen, und das Dashboard ist kein Medium.
* **Advertising ID**: **Nein**, es wird keiner verwendet.
* **Privacy policy** URL: Pflichtfeld, muss erreichbar sein → `legal/privacy-policy.en.md`
  veröffentlichen und eintragen.
* **Data deletion**: Play-Formular ausfüllen und zusätzlich in der App bzw. auf
  der Website anbieten (Link im Impressum reicht).

## 6. Was dieses Projekt technisch bereits sauber hält

* `INTERNET` und `VIBRATE` als einzige Permissions — kein Standort, kein
  Speicher, kein Telefon, kein `AD_ID`.
* `user_data_backup/allow=false` — keine Daten wandern in ein Backup.
* `package/show_in_android_tv=false` — die App wird nicht im TV-Store gelistet.
* Kein Login, kein Tracking, keine Werbe-SDK-Abhängigkeit im `package.json`.

`npm run verify` prüft die Permissions nach jedem Build und schlägt fehl, wenn
etwas dazukommt.

## Quellen

* UGC-Policy: <https://support.google.com/googleplay/android-developer/answer/9876937>
* Families-Policy: <https://support.google.com/googleplay/android-developer/answer/9893335>
* Data safety: <https://support.google.com/googleplay/android-developer/answer/10787469>
* Inhaltsbewertung: <https://support.google.com/googleplay/android-developer/answer/9859655>
* Zielgruppe: <https://support.google.com/googleplay/android-developer/answer/9866642>
* Glücksspiel: <https://support.google.com/googleplay/android-developer/answer/9877042>
* Permissions deklarieren: <https://support.google.com/googleplay/android-developer/answer/9214102>
* Datenschutzrichtlinie: <https://support.google.com/googleplay/android-developer/answer/10144311>
