# Asset-Maße und Vorgaben (Kurzreferenz)

Alle Werte stammen aus der Play-Hilfe „Add preview assets to showcase your app"
(Stand September 2026). `npm run preflight` prüft die erzeugten Dateien gegen
diese Tabelle.

| Asset | Maße | Format | Max. Dateigröße | Pflicht |
|---|---|---|---|---|
| App-Icon | 512×512 | 32-Bit PNG mit Alpha | 1 MB | ja |
| Feature Graphic | 1024×500 | JPEG oder 24-Bit PNG, **kein** Alpha | 15 MB | ja |
| Screenshot (Telefon, quer) | 1920×1080 empfohlen (16:9) | JPEG oder 24-Bit PNG | — | min. 2 |
| Screenshot (Telefon, hoch) | 1080×1920 empfohlen (9:16) | JPEG oder 24-Bit PNG | — | optional |
| Tablet / Chromebook | 4 Stück, 1080–7680 px, 16:9 oder 9:16 | PNG/JPEG | — | empfohlen |
| Android-TV-Banner | 1280×720 | PNG/JPEG | — | nur bei TV |
| Preview-Video | YouTube-URL | öffentlich/gelistet, ohne Werbung | — | optional |

Regeln, an denen Apps abgelehnt oder in den Empfehlungen nicht gezeigt werden:

* Screenshots müssen das **echte Spiel** zeigen — keine Mock-ups, keine
  Hände/Finger vor dem Gerät, keine Geräterahmen, keine Kopfzeile mit Uhrzeit,
  Signalbalken oder Akku unvollständig.
* Keine Text-Overlays mit Leistungsversprechen, Aufrufen oder Preisen.
* Text im Bild höchstens ~20 % der Fläche, in gut lesbarer Größe.
* Keine fremden Marken oder Logos ohne Erlaubnis.
* Keine Play-Badges im eigenen Bild.
* Icon: keine Badges, kein Text, der auf Rang oder Preis hindeutet.
* Für Spiele zeigt Google bevorzugt **drei 16:9-Screenshots** in den
  Empfehlungsleisten.

## Erzeugte Dateien

`npm run assets` schreibt nach `assets/generated/`:

| Datei | Maße | Kanal |
|---|---|---|
| `icon-512.png` | 512×512 | RGBA (Store-Icon, randlos gefüllt) |
| `feature-graphic-1024x500.png` | 1024×500 | RGB (24-Bit, kein Alpha) |
| `icon-192.png` | 192×192 | RGBA (Launcher) |
| `adaptive-background-432.png` | 432×432 | RGBA (adaptive Hintergrundebene) |
| `adaptive-foreground-432.png` | 432×432 | RGBA (adaptive Vordergrundebene, 66-%-Sicherheitszone) |
| `adaptive-monochrome-432.png` | 432×432 | RGBA (monochrome Ebene für Themed Icons) |

## Optional im Export-Preset

Damit die App auch auf dem Gerät ein echtes adaptives Icon bekommt, können die
Dateien im Preset verdrahtet werden (`launcher_icons/…`). Der Generator
schreibt sie bereit; `scripts/install-export-preset.mjs` setzt die Felder,
sobald `assets/generated/` befüllt ist.
