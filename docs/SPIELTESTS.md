# Spieltests

Hier traegst du die Ergebnisse der Tests in der Welt ein. Ein Test zaehlt nur, wenn er im Spiel gelaufen ist.

## Stufe 0: Rahmen und Installer

Vorbereitung: ein leerer Computer (Advanced Computer genuegt), HTTP erlaubt. `<ZWEIG>` ist der Zweig dieser Stufe, solange sie nicht gemergt ist (`claude/stufe-0`), danach ein Tag oder `main`.

| Nr | Schritt | Erwartung | Ergebnis |
|---|---|---|---|
| 0.1 | `wget https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/<ZWEIG>/installer.lua installer.lua` | Datei wird geladen | |
| 0.2 | `installer`, dann `1` (Installieren), `e`, `<ZWEIG>`, bei der Rolle `q` | Menue, Versionswahl (mit Hinweis auf beweglichen Zweig) und Rollenliste mit Beschreibungen erscheinen; am Ende "Beendet. Es wurde nichts veraendert."; `installer --status` meldet "nicht installiert" | |
| 0.3 | `installer`, `1`, `e`, `<ZWEIG>`, bei der Rolle `z`, bei der Version `z`, im Menue `q` | `z` fuehrt jeweils einen Schritt zurueck, bis zum Menue | |
| 0.4 | Im Menue `x` eingeben | "Bitte eine der angegebenen Eingaben waehlen." und die Frage kommt erneut | |
| 0.5 | `installer`, `1`, `e`, `<ZWEIG>`, Rolle `zentrale`, in der Zusammenfassung `j`, bei "Jetzt starten?" `j` | Zusammenfassung nennt Rolle, Version, Dateien, Platz, "Bisher: neue Installation", startup; danach "Installiert: Version 0.1.0" und die Ausgabe von `crn/app/main` | |
| 0.6 | `reboot` | Zeigt dieselbe Ausgabe ohne Eingabe (startup.lua wurde angelegt) | |
| 0.7 | `installer`, im Menue `2` (Installation pruefen) | "Alle Dateien stimmen mit dem Verzeichnis ueberein." | |
| 0.8 | `installer`, `1`, Version `1` (zuletzt verwendet), Rolle (bisher), `j` | Zusammenfassung nennt "Version 0.1.0 wird zur Vorversion"; danach zeigt das Menue "Zur Vorversion zurueckkehren" | |
| 0.9 | `installer`, im Menue Rueckkehr waehlen, `j` | "Zurueck bei Version 0.1.0."; Pruefung bleibt gruen | |
| 0.10 | `edit crn/core/adler.lua`, ein Zeichen aendern, speichern; `installer`, `2` | "beschaedigt: core/adler.lua" | |
| 0.11 | Ohne Dialog: `installer lokfuehrer <ZWEIG> --yes`, dann `installer zentrale <ZWEIG> --yes` | Erst die Liste der Rollen und keine Aenderung, dann eine Installation ohne Rueckfrage | |
| 0.12 | Auf einem Computer mit fremder `startup.lua`: Dialog bis zur Zusammenfassung | Dort steht "bleibt unveraendert (gehoert zu einem anderen Programm)"; nach der Installation ist die Datei unveraendert | |

Mit einem festen Tag oder Commit statt eines Zweigs entfaellt die Warnung in 0.2.
