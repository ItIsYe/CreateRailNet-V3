# Installer und rollenabhaengiger Assistent

## Aenderung

Der interaktive Installer benutzt einen eigenstaendigen Terminal-Renderer, ohne
bereits installierte Module vorauszusetzen. Pfeiltasten und Enter oder Maus
waehlen Aktionen; die Buchstabentasten bleiben erhalten. Bild auf/ab bewegt
lange Erklaerungen, Pfeiltasten machen auch lange Auswahllisten erreichbar.
Die Kommandozeileninstallation und die atomare Installation bleiben bestehen.

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
Ein Entwurf kann jederzeit gespeichert werden und startet keinen aktiven Betrieb.
Bearbeitung erfolgt auf einer Kopie der bestehenden Konfiguration.

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
