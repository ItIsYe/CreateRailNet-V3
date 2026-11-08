# Selbstaktualisierung der Nodes

Jede Node, die ueber den Installer eingerichtet wurde, prueft selbst, ob ihr Kanal (`main` oder `beta`) einen neueren Stand hat, und installiert ihn in ruhigen Zeiten. Ein neuer Stand, der nicht anlaeuft, wird von selbst zurueckgenommen. Die Dateien in `/crn_data` werden dabei vom Integrator an das neue Programm angepasst (`docs/DATENFORMAT.md`).

## Betriebsarten

Auf der Seite *Update* (Knopf *Modus*) oder mit `crn/app/main update auto | melden | aus`:

| Betriebsart | Verhalten |
|---|---|
| **automatisch** (Standard) | pruefen und, wenn nichts dagegen spricht, installieren |
| nur melden | pruefen und einmal je Stand eine Meldung zeigen (Seite *Meldungen*); installiert wird von Hand |
| aus | keine Abrufe |

Feste Versionen (Tag wie `v0.1.0`, Commit) werden nicht verfolgt: wer so installiert hat, bleibt dort, bis er von Hand mit `installer` etwas anderes waehlt. Der Kanal ist der, von dem installiert wurde (`/crn/install.lua`).

## Ablauf

1. **Pruefen:** die erste Pruefung 1 bis 10 Minuten nach dem Start (je Node verschieden, damit nicht alle zugleich laden), danach alle 30 Minuten. Es wird nur das kleine Verzeichnis `dist/manifest.lua` abgerufen und der Stand verglichen.
2. **Warten, bis es passt:** installiert wird fruehestens 5 Minuten nach dem Start und nur, wenn die Rollen nichts dagegen haben. Die Leitstelle wartet, solange Fahrten laufen (Fahrplan uebergeben, Abfahrt freigegeben, unterwegs, am Ziel); ein Bahnhof, solange eine Abfahrt freigegeben ist. Ohne Sperre regelt Create die Signale waehrend der Neustartzeit allein. Der Grund steht auf der Seite *Update*.
3. **Installieren:** der Installer wird frisch vom Kanal geladen (`installer.lua`), laedt und prueft jede Datei (Groesse, Pruefsumme) und tauscht atomar aus: bei jedem Abbruch bleibt die alte oder die neue Version vollstaendig. Die bisherige Version bleibt als Vorversion (`/crn_prev`). Danach startet der Computer neu.
4. **Probezeit:** der neue Stand laeuft zwei Minuten, bevor er als bestaetigt gilt (Meldung *Update auf Version ... bestaetigt*). Wurde beim ersten Start eine Datenanpassung noetig, merkt sich die Probe die Sicherung.
5. **Rueckfall:** beendet sich das Programm in der Probezeit zweimal (Absturz, Programmfehler), oder passen die Daten nicht zum neuen Programm (*Datenanpassung gescheitert*), nimmt die Startdatei den Stand zurueck: Vorversion, die gesicherten Daten, und der Stand wird vermerkt (`/crn_data/update_bad`), damit er nicht noch einmal versucht wird. Erst ein neuerer Stand wird wieder installiert.

## Die Startdatei

`/startup.lua` (Fassung 2, vom Installer geschrieben und bei jeder Installation erneuert, wenn sie CRN gehoert) tut zwei Dinge, bevor sie CRN startet: sie fuehrt einen unterbrochenen Austausch der Installation zu Ende, und sie zaehlt Fehlstarts, solange `/crn_data/probe` besteht. Eine fremde `startup.lua` bleibt unveraendert (dann gibt es keinen Rueckfall; `crn/app/main` von Hand starten).

## Befehle

```
crn/app/main update                 Zustand
crn/app/main update pruefen         jetzt pruefen
crn/app/main update jetzt           jetzt installieren (ohne zu warten)
crn/app/main update auto|melden|aus Betriebsart
crn/app/main update ersetzen ein|aus
```

## Leitstelle

Die Leitstelle belegt rund 460 KB; zwei Staende zusammen rund 920 KB. Das passt zugleich auf den Computer (1 000 000 Byte) nur, solange die Daten unter /crn_data (Netzverzeichnis, Sicherungen der Nodes, Sicherung vor einer Datenanpassung) nicht mehr als rund 80 KB belegen; wird es eng, passen alte und neue Version nicht zugleich. Die Selbstaktualisierung meldet das dann (*Alt und neu passen nicht zugleich ...*) und installiert nicht von selbst. Mit `crn/app/main update ersetzen ein` darf sie die bisherige Version ersetzen: das geht nur ohne Rueckweg (keine Vorversion, keine Probe mit Rueckfall; bricht der Download ab, ist CRN nicht installiert und `installer zentrale` ist von Hand zu wiederholen). Empfehlung: die Leitstelle von Hand aktualisieren (`installer zentrale --replace`), wenn die anderen Nodes den neuen Stand ohne Fehler zeigen.

## Grenzen

- Die Nodes aktualisieren sich unabhaengig voneinander; waehrend einiger Minuten laufen alte und neue Staende nebeneinander. Aendert ein Stand das Funkprotokoll, ist das ein Grund, die Betriebsart vorher auf *aus* oder *nur melden* zu stellen.
- Waehrend der Probezeit zaehlt auch ein von Hand beendetes Programm (Strg+T) als Fehlstart.
- Der Rueckfall spielt die Daten auf den Stand vor der Anpassung zurueck; Aenderungen der ersten Minuten nach dem Update gehen dabei verloren.
- Nicht im Spiel geprueft: alles hier ist im Simulator getestet (`tests/test_update.lua`, mit Abbruch an jeder Dateiaenderung); die Spielabnahme steht in `docs/GROSSER_TEST.md` (3.81 bis 3.86).
