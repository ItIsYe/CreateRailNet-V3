# Erstaufbau eines Systems

Kurzanleitung fuer ein neues Netz, von den Computern bis zum ersten aktiven Bahnhof. Die Einzelheiten stehen in `docs/SETUP_UI.md` (Bedienung), `docs/NETZVERZEICHNIS.md` (Verzeichnis, Funk, Verhalten bei Ausfall) und `docs/GROSSER_TEST.md` (Abnahme im Spiel).

## Voraussetzungen

- **HTTP** ist auf dem Server fuer Computer erlaubt (sonst kann der Installer nichts laden).
- **Ein Computer je Aufgabe** (Advanced Computer): eine Leitstelle, je eine Node fuer Bahnhoefe und Depot. Eine Node darf mehrere Rollen tragen. Strecke, Signale und Weichen regelt Create allein; dafuer braucht es keinen Computer.
- **Funk:** an jedem Computer ein Funkmodem (Ender-Modem reicht ueber jede Entfernung, sonst gilt die Reichweite des Funkmodems). Create-Geraete (Train Station, Beobachter) haengen direkt am Computer oder an einem Kabelmodem.
- **Monitor** ist freiwillig (Advanced Monitor). Das grosse Layout (ab 100x40 Zeichen) braucht bei Textgroesse 0,5 mindestens 5x4 Bloecke (umschalten mit der Taste "Textgroesse" auf der Seite Geraete, oder von Hand mit `monitor.setTextScale(0.5)`), bei der Vorgabe 1,0 mindestens 10x6; ab 6x3 Bloecken (Textgroesse 1,0) gibt es die kompakte Ansicht. Alles geht auch am Terminal des Computers (51x19); Texteingaben gehen nur dort (Rechnung in `docs/MESSWERTE.md`, Q01 bis Q04).
- **Chunks laden:** ein Computer in einem nicht geladenen Chunk laeuft nicht. Leitstelle und Bahnhoefe gehoeren in dauerhaft geladene Chunks (Chunk-Lader), siehe "Nicht geladene Chunks" in `docs/NETZVERZEICHNIS.md`.
- **Platz:** ein Computer fasst 1 MB. Die Leitstelle belegt rund 470 KB, die Nodes 280 bis 300 KB.

## Reihenfolge

1. **Leitstelle installieren.** Auf dem Computer der Leitstelle (Befehl fuer den Kanal `main` oder `beta` siehe `README.md`): `wget ... installer.lua`, `installer`, Rolle `zentrale`. Dann `crn/app/main` oder Neustart.
2. **Leitstelle einrichten.** Seite *Einrichtung*, *Einrichtung starten*, *Erste Leitstelle dieses Netzes erstellen*, Netzname, dann ist die Rolle Leitstelle schon gewaehlt; Namen vergeben, weiter bis *Aktivieren*. Danach nennt die Seite *Uebersicht* den naechsten Schritt.
3. **Strecke bauen.** Gleise, Signale, Weichen und Kreuzungen baut und regelt man in Create; die Leitstelle muss davon nichts wissen. Nur fuer eine Anmeldung legt man in der Leitstelle auf der Seite *Betriebsstellen* eine Betriebsstelle an (*Neu*: Name, Art, Standort).
4. **Nodes installieren und einrichten.** Auf jedem weiteren Computer `installer` mit der passenden Rolle (`passagierbahnhof`, `gueterbahnhof`, `depot`, `anmeldung`), dann *Einrichtung starten*, *Diesem bestehenden Netz beitreten*, das Netz waehlen, Rolle, *Kennung anfordern*, Geraete waehlen, Gleise anlegen und ihnen Train Station und Beobachter zuordnen, aktivieren. Die Leitstelle vergibt die Kennung (`N0001`, ...).
5. **Kontrollieren.** In der Leitstelle zeigt die Seite *Netz* jede Node mit Zustand, die Seite *Stoerungen* Auffaelligkeiten und die Seite *Meldungen* die Ereignisse.

## Aktualisieren

Nodes aktualisieren sich selbst (Seite *Update*, `docs/AKTUALISIERUNG.md`): pruefen alle 30 Minuten, installieren in ruhigen Zeiten, nehmen einen Stand zurueck, der nicht anlaeuft. Von Hand:

`installer` (Dialog) oder `installer ROLLE`. Die Vorversion bleibt erhalten (`installer --rollback`). Reicht der Platz nicht fuer alte und neue Version zugleich (die Leitstelle mit dem 32-KB-Installer und ihren Daten ist so ein Fall), steht im Dialog die Wahl *Bisherige Version ersetzen*; ohne Dialog `installer zentrale --replace`. Dabei wird die bisherige Version zuerst entfernt (kein Zurueck zur Vorversion, `/crn_data` bleibt); bricht der Download ab, den Aufruf wiederholen.

## Wenn etwas nicht klappt

| Meldung oder Beobachtung | Ursache und Abhilfe |
|---|---|
| `HTTP ist auf diesem Computer nicht verfuegbar` | HTTP fuer Computer in der Servereinstellung erlauben. |
| `Zu wenig Platz` | Hinweise der Meldung befolgen: `--drop-prev` (Vorversion loeschen) oder `--replace`; sonst unnoetige Dateien loeschen (`ls`, `delete`). |
| `Kein Netz gefunden: Leitstelle an, Chunk geladen?` | Leitstelle laeuft nicht oder ihr Chunk ist nicht geladen, oder kein Ender-Modem in Reichweite; *Neu suchen* oder *Netz von Hand eingeben*. |
| `Die Leitstelle antwortet nicht ...` | Wie oben; *Von Hand* geht trotzdem. |
| Funk: `KEIN FUNKMODEM` auf der Seite *Uebersicht* | Funkmodem anschliessen; ein spaeter angeschlossenes Modem wird erkannt. |
| Eine Node meldet sich nicht mehr | Chunk geladen? Computer an? Siehe "Nicht geladene Chunks". |
| Zwei Computer haben dieselbe Kennung | Einen neu einrichten (beide `N0001`: Leitstelle und Node auf den gleichen Stand bringen). |
