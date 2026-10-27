# CRN - Create Rail Net

Betriebssystem fuer ein Bahnnetz mit Create und CC:Tweaked (ATM10). Grundlage ist das Konzept 1.1; die Umsetzung laeuft nach `docs/STUFENPLAN.md`. Gebaut wird stufenweise; der grosse Spieltest am Ende steht in `docs/GROSSER_TEST.md`. Stand: Stufe 0 (Installer), 1 (Kern: Uhr, sicheres Speichern, Journal, Nachrichten, Funk), 2 (Geraete), 3 (Oberflaeche und Einrichtungsassistent) 4 (erster Bahnhof: Zugregister, Anmeldung, Fahrtauftrag mit Lebenszyklus, Freigabeausgang, Bedarfstaste), 5 (mehrere Gleise, Linien im Takt, Tafel), 6 (Signal- und Knoten-Node) 7 (Depot, manuelle Zuege, Ausschleusen und Aufnehmen), 8 (Stoerungen, Wiederanlauf, Ersatzcomputer, Update-Pruefung) und 9 (Lasttest, Abnahmematrix `docs/ABNAHME.md`). Alle Stufen sind offline getestet; der grosse Spieltest steht in `docs/GROSSER_TEST.md`.

## Installieren (Stufe 0)

Auf dem Computer (HTTP muss erlaubt sein):

```
wget https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/<VERSION>/installer.lua installer.lua
installer
```

`installer` ohne Zusatz startet den Dialog und fragt Schritt fuer Schritt: Menue (installieren, pruefen, zur Vorversion zurueck), Version, Rolle, Zusammenfassung. Mit `z` geht es einen Schritt zurueck, mit `q` bricht man ab; erst nach `j` in der Zusammenfassung wird etwas veraendert.

`<VERSION>` ist ein Tag, ein Commit oder ein Zweig. Ein beweglicher Zweig wie `main` wird beanstandet, weil sich der Inhalt zwischen zwei Aufrufen aendern kann. Rollen: `zentrale`, `passagierbahnhof`, `gueterbahnhof`, `depot`, `signal`, `knoten`, `anmeldung`.

Ohne Dialog (fuer Skripte): `installer ROLLE VERSION [--yes]`, dazu `installer --status`, `installer --check`, `installer --rollback` (zur Vorversion), `installer --drop-prev ROLLE` (Vorversion loeschen, wenn der Platz knapp ist), `installer --help`. Gestartet wird mit `crn/app/main`.

## Entwickeln

```
lua5.4 tools/build.lua          # dist/ neu bauen (nach jeder Aenderung an src/ oder build/)
lua5.4 tools/budget.lua         # Groessenbudget je Rolle
lua5.4 tools/check.lua          # Syntax, Kopfzeilen, Lua-5.1-Pruefung (auch mit lua5.1 ausfuehren)
lua5.4 tools/run_tests.lua      # Tests (auch mit lua5.1 und luajit)
```

Aufbau: `src/` Quelltext, `build/` Rollen/Module und Budget, `dist/` gebaute Auslieferung (CI prueft, dass sie zu `src/` passt), `installer.lua` laedt `dist/` einer Version, `probe/` Messprogramme fuer das echte Modpack, `docs/` Konzeptergaenzungen, Messwerte und Stufenplan.

Arbeitsregeln: `AGENTS.md`.
