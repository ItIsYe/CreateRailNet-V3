# Installer und rollenabhaengiger Assistent

## Aenderung

Der interaktive Installer fragt keine Version: der Kanal (`main` oder `beta`) steht in der geladenen Datei (`installer.lua` bzw. `installer_beta.lua`). Er benutzt einen eigenstaendigen Terminal-Renderer, ohne
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

## Automatik (freiwillig)

Neben der Handarbeit gibt es drei Abkuerzungen, die sich mischen lassen:

- **Automatisch einrichten** (Schritt 2, neben "Weiter"): waehlt alle passenden Geraete (Bahnhoefe, Signale, Beobachter, Monitore, nie Relais), legt die Gleise an, laesst die Pruefungen laufen und springt zu "Fertig", oder dorthin, wo von Hand etwas noetig ist (Knotenpunkt, fehlender Bahnhof, offene Pruefung).
- **Alle passenden** (Schritt 3) und **Automatisch** (Schritt 4, nur bei leerer Gleisliste): dasselbe in einzelnen Schritten.
- Die Gleise entstehen so: je Bahnhof ein Gleis; gibt es nur ein Gleis, gehoeren alle Signale und Beobachter dazu; ein Signal-Node bekommt ein Gleis mit allen Signalen. Bei mehreren Bahnhoefen werden Signale und Beobachter nicht geraten (Hinweis, Zuordnung von Hand). Freigabeausgaenge gehen der Reihe nach an freie Computerseiten (Seiten mit Modem oder Monitor sind belegt); die Seite steht auf der Seite "Fertig", danach wird verdrahtet. Knotenpunkte bleiben Handarbeit.

Die Pruefungen (Schritt 5) laufen beim Betreten und vor dem Aktivieren von selbst. Lesende immer. Schaltende nur, wenn der gelesene Zustand beweist, dass sie nichts treffen: die Sperre nur bei einem gruenen, nicht gesperrten Signal ohne gemeldeten Zug, der Ausgang nur, wenn am Bahnhof des Gleises kein Zug steht, naht oder faehrt. Alles andere wartet auf die Bestaetigung von Hand (Grund in der Zeile und im Hinweis); "Neu pruefen" wiederholt alle, auch fehlgeschlagene.

## Grosse Netze (hunderte Signale)

Wer sehr viele Signale hat, richtet sie nicht einzeln ein: Am Signal-Node reicht "Automatisch einrichten" (Schritt 2: Rolle Signal, Name eintippen). Alle am Computer erkannten Signale und Beobachter landen in einem Gleis (die Gleise des Signal-Nodes sind nur Namen), die Pruefungen laufen von selbst. Gemessen am Fake: 450 Signale mit 112 Beobachtern in etwa 0,2 s Rechenzeit (die Pruefungen berechnen die Konfigurationssignatur einmal, nicht je Pruefung; sonst waren es 9 s, und das Zeichnen der Pruefungsliste brauchte je Bild ebenso lange). Im Spiel kommt die Wartezeit der Create-Aufrufe dazu: jede schaltende Pruefung setzt und loest eine Sperre (zwei Aufrufe auf dem Server-Takt, jeweils etwa ein Tick), das ergibt grob eine Minute bei 450 Signalen (Schaetzung, bitte beim Spieltest notieren). Waehrenddessen zeigt die Hinweiszeile "Pruefung n von m ..."; den Computer in dieser Zeit nicht neu starten.

Das Netz selbst traegt solche Mengen:

- Ein Signal-Node meldet seine Signale in Teilen (hoechstens 30 Signale und etwa 5000 Zeichen je Nachricht; die Funkschicht erlaubt rund 6000). Jeder Teil nennt Startposition und Gesamtzahl, die Leitstelle setzt ihn an seine Stelle. Aenderungen gehen sofort und nur fuer den betroffenen Teil, ein vollstaendiger Durchlauf folgt alle 5 s (hoechstens 6 Teile je Sekunde und Node). Ein verlorener Teil heilt mit dem naechsten Durchlauf.
- Die Konfigurationssicherung fuer den Ersatzcomputer geht in Teilen zu je 2000 Zeichen (hoechstens 100 Teile, rund 200 KB, ungefaehr 2400 Signale an einem Node). Darueber warnt der Node einmal und sichert nicht; ein Ersatz muss dann von Hand eingerichtet werden.
- Die Leitstelle nimmt hoechstens 5000 Signale je Node an.

Besser verteilt es sich trotzdem: mehrere Signal-Nodes mit je einigen dutzend Signalen halten die Wartezeiten der Pruefungen, die Funkmenge je Computer und den Schaden eines ausgefallenen Computers klein.

## Netz beitreten (Netzsuche)

Beim Beitreten ruft der Assistent einmal per Funk (Rundruf, Anfrage `netze`, vorlaeufige Kennung `neu-...`). Jede laufende Leitstelle in Reichweite antwortet mit Netzname und ihrer Kennung (und der Zahl der bekannten Nodes), sonst nichts. Der Assistent bietet die Treffer zur Auswahl an; die Wahl setzt Netzname und Leitstelle, die beiden Eingabefelder entfallen. "Netz von Hand eingeben" und "Neu suchen" stehen immer zur Verfuegung. Die Antworten sind unbeglaubigt (Rednet ist keine Anmeldung, siehe Konzept 13.5): angenommen werden nur Name und Kennung in der erlaubten Form (Buchstaben, Ziffern, Leerzeichen, - und _, hoechstens 30 Zeichen), und nur als Antwort auf den eigenen Rundruf.

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

1. Installer auf Advanced Computer mit 51x19 starten (Befehl von `beta` und von `main`: der Kanal in Menue und Zusammenfassung stimmt). Rolle, Zusammenfassung
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
