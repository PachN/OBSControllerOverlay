# OBS Controller Overlay

Ein OBS-Skript, das deinen Controller als Overlay zeigt. Gedrückte Tasten leuchten in Echtzeit auf. Trigger füllen sich stufenlos, und die Sticks bewegen sich mit.

- **Controller:** Xbox (XInput), PS5 DualSense (USB und Bluetooth, inklusive Touchpad) und Nintendo Switch 2 Pro Controller (USB).
- **Spiel im Vordergrund:** Das Overlay funktioniert auch dann. Das Skript liest den Controller selbst aus und schickt die Daten an die Browser-Quelle.
- **Eine Datei:** Es reicht `xbox-controller-overlay.lua`. Es gibt keine Abhängigkeiten und keine OBS-Startparameter.
- **Einstellungen im Skriptfenster:** Controller, Layout, Farbvariante (dunkel/hell), Leuchtfarbe, Deckkraft und Hinweistext. Alle Änderungen wirken sofort.

## Schnellstart

1. Öffne in OBS **Werkzeuge → Skripte**, klicke auf **+** und wähle `xbox-controller-overlay.lua`.
2. Füge eine neue **Browser**-Quelle hinzu. Setze **keinen** Haken bei „Lokale Datei“.
   - URL: `http://localhost:8790`
   - Größe: 1600 × 1120
3. Stell das Aussehen im Skriptfenster ein.

Die ausführliche, bebilderte Anleitung steht in [Controller-Overlay-Anleitung.pdf](Controller-Overlay-Anleitung.pdf).

### Optionale URL-Parameter

URL-Parameter haben Vorrang vor den Skript-Einstellungen:

```
layout=auto|xbox|ps|ns  theme=carbon|white  accent=HEX  hint=0  bg=HEX  pad=N  dz=0.12  opacity=10..100
```

## Anleitung neu erzeugen

Die PDF wird aus `guide/template.html` gebaut. Die Vorschaubilder des Controllers stammen direkt aus dem SVG im Lua-Skript. Zum Bauen brauchst du Node.js und Microsoft Edge.

```powershell
.\guide\build-pdf.ps1
```

## Bekannte Einschränkungen

- Die Share-Taste des Xbox-Controllers lässt sich über XInput nicht auslesen.
- Den Switch 2 Pro Controller erkennt das Skript nur über USB. Joy-Con 2 und Bluetooth werden nicht unterstützt.
- Steam kann die USB-Schnittstelle des Switch 2 Pro Controllers belegen. Beende Steam in dem Fall.
- Das Skript läuft nur unter Windows.
