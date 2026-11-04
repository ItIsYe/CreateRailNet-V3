# CRN - Create Rail Net

Betriebssystem fuer ein Bahnnetz mit Create und CC:Tweaked (ATM10). Grundlage ist das Konzept 1.1; die Umsetzung laeuft nach `docs/STUFENPLAN.md`. Stand: Stufen 0 bis 9 sind gebaut und offline getestet (Installer, Kern, Geraete, Oberflaeche und Einrichtungsassistent, Bahnhof mit Zugregister und Fahrtauftraegen, Linien und Tafel, Signal- und Knoten-Node, Depot, Stoerungen und Ersatzcomputer, Lasttest), dazu das Netzverzeichnis mit gefuehrter Einrichtung aller Rollen (`docs/NETZVERZEICHNIS.md`). Der Spieltest steht in `docs/GROSSER_TEST.md`, die Abnahmematrix in `docs/ABNAHME.md`.

**Neues Netz aufbauen:** `docs/ERSTAUFBAU.md` (Voraussetzungen, Reihenfolge, haeufige Meldungen). Bedienung der Einrichtung: `docs/SETUP_UI.md`.

## Installieren

Auf dem Computer (HTTP muss erlaubt sein):

Welche Version installiert wird, bestimmt der Befehl, nicht der Dialog:

Test (Branch `beta`):

```
wget https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/beta/installer_beta.lua installer.lua
installer
```

Stabil (Branch `main`):

```
wget https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/main/installer.lua installer.lua
installer
```

Der Installer kennt seinen Kanal (`main` oder `beta`) aus der Datei, die man geladen hat, und holt alles nur von dort; `installer_beta.lua` wird von `tools/build.lua` aus `installer.lua` erzeugt (nur eine Zeile ist anders). Gibt es `installer.lua` schon (`File already exists`), vorher `delete installer.lua`.

`installer` ohne Zusatz startet den Dialog und fragt Schritt fuer Schritt: Menue (installieren, pruefen, zur Vorversion zurueck), Rolle, Zusammenfassung. Eine Versionsfrage gibt es nicht. Die Eingabetaste uebernimmt die markierte Vorgabe (bisherige Rolle). Mit `z` geht es einen Schritt zurueck, mit `q` bricht man ab; erst nach `j` in der Zusammenfassung wird etwas veraendert.

Ohne Dialog (Skripte) geht zusaetzlich ein Tag, ein Commit oder ein anderer Branch als Version; ein fremder beweglicher Branch wird beanstandet, weil sich der Inhalt zwischen zwei Aufrufen aendern kann. Der eigene Kanal wird nicht beanstandet. Rollen: `zentrale`, `passagierbahnhof`, `gueterbahnhof`, `depot`, `signal`, `knoten`, `anmeldung`.

Ohne Dialog (fuer Skripte): `installer ROLLE [VERSION] [--yes]` (ohne VERSION gilt der Kanal), dazu `installer --status`, `installer --check`, `installer --rollback` (zur Vorversion), `installer --drop-prev ROLLE` (Vorversion loeschen, wenn der Platz knapp ist), `installer ROLLE --replace` (bisherige Version zuerst entfernen, wenn alt und neu nicht zugleich auf den Computer passen; so ist es bei der Leitstelle, `/crn_data` bleibt), `installer --help`. Gestartet wird mit `crn/app/main`; `startup.lua` startet CRN beim Einschalten.

## Entwickeln

```
lua5.4 tools/build.lua          # dist/ neu bauen (nach jeder Aenderung an src/ oder build/)
lua5.4 tools/budget.lua         # Groessenbudget je Rolle
lua5.4 tools/check.lua          # Syntax, Kopfzeilen, Lua-5.1-Pruefung (auch mit lua5.1 ausfuehren)
lua5.4 tools/run_tests.lua      # Tests (auch mit lua5.1 und luajit)
```

Aufbau: `src/` Quelltext, `build/` Rollen/Module und Budget, `dist/` gebaute Auslieferung (CI prueft, dass sie zu `src/` passt), `installer.lua` laedt `dist/` einer Version, `probe/` Messprogramme fuer das echte Modpack, `docs/` Konzeptergaenzungen, Messwerte und Stufenplan.

Arbeitsregeln: `AGENTS.md`.

## Aktualisieren

Nodes pruefen selbst alle 30 Minuten, ob ihr Kanal einen neueren Stand hat, installieren ihn in ruhigen Zeiten und nehmen einen Stand zurueck, der nicht anlaeuft; gespeicherte Dateien alter Staende werden an das neue Programm angepasst. Siehe `docs/AKTUALISIERUNG.md` und `docs/DATENFORMAT.md`.
