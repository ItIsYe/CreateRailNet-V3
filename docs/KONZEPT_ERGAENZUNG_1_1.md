# Ergaenzungen zum Konzept 1.1

Grundlage: das Konzept 1.1 (27. Oktober 2026) und die Messwerte M01 bis M16 in `docs/MESSWERTE.md`. Hier steht nur, was das Konzept noch nicht entscheidet oder was die Messung bestaetigt oder verschiebt. Es ist noch kein Code geschrieben. Kapitelnummern verweisen auf das Konzept.

## 1. Die Messung bestaetigt das Konzept

| Konzept | Messwert | Ergebnis |
|---|---|---|
| 21.1 getSchedule liefert keinen laufenden Zustand | M11: kein Fortschritt im Ergebnis | bestaetigt; das Ziel eines Zuges kommt nur aus Ereignissen und Bahnhofsnamen, sonst "unbekannt" |
| 7.1 Zugname nicht eindeutig | M14: zwei Zuege, einer heisst "Unnamed Train" | bestaetigt; Anmeldung muss "Unnamed Train" und doppelte Namen ablehnen oder ueber setTrainName klaeren |
| 19.4 Ereignis traegt Anschlussname | M05, M06 | bestaetigt, Reihenfolge imminent, passing, arrival, departure, passed gemessen |
| 18 Methoden vorhanden (A01) | M03 | bestaetigt, nichts fehlt |
| 20.1 setForcedRed hebt nur die zusaetzliche Sperre auf | M09 | bestaetigt, Zustand ohne Zug wird wieder GREEN |
| 8.2 setSchedule am haltenden Zug | M12 | gleicher Fahrplan: ok, unveraendert, Zug fuhr weiter (Aenderung des Inhalts noch nicht gemessen) |

## 2. Wirkliche Aenderungen und Luecken

| Nr | Thema | Befund | Vorschlag |
|---|---|---|---|
| E1 | Zeitbasis (12.1) | Spielzeit laeuft 1,83-mal langsamer als Echtzeit (vermutlich etwa 11 Ticks/s); `os.epoch("ingame")` unbrauchbar | Betriebsuhr, Haltezeiten, Timeouts und Heartbeats in Spielzeit (`os.clock`). `os.clock` beginnt bei jedem Computerstart neu: Zeitstand speichern und beim Start fortfuehren. Echtzeit nur fuer Anzeige und Protokoll |
| E2 | Soll und Ist am Signal (24.3) | Das eigene Zwangsrot loest dasselbe Ereignis aus wie ein natuerlicher Wechsel | "Sperre bestaetigt" nur ueber `isForcedRed()`, nie ueber das Ereignis |
| E3 | Rueckgaben mit zwei Werten (19.2) | `canTrainReach` liefert `false, "no-target"`; `distanceTo` liefert Distanz oder `nil, Grund` | Beide Werte immer auswerten; "kein Zug" bei getTrainName und hasSchedule ist ein Fehler (M04), kein Leerwert |
| E4 | Abfragelast (16.2) | Geraeteaufrufe kosten unter 0,125 ms, auch ueber Kabelmodem | Abfragen sind nicht der Engpass. Zu messen bleibt die Last durch Ereignisse und das Kabelnetz bei sehr vielen Geraeten |
| E5 | Installation (29) | Das Konzept nennt Diskette als Grundweg; `http` ist erreichbar (M02) und wird als Hauptweg gewuenscht | Download als Hauptweg, Diskette als Weg ohne Netz. Feste Version statt beweglichem Zweig, mit Pruefsummenliste, sichtbarer Paketversion und Rueckkehr zur Vorversion (29.2) |
| E6 | Groesse (15.1) | Eine Anwendung fuer alle Rollen muss in 1 000 000 Byte (M01) passen, jede Datei zaehlt mindestens 500 Byte | Eine Codebasis; beim Installieren waehlt die Rolle die Module. Festes Budget je Rolle: Programm hoechstens 500 000, Daten und Journal hoechstens 300 000, mindestens 200 000 frei fuer Updates (Vorschlag, im ersten Entwurf pruefen) |
| E7 | Freigabeausgang (8.4, 24.1) | Jeder gleichzeitig freizugebende Haltepunkt braucht einen eigenen Ausgang. Ob ein Redstone Relay im Pack herstellbar ist, ist nicht geprueft | Standard: Computerseiten. Relay nur, wenn im Pack herstellbar. Ein Bahnhof-Computer fuehrt hoechstens so viele Haltegleise, wie er Ausgaenge hat |
| E8 | Nachrichtenweg (13) | Funk (Ender-Modem `left`) und Kabel (`right`) nebeneinander am selben Computer (M03) | `rednet` mit eigenem Protokollnamen, darauf der Umschlag aus 13.2; Funk fuer Computer untereinander, Kabel fuer Geraete und Monitore. Serialisierung mit `textutils.serialize` (Lua-Tabellen) |
| E9 | Datenhaltung (13.4) | Absicht vor Aktion, Ergebnis danach | Datei erst unter Namen `.tmp` schreiben, pruefen, dann `fs.move`; zwei Generationen behalten; ein Journal mit fester Obergrenze |
| E10 | Ausfallwirkung am Signal (14.3, A10) | Nicht gemessen | Kurzer Handtest (siehe Abschnitt 4), bevor Sicherheitsregeln auf "Signale bleiben rot" bauen |

## 3. Angaben, die nur du liefern kannst (25.2)

- Stationsnamen und Haltegleise, Zuglaengen und zulaessige Haltebereiche.
- Gleisplan in Worten (Strecken, Richtungen, Abzweige, Kreuzungen) und die nativen Signalgruppen.
- Welche Redstone-Ausgaenge je Bahnhof tatsaechlich verdrahtet werden koennen.
- Chunkloading auf dem Server (welche Bereiche dauerhaft geladen sind).
- Ob ein Redstone Relay im Pack herstellbar ist.
- Welche Monitore (Groesse, Advanced oder normal) an welchem Computer stehen.

## 4. Naechste Messungen

1. **A10 Ausfallwirkung (von Hand, ohne Programm):** Am Computer mit dem Signal `lua` starten, `peripheral.wrap("Create_Signal_5").setForcedRed(true)` eingeben, pruefen ob das Signal rot ist, dann den Computer ausschalten (`shutdown`) und nach 10 s beobachten, ob das Signal rot bleibt. Danach das Modem abziehen und erneut beobachten, dann wieder einschalten und `setForcedRed(false)` ausfuehren.
2. **Monitore (A12, UI):** `crn_probe` am Master-Computer ausfuehren, an dem die Monitore haengen. Der Bericht nennt Groesse und Farbfaehigkeit.
3. **Funk:** vorhandener `--linktest` aus der alten Fassung, falls die Reichweite zwischen zwei Standorten wichtig ist.

## 5. Entscheidungen, die ich brauche

E1 Spielzeit, E5 Download als Hauptweg, E6 Groessenbudget, E7 Ausgaenge, E8 Nachrichtenweg und E9 Datenhaltung gelten als beschlossen, sobald sie bestaetigt sind. Mit E10 und den Angaben aus Abschnitt 3 ist die Grundlage fuer die erste Umsetzungsstufe vollstaendig.
