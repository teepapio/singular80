# 02 — Play Console: Konto, Verifizierung, App anlegen

Recherche-Stand September 2026. Links am Ende.

## 1. Konto anlegen

1. Google-Konto bereithalten (ein einziges Konto ist Account-Owner und hat
   damit die Rechte über Zahlungen, Mitglieder und die Developer-Seite).
2. `play.google.com/console` → **Registrieren**. Einmalig **25 USD** Gebühr
   (Kartenzahlung, je nach Land auch Überweisung/Bankabbuchung).
3. **Kontotyp wählen — nicht später änderbar:**

   | | Persönlich | Organisation |
   |---|---|---|
   | Kosten | 25 USD einmalig | 25 USD einmalig + wiederkehrende Gebühr pro Jahr (derzeit ab ~25 USD, gestaffelt nach Größe) |
   | Nachweis | Ausweis (Personalausweis/Reisepass) + Adressnachweis | Handelsregisterauszug + D-U-N-S-Nummer + offizielle Website |
   | Öffentlich sichtbar | dein Name + Land | Firmenname + Land |
   | Testpflicht | **12 Tester / 14 Tage**, bevor Production frei wird | keine |
   | Warste | 1–2 Wochen bis zur Verifizierung | D-U-N-S kann 30+ Tage dauern |

   **Empfehlung:** persönlich. Der Nachteil ist die Testpflicht — aber die
   14 Tage laufen ohnehin, und die Alternative (D-U-N-S-Nummer) dauert länger,
   wenn man sie beantragen muss.

4. **Zahlungsprofil** anlegen (Pflicht, seit 2023). Es verifiziert die
   Identität; es wird mit dem Konto verknüpft, nicht mit einzelnen Apps.
5. **Kontotyp bestätigen** (bei Organisation: D-U-N-S), dann
   **Zahlungsprofil wählen/erstellen**, dann **Kontaktdaten** und
   **öffentliche Entwicklerprofil**-Angaben.

### Was in der Konsole öffentlich erscheint

* **Legal name** — bei persönlichen Konten der volle Name, wie im Ausweis.
* **Legal address** — das Land bzw. die Adresse (teils öffentlich sichtbar).
* **Öffentliche Support-E-Mail** — steht auf der App-Seite.
* Optional: Website.

Diese Werte stehen in `config/app.json` unter `owner` und `urls` und müssen
ausgefüllt werden, bevor das Formular abgeschickt wird.

## 2. Identität verifizieren (Play Console Requirements)

Neue Konten (seit 2023) müssen vor dem Veröffentlichen verifiziert werden:

* **Legal name** (identisch zum Ausweis)
* **Legal address**
* **Private E-Mail + Telefon** (per Einmalcode bestätigt — **nicht** die
  öffentliche Support-Adresse)
* **Öffentliche E-Mail** für das Entwicklerprofil
* **Website** (bei persönlichen Konten optional)
* **Ausweisdokument**, farbig, scharf, nicht als Kopie/Handyfoto, gültig

Für Organisationen zusätzlich: Handelsregisterauszug, D-U-N-S-Nummer
(Dokumentenname muss mit dem D-U-N-S-Eintrag übereinstimmen), Organisations-
typ, Größe, Website.

Nach dem Absenden prüft Google manuell: **einige Tage, gelegentlich Wochen**.
Deshalb Schritt 1 sofort beginnen.

## 3. App anlegen

`Create app` (nur möglich, wenn die Verifizierung durch ist bzw. die App
verifiziert werden kann — die Verifizierung ist Voraussetzung, nicht umgekehrt).

| Feld | Wert | Herkunft |
|---|---|---|
| App name | `Singular 80` | `app.storeName` |
| Default language | English (United States) | `app.defaultLanguage` |
| App or game | **App** | — |
| Free or paid | **Free** | `listing.appFree` |
| Declarations | Signing Form / externe Werbung = ansehen | [`COMPLIANCE.md`](COMPLIANCE.md) |
| App access | alle Funktionen ohne Login erreichbar → keine Test-Zugangsdaten nötig | `npm run preflight` prüft das |
| Category | Game → (Unterkategorie optional) | `app.appCategory` |
| Contact email | öffentliche Support-Adresse | `urls.support` / `owner.contactEmail` |
| Privacy policy | **Pflicht-URL**, öffentlich erreichbar | `urls.privacyPolicy` |

**Wichtig:** Der **Paketname** (`de.singular80.game`) wird beim ersten AAB-Upload
automatisch aus dem Bundle gelesen und ist danach unveränderlich. Ein Tippfehler
bedeutet ein neues Listing. Er steht in `config/app.json` unter
`app.packageName`; `npm run verify` vergleicht ihn mit dem gebauten AAB.

## 4. Nach dem ersten Upload

* **Play App Signing** ist Pflicht: Beim ersten hochgeladenen AAB fordert Play
  einen **Upload-Key** an. Dafür den Keystore aus `npm run keystore` verwenden.
  Google erzeugt daraus den App-Signatur-Key (RSA-2048, von Google verwahrt).
* Unter *Release* → *Setup* → *App integrity* kann man das Zertifikat sehen und
  mit `PLAY_KEYSTORE_SHA256` vergleichen (siehe [`RELEASE.md`](RELEASE.md)).
* Danach existieren *Test and release* mit den Tracks **Internal testing**,
  **Closed testing**, später **Open testing** und **Production**.

## 5. Nützliche Zusätze (optional, aber empfohlen)

* **Pre-Launch report** — Play testet den AAB auf ~50 realen Geräten und
  meldet Crashes, ANRs, Performance. Für den closed test unbedingt einschalten.
* **Staged rollout** — auch für die Production: 5 % → 20 % → 100 %.
* **Play Store listing experiments** — später für A/B-Tests der Grafik.

## Quellen

* Developer-Konto anlegen: <https://support.google.com/googleplay/android-developer/answer/13628312>
* Kontotyp wählen: <https://support.google.com/googleplay/android-developer/answer/13634814>
* Verifizierung: <https://support.google.com/googleplay/android-developer/answer/14177239>
* App erstellen: <https://support.google.com/googleplay/android-developer/answer/9859154>
* Play App Signing: <https://support.google.com/googleplay/android-developer/answer/9842756>
* Pre-Launch report: <https://support.google.com/googleplay/android-developer/answer/9855338>
