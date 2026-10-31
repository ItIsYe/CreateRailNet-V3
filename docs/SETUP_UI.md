# Installer und rollenabhaengiger Assistent

## Aenderung

Der interaktive Installer benutzt einen eigenstaendigen Terminal-Renderer, ohne
bereits installierte Module vorauszusetzen. Pfeiltasten und Enter oder Maus
waehlen Aktionen; die Buchstabentasten bleiben erhalten. Bild auf/ab bewegt
lange Erklaerungen, Pfeiltasten machen auch lange Auswahllisten erreichbar.
Die Kommandozeileninstallation und die atomare Installation bleiben bestehen.
Beim Beenden gibt der Dialog die Terminalfarben zurueck, leert den Bildschirm
und laesst den bisherigen Verlauf als normalen Text stehen. Auf kleinen Flaechen
(51x19) belegt jeder Auswahleintrag nur eine Zeile, damit der Text Platz behaelt.

Der Setup-Assistent zeigt auf grossen Ausgaben einen festen Schrittstreifen und
einen Kontextbereich. Die kompakte Ansicht arbeitet mit denselben Pruefungen.
Aktionsflaechen werden umgebrochen; fehlender Platz entfernt keine Aktion.

## Rollen

- Leitstelle: keine lokalen Gleise erforderlich, Monitor freiwillig.
- Passagier- und Gueterbahnhof: Station und eigener Freigabeausgang je Gleis.
- Depot: Station je Gleis, kein verpflichtender Freigabeausgang.
- Signal: mindestens ein Gleis und ein zugeordnetes Signal je Gleis.
- Knoten: Signale, Beobachter, Anschluesse, Verbindungen und Ein-/Ausfahrtszuordnung.
- Anmeldung: ausgewaehlte, gueltige Station.
- Nur Rollen mit installierten Laufzeitmodulen werden angeboten.
- Zusaetzliche Signale/Beobachter eines Bahnhofs sind optional. Ohne Auswahl
  erscheinen ihre Zuordnungsseiten nicht. Eine gewaehlt aktivierte Erweiterung
  muss erreichbar und pruefbar sein.

## Sperren

Geraete, Methoden, Modem, Zuordnungen, Ausgangsseiten und Tests werden vor dem
jeweiligen Hauptschritt geprueft. Die Aktivierung prueft nochmals frisch.
Gesperrte Aktionen werden auch bei Tastatur und direkter Aktionsausloesung
abgewiesen. Ein Geraeteausfall entwertet die bisherigen Testnachweise.
Konfigurationsaenderungen entwerten Tests ueber eine Konfigurationssignatur.
Ein Entwurf kann bei einer neuen oder bereits als Entwurf gespeicherten Node
jederzeit gespeichert werden und startet keinen aktiven Betrieb. Bei einer
laufenden (aktiven) Node ist "Entwurf" gesperrt: die Bearbeitung erfolgt auf
einer Kopie, die erst mit "Aktivieren" gespeichert wird; "Abbrechen" verwirft sie.
Das Zeichnen liest die Geraete nicht neu; neu gelesen wird bei "Neu lesen", beim
Betreten von Schritt 3, bei "Weiter" und bei der Aktivierung.
Wer eine Rolle abwaehlt, zu der schon Geraete oder Gleise gewaehlt sind, bekommt
vorher gesagt, was entfaellt, und muss erneut antippen.

## Spielabnahme (noch offen)

1. Installer auf Advanced Computer mit 51x19 starten. Rolle, Version, Zusammenfassung
   und fremdes Startprogramm pruefen. Lange Hinweise und alle Rollen erreichen.
2. Setup auf 51x19, 100x40 und Schwarzweiss pruefen; Touch, Tastatur und Resize.
3. Signalrolle: keine Stations-/Depotzuordnung anbieten; ohne Signal nicht weiter.
4. Bahnhof: ohne Station oder Ausgang nicht zum Test; Depot ohne Ausgang zulassen.
5. Signal direkt vor Aktivierung abziehen: Aktivierung blockiert. Nach Wiederanschluss
   erneut pruefen. Native Create-Signalsicherung bleibt massgeblich.
6. Tests auslassen: Weiter blockiert, Entwurf speichern funktioniert nach Neustart.
7. Zuordnung nach bestandenen Tests aendern: Tests erneut erforderlich.

Offline-Pruefungen ersetzen diese Spielabnahme nicht. Kein automatischer Merge.

Nachtrag: Eine Ausnahme in einem Ereignis (Touch, Funk, Geraet) beendet das Programm nicht mehr; sie erscheint als Meldung "Ereignis ..." (hoechstens einmal je Minute je Text).
