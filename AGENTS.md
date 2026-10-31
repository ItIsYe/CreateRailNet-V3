# AGENTS

Neustart nach Konzept 1.1. Vorgehen: `docs/STUFENPLAN.md`; Entscheidungen: `docs/KONZEPT_ERGAENZUNG_1_1.md`; Messwerte vom echten Modpack: `docs/MESSWERTE.md`.

## Branches

Es gibt genau zwei: `main` (stabil) und `beta` (Test- und Arbeitsbranch). Gearbeitet wird nur auf `beta`; nach bestandenem Spieltest und ausdruecklicher Freigabe geht `beta` per Pull-Request nach `main`. Weitere Branches werden nicht angelegt. `installer_beta.lua` (Kanal beta) wird von `tools/build.lua` aus `installer.lua` erzeugt und nie von Hand geaendert; der Befehl fuer `beta` laedt `installer_beta.lua`, der fuer `main` `installer.lua`.

## Regeln

- Lua 5.1 (Sprache von CC:Tweaked). Keine Globals, keine Funktionen, die es in 5.1 nicht gibt (`tools/check.lua` meldet sie).
- Jede Datei beginnt mit einem Kommentar mit `Purpose:`. Deutsche Texte fuer Benutzer ohne Umlaute (ae, oe, ue, ss).
- Nach jeder Aenderung an `src/` oder `build/`: `lua tools/build.lua`. CI prueft, dass `dist/` aktuell ist.
- Festes Limit: ein Computer fasst 1 000 000 Byte, jede Datei zaehlt mindestens 500. Das Budget je Rolle steht in `build/budget.lua` und wird im Build geprueft; nie anheben, um etwas passend zu machen.
- Zeitueberwachung in Spielzeit (`os.clock`), nie in Echtzeit (Ergaenzung E1).
- Vom Spiel abhaengiges Verhalten kommt aus `docs/MESSWERTE.md`. Fakes in `tests/fakes/` bilden nur nach, was das Spiel auch tut (feste Kapazitaet, `move` scheitert bei vorhandenem Ziel).
- Tests zuerst, und pruefen, dass sie aus dem richtigen Grund scheitern. Dateiaenderungen mit Absturz an jeder Stelle testen (siehe `tests/test_installer.lua`).
- Mutationspruefungen nur in einer Wegwerfkopie, danach die ganze Suite im echten Verzeichnis, bevor etwas committet wird.
- Vor dem Push: `tools/check.lua`, `tools/run_tests.lua` mit lua5.4, lua5.1 und luajit.
- Eine Stufe ist erst fertig, wenn ihr Spieltest bestanden und von der Betreiberin oder dem Betreiber eingetragen ist.
