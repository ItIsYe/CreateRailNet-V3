# Stufenplan

Grundlage: Konzept 1.1 (Kapitel 17.2 und 17.3), `docs/MESSWERTE.md`, `docs/KONZEPT_ERGAENZUNG_1_1.md`. Es ist noch kein Code geschrieben. Dieser Plan legt nur die Reihenfolge und die Abschlusskriterien fest.

## Regeln fuer jede Stufe

Eine Stufe ist erst fertig, wenn alle fuenf Punkte erfuellt sind. Die naechste Stufe beginnt vorher nicht.

1. **Tests ausserhalb des Spiels** laufen unter Lua 5.1, 5.4 und LuaJIT gruen. Fakes fuer Create-Geraete werden aus den gemessenen Formaten gebaut (M04, M10, M13), nicht aus Annahmen.
2. **Groessenpruefung:** Der Test bricht ab, wenn eine Rolle ihr Budget ueberschreitet (Programm hoechstens 500 000 Byte, Daten und Journal hoechstens 300 000, mindestens 200 000 frei; jede Datei zaehlt mindestens 500 Byte).
3. **Spieltest in der Welt** nach einer Checkliste, die im Plan der Stufe steht. Das Ergebnis traegst du ein, nicht ich. Nur ein bestandener Spieltest schliesst die Stufe.
4. **Mutationspruefung** nur in einer Wegwerfkopie des Repositories, danach die komplette Suite, bevor etwas committet wird.
5. **Dokumentation und PR:** Abnahmekennungen (A01 bis A18) und Messwerte (M..) werden in der Abnahmetabelle nachgetragen. Gemergt wird erst nach deinem ausdruecklichen Ja.

## Stufen

| Stufe | Inhalt | Konzept | Spieltest | Abnahme |
|---|---|---|---|---|
| 0 Rahmen | Repository-Geruest, Build mit Rollenmodulen, Budgettest, Testlaeufer, CI. Installer per Download (feste Version, Pruefsummenliste, sichtbare Paketversion, Rueckkehr zur Vorversion) | 29, E5, E6 | Leerer Computer wird per `wget` installiert, zeigt Version und freien Platz; Wiederholung und Vorversion funktionieren | A18 (Vorbereitung) |
| 1 Kern | Betriebsuhr in Spielzeit mit gespeichertem Stand (E1), atomares Schreiben mit zwei Generationen und begrenztes Journal (E9), Konfiguration, Node-Kennung, Nachrichtenumschlag ueber `rednet` mit Duplikaterkennung und Epoche (13.2, E8) | 12.1, 13, 14.2 | Zwei Computer tauschen eine Nachricht ueber Funk; Neustart setzt die Uhr fort; doppelte Nachricht erzeugt kein zweites Ergebnis | A15 (Vorbereitung) |
| 2 Geraete | Erkennung mit Typ und Methoden, geschuetzte Aufrufe (Fehler ungleich leer), Ereignisse und Anschlussname zu Gleis, Signal ueber `isForcedRed` (E2), Redstone-Ausgang, Monitor | 18, 19, 20, 24 | Der Bericht der App stimmt mit `crn_probe` ueberein; Signal wird gesperrt und freigegeben | A01, A02, A03, A09 |
| 3 Oberflaeche und Assistent | Zeichenraster 100x40 und 51x19, 16-Farben-Palette, Touch-Rechtecke, sechs Schritte, lesende Erkennung getrennt von schaltenden Pruefungen | 15, 28, 29 | Einrichtung eines Bahnhof-Nodes am echten Monitor; `getSize` stimmt; zu kleiner Monitor zeigt die Statusansicht | UI-Punkte aus 29.3 |
| 4 Erster Bahnhof | Zugregister, Anmeldung (lehnt "Unnamed Train" und doppelte Namen ab), Warteauftrag, Fahrtauftrag mit Lebenszyklus, Freigabeausgang als letzte Bedingung, Bedarfstaste | 7, 8, 9 | Ein Zug, ein Bahnhof, eine Bedarfsfahrt (Weizen) bis zur Rueckkehr; zwei Tastendruecke ergeben genau einen Auftrag | A04, A05, A06, A07, A08 |
| 5 Zweiter Bahnhof und Linien | Zielbahnhof, Rueckfahrt, mehrere Gleise je Bahnhof, Gleiszuweisung, Anzeigen, Linien und Takt, Prioritaeten | 10, 12, 22 | Linienbetrieb zwischen zwei Bahnhoefen mit drei Gleisen; Tafel zeigt Plan und Ist getrennt | A12 |
| 6 Signal und Knoten | Signal- und Strecken-Node mit beliebig vielen Gleisen, Konfliktbereiche, T-Kreuzung, mehrere konkurrierende Zuege | 4.5, 4.6, 11, 14.3 | T-Kreuzung mit langen Zuegen; Bereich wird erst nach Raeumungsnachweis frei | A09, A10, A11 |
| 7 Depot und manuelle Zuege | Aufnehmen, Abstellen, Aktivieren, Uebergabe, Ausschleusen, unbekannte Zuege | 4.4, 7.2 bis 7.5, 10.2 | Zug aufnehmen und abstellen; manueller Zug angemeldet; fremder Zug wird nie falsch zugeordnet | A13, A14 |
| 8 Stoerung und Wartung | Stoerungsmodell, Wiederanlauf, Ersatzcomputer, gefuehrtes Update mit Rueckkehr | 14, 29.2 | Zentrale waehrend eines Auftrags neu starten; Computer ersetzen; Update auf eine Zweitversion | A15, A17, A18 |
| 9 Betrieb im Grossen | Last mit 300 und mehr Signalen, Chunkgrenzen, Gesamtabnahme | 16, 17.3 | Alle Abnahmen noch einmal auf der Gesamtanlage | A01 bis A18, A16 |

## Abhaengigkeiten von offenen Punkten

| Offener Punkt | blockiert |
|---|---|
| Handtest Ausfallwirkung am Signal (E10) | Stufe 6, in Stufe 2 nur als Hinweis im Bericht |
| Monitor-Bericht vom Master | Stufe 3 |
| Redstone Relay herstellbar? | Stufe 4 (Anzahl der Freigabeausgaenge je Bahnhof) |
| Stationsnamen, Zuglaengen, Gleisplan | Stufe 4 (Beispieldaten), Stufe 5 und 6 (echte Anlage) |
| Chunkloading des Servers | Stufe 9 |

## Was ich aus dem Altprojekt uebernehme

- Minifier und Rollenbuild nur, wenn das Budget es verlangt; die Groessenpruefung kommt in Stufe 0, nicht erst am Ende.
- Setup-Werkzeuge liegen nicht auf jedem Computer, sondern werden bei Bedarf geholt.
- Geraeteerkennung unterscheidet Funk und Kabel und rate nie (Messung: `left` Funk, `right` Kabel).
- Mehrere Geraete je Computer sind der Normalfall.
- Mutationslaeufe nie im Arbeitsbaum.

Alter Code wird nur uebernommen, wenn er im Spiel bewiesen ist und ins Budget passt; ansonsten wird er neu und kleiner geschrieben.
