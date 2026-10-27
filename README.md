# CRN - Create Rail Net

Betriebssystem fuer ein Bahnnetz mit Create und CC:Tweaked (ATM10). Grundlage ist das Konzept 1.1; die Umsetzung laeuft nach `docs/STUFENPLAN.md`. Der Stand hier ist **Stufe 0**: Rahmen und Installer, noch kein Fahrbetrieb.

## Installieren (Stufe 0)

Auf dem Computer (HTTP muss erlaubt sein), Rolle und feste Version angeben:

```
wget https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/<VERSION>/installer.lua installer.lua
installer zentrale <VERSION>
crn/app/main
```

`<VERSION>` ist ein Tag, ein Commit oder ein Zweig. Ein beweglicher Zweig wie `main` wird beanstandet, weil sich der Inhalt zwischen zwei Aufrufen aendern kann. Rollen: `zentrale`, `passagierbahnhof`, `gueterbahnhof`, `depot`, `signal`, `knoten`, `anmeldung`.

Weitere Aufrufe: `installer --status`, `installer --check`, `installer --rollback` (zur Vorversion), `installer --drop-prev ROLLE` (Vorversion loeschen, wenn der Platz knapp ist).

## Entwickeln

```
lua5.4 tools/build.lua          # dist/ neu bauen (nach jeder Aenderung an src/ oder build/)
lua5.4 tools/budget.lua         # Groessenbudget je Rolle
lua5.4 tools/check.lua          # Syntax, Kopfzeilen, Lua-5.1-Pruefung (auch mit lua5.1 ausfuehren)
lua5.4 tools/run_tests.lua      # Tests (auch mit lua5.1 und luajit)
```

Aufbau: `src/` Quelltext, `build/` Rollen/Module und Budget, `dist/` gebaute Auslieferung (CI prueft, dass sie zu `src/` passt), `installer.lua` laedt `dist/` einer Version, `probe/` Messprogramme fuer das echte Modpack, `docs/` Konzeptergaenzungen, Messwerte und Stufenplan.

Arbeitsregeln: `AGENTS.md`.
