# OBS Controller Overlay

Ein OBS-Skript, das deinen Controller als Overlay zeigt. Gedrückte Tasten leuchten in Echtzeit auf. Trigger füllen sich stufenlos, und die Sticks bewegen sich mit.

- **Controller:** Xbox (XInput), PS5 DualSense (USB und Bluetooth, inklusive Touchpad) und Nintendo Switch 2 Pro Controller (USB).
- **Spiel im Vordergrund:** Das Overlay funktioniert auch dann. Das Skript liest den Controller selbst aus und schickt die Daten an die Browser-Quelle.
- **Eine Datei:** Es reicht `xbox-controller-overlay.lua`. Es gibt keine Abhängigkeiten und keine OBS-Startparameter.
- **Eigene OBS-Quelle:** Das Skript bringt die Quellenart **Controller Overlay** mit. Du brauchst keine Browser-Quelle und keine URL.
- **Einstellungen pro Quelle:** Controller, Layout, Farbvariante (dunkel/hell), Leuchtfarbe, Originalfarben für A/B/X/Y bzw. PS-Symbole, Deckkraft und Hinweistext. Alle Änderungen wirken sofort.

## Schnellstart

1. Öffne in OBS **Werkzeuge → Skripte**, klicke auf **+** und wähle `xbox-controller-overlay.lua`.
2. Klicke in der Szene bei **Quellen** auf **+** und wähle **Controller Overlay**.
3. Stell das Aussehen in den Eigenschaften der Quelle ein (Doppelklick auf die Quelle).

Die ausführliche, bebilderte Anleitung steht in [Controller-Overlay-Anleitung.pdf](Controller-Overlay-Anleitung.pdf).

### Als Browser-Quelle

Das Overlay lässt sich weiterhin als Browser-Quelle einbinden, mit der URL `http://localhost:8790` und einer Größe von 1600 × 1120. Dann gelten die Standardeinstellungen. Ändern kannst du sie nur über URL-Parameter:

```
layout=auto|xbox|ps|ns  theme=carbon|white  accent=HEX  hint=0  bg=HEX  pad=N  dz=0.12  opacity=10..100  face=orig
```

## Bekannte Einschränkungen

- Die Share-Taste des Xbox-Controllers lässt sich über XInput nicht auslesen.
- Den Switch 2 Pro Controller erkennt das Skript nur über USB. Joy-Con 2 und Bluetooth werden nicht unterstützt.
- Steam kann die USB-Schnittstelle des Switch 2 Pro Controllers belegen. Beende Steam in dem Fall.
- Das Skript läuft nur unter Windows.
