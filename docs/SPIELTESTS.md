# Spieltests

Hier traegst du die Ergebnisse der Tests in der Welt ein. Ein Test zaehlt nur, wenn er im Spiel gelaufen ist.

## Stufe 0: Rahmen und Installer

Vorbereitung: ein leerer Computer (Advanced Computer genuegt), HTTP erlaubt. `<ZWEIG>` ist der Zweig dieser Stufe, solange sie nicht gemergt ist (`claude/stufe-0`), danach ein Tag oder `main`.

| Nr | Schritt | Erwartung | Ergebnis |
|---|---|---|---|
| 0.1 | `wget https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/<ZWEIG>/installer.lua installer.lua` | Datei wird geladen | |
| 0.2 | `installer zentrale <ZWEIG>` | Warnt vor beweglichem Zweig, wartet auf Enter; danach "Installiert: Version 0.1.0" | |
| 0.3 | `crn/app/main` | Zeigt Version 0.1.0, Rolle zentrale, drei Dateien mit belegten Byte, freien Platz | |
| 0.4 | Computer neu starten (`reboot`) | Zeigt dieselbe Ausgabe ohne Eingabe (startup.lua wurde angelegt) | |
| 0.5 | `installer --status` und `installer --check` | Version, Rolle, Herkunft; "Alle Dateien stimmen ..." | |
| 0.6 | `installer zentrale <ZWEIG> --yes` ein zweites Mal | Gelingt; `installer --status` nennt jetzt eine Vorversion | |
| 0.7 | `installer --rollback` | "Zurueck bei Version 0.1.0."; `installer --check` bleibt gruen | |
| 0.8 | `edit crn/core/adler.lua`, ein Zeichen aendern, speichern, dann `installer --check` | "beschaedigt: core/adler.lua" | |
| 0.9 | Auf einem Computer mit fremder `startup.lua`: `installer signal <ZWEIG> --yes` | Hinweis, dass startup.lua unveraendert bleibt; Start von Hand mit `crn/app/main` | |
| 0.10 | `installer lokfuehrer <ZWEIG> --yes` | Nennt die moeglichen Rollen, aendert nichts | |

Mit einem festen Tag oder Commit statt eines Zweigs entfaellt die Warnung in 0.2.
