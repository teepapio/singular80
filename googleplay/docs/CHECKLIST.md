# 07 — Abnahme-Checkliste

Stand: September 2026. `npm run preflight` prüft alles Technische
automatisch; diese Liste deckt die Dinge ab, die nur im Play Console passieren
können.

## Status heute

| Bereich | Stand |
|---|---|
| Android-SDK 36 + Build-Tools | ✅ erledigt |
| Godot-Template auf targetSdk 36 | ✅ erledigt (muss nach jedem Template-Install neu) |
| bundletool/Manifest-Prüfung | ✅ erledigt |
| Export-Preset „Google Play (AAB)" | ✅ erledigt, idempotent |
| Signierter AAB-Build | ✅ erledigt (77,5 MB, targetSdk 36, Paketname korrekt) |
| AAB-Verifikation | ✅ erledigt |
| Store-Icon + Feature Graphic | ✅ erledigt, von `npm run assets` erzeugt |
| Store-Texte en/de | ✅ Entwurf, von `npm run preflight` geprüft |
| Rechtstexte | ⚠️ Entwurf mit Platzhaltern |
| Screenshots | ❌ headless nicht renderbar, Import-Modus bereit |
| Play-Konto + Verifizierung | ❌ braucht dich |
| 12 Tester | ❌ braucht dich |

## A — Angaben von dir

- [ ] **Play-Konto**: registriert? 25 USD bezahlt? (`play.google.com/console`)
- [ ] **Kontotyp** entschieden: persönlich (empfohlen) oder Organisation?
- [ ] **Zahlungsprofil** angelegt und mit dem Konto verknüpft
- [ ] **Verifizierung** eingereicht: Ausweis, Adresse, private Mail + Telefon,
      öffentliche Mail (Angaben stehen in `config/app.json` unter `owner`)
- [ ] **Öffentliche Support-Adresse** festgelegt
- [ ] **Website/Impressum** bereit und erreichbar (`legal/imprint.md`)
- [ ] **Upload-Keystore** erzeugt: `npm run keystore`, Passwort im
      Passwortmanager, **Zertifikat-SHA-256 notiert**
- [ ] **Backend-URL** öffentlich und über HTTPS erreichbar (oder Feature für den
      Test ausgeschaltet lassen)

## B — Konfiguration hier im Projekt

- [ ] `config/app.json`: alle `TODO:` ersetzt (prüft `npm run preflight`)
- [ ] `config/app.json`: `version.versionCode` / `version.versionName` gesetzt
- [ ] `legal/*.md`: alle `[[PLATZHALTER]]` ersetzt
- [ ] Rechtstexte **veröffentlicht** und unter den URLs in `config/app.json`
      erreichbar (nicht nur im Repo)
- [ ] `npm run preflight` ohne Blocker
- [ ] Screenshots: 2–4 Stück importiert (`npm run screenshots -- --import …`)

## C — Play Console: App anlegen

- [ ] App-Name, Default-Sprache, „App or game: **App**", „Free"
- [ ] Deklarationen im Wizard
- [ ] **App access**: alle Funktionen ohne Login → keine Test-Zugangsdaten
- [ ] Kategorie Game, Kontakt-E-Mail
- [ ] **Privacy-Policy-URL** (Pflicht, sonst speicherbar erst mit URL)

## D — App content (die Formulare)

- [ ] **Target audience**: 13 and under + 18 and under, **nichts unter 13**
- [ ] Keine Werbung, keine In-App-Käufe
- [ ] **Data safety** ausgefüllt (1 Datentyp: „Other user-generated content“,
      Zweck App functionality, optional, verschlüsselt, Löschung möglich)
- [ ] **IARC-Fragebogen**: simuliertes Glücksspiel **ja**, UGC **ja** (bzw.
      **nein**, wenn die Vorschlagsfunktion im Test aus bleibt — siehe
      `legal/moderation.md`)
- [ ] **UGC**: Bedingungen akzeptierbar vor dem Senden; Meldeweg dokumentiert
- [ ] Keine Government-/Finance-/Health-/News-Deklaration

## E — Store listing

- [ ] Icon 512×512, Feature Graphic 1024×500, 2–4 Screenshots 16:9
- [ ] Kurz-/Vollbeschreibung + Captions aus `listing/*.md`
- [ ] *External marketing*: pokernahes Spiel, Empfehlungen mit Kinderfokus
      besser aus

## F — Release

- [ ] Erster AAB in **Internal testing** hochgeladen
- [ ] **Pre-Launch report** gestartet und abgewartet
- [ ] Test auf eigenen Geräten (Android 7/8/13/16, Hoch- und Querformat)
- [ ] **Closed testing**-Track angelegt, Tester eingeladen, Opt-ins bestätigt
- [ ] **14 Tage** ab dem 12. Opt-in abgewartet
- [ ] Produktionsantrag gestellt (mit ehrlicher Feedback-Zusammenfassung)
- [ ] Production-Release mit **staged rollout 5 %** statt auf 100 %

## Wiederkehrend bei jedem Release

```bash
cd googleplay
npm run check      # Werkzeugkette + Konfiguration
npm run release    # preflight + build + verify
```

1. [ ] `config/app.json`: `version.versionCode` **erhöht**
2. [ ] `npm run release` grün
3. [ ] Release Notes in `listing/*.md` aktualisieren
4. [ ] In **Internal testing** hochladen, smoke-testen
5. [ ] In **Closed/Production** hochladen
6. [ ] Vitality/Reviews beobachten (`[[TODAY]]` als Erinnerung setzen)

## Bekannte offene Punkte

1. **Screenshots** — headless nicht renderbar. Auf einem Gerät aufnehmen und
   mit `--import` normalisieren. Siehe `docs/LISTING.md`.
2. **Meldefunktion für Vorschläge** — Play verlangt einen Meldeweg in der App.
   Vorschlag: im closed test ausliefern, aber nicht aktiv, und vor dem
   öffentlichen Launch ergänzen. Siehe `legal/moderation.md`.
3. **Zustimmungstext im Vorschlagsdialog** — muss auf die Nutzungsbedingungen
   verweisen, bevor ein Vorschlag gesendet wird.
4. **32-Bit-Geräte** — arm64-only schließt alte Android-7/8-Handys aus.
5. **Godot 4.7** — ein Upgrade von 4.5.1 bringt natives API 36 und aktuelle
   Engine-Fixes, bringt aber Breaking Changes. Eigenes Vorhaben.
6. **Rechtstexte prüfen lassen** — besonders Impressum und Datenschutz, wenn
   in DE/AT/CH veröffentlicht wird.
