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

## Gefuehrte Einrichtung einer Signal-Node (Netzverzeichnis)

Das Netz wird einmal zentral beschrieben, jede Signal-Node uebernimmt daraus ihren Ausschnitt und ordnet nur noch ihre Signale zu (Konzept "Modulares Streckennetz", Abschnitte 4, 5, 10 bis 13).

**1. In der Leitstelle (einmal je Strecke).** Seite **Bereiche**: "Neu" legt einen Bereich an: Name (zum Beispiel West-Ost), Anschluss 1 und 2 (zum Beispiel Westbahnhof, Ostbahnhof), Anzahl Gleise und Vorlage: `gegenlaeufig` (erste Haelfte Richtung Anschluss 2, Rest Richtung Anschluss 1; ungerade Zahlen sind zulaessig), `gleich` (alle Richtung Anschluss 2), `beide`. Die Leitstelle vergibt dauerhafte Kennungen: Bereich `B0001`, Gleis `A0001`, spaeter Node `N0001`; sie werden nie wiederverwendet. Seite **Gleise**: Gleise umbenennen, die Richtung aendern (Anschlussname oder `beide`), Gleise ergaenzen oder loeschen. Ein Bereich oder Gleis, das eine Node uebernommen hat, laesst sich nicht loeschen. Zweimal tippen loescht.

**2. Auf der Signal-Node.** Einrichtung starten, Beitreten, Netz waehlen, Rolle **Signal** (nur diese). Dann:

1. **Bereich waehlen** (die Leitstelle liefert die Liste, auch ueber mehrere Seiten). "Von Hand" fuehrt auf den bisherigen Weg (Name, Geraete, Gleise).
2. **Gleise uebernehmen**: alle sind angehakt; abwaehlen, was diese Node nicht betreut (eine Node darf nur einen Teil eines Bereichs betreuen). "Weiter" fordert die Kennung an: die Leitstelle antwortet mit `N0001`, dem Namen (zum Beispiel "Signal West-Ost N0001") und dem Computerlabel (`N0001 | SIG | B0001`). Dieselbe Anforderung liefert dieselbe Kennung (kein Doppeleintrag nach Wiederholung oder Neustart).
3. **Signale zuordnen**: Tabelle der Gleise mit Richtung. "Signal" oeffnet die Liste der noch freien Signale (mit Zustand; ein erst nach dem Oeffnen der Einrichtung angeschlossenes Signal ist mit "(neu)" markiert), das Antippen ordnet zu und springt zum naechsten Gleis ohne Signal. "Loesen" nimmt das zuletzt zugeordnete Signal weg; mehrere Signale je Gleis sind moeglich. Weiter geht es erst, wenn jedes uebernommene Gleis ein Signal hat. Welches Signal an welchem echten Gleis steht, kann der Computer nicht lesen: Das ist die einzige Angabe, die von Hand bestaetigt wird.
4. **Pruefen und aktivieren**: Der Knopf **Pruefen+Aktivieren** bestaetigt die Zuordnung und dass der Bereich fuer die Schaltpruefung vorbereitet ist. Danach laeuft die Abschlusspruefung ohne weitere Rueckfragen (siehe unten) und aktiviert bei vollstaendigem Erfolg selbst. Das Computerlabel wird beim Aktivieren gesetzt.

**Abschlusspruefung (Konzept 13).** Reihenfolge: Pflichtangaben (Modem, Kennung der Leitstelle, Gleise, Signale, Geraete angeschlossen), dann je Signal lesen und eine kurze eigene Testsperre setzen, zuruecklesen, aufheben, zuruecklesen. Sie laeuft Schritt fuer Schritt im Sekundentakt (hoechstens etwa 0,8 s Arbeit je Takt), zeigt Signal fuer Signal den Fortschritt und laesst sich mit "Stoppen" abbrechen; es bleibt nie eine Testsperre zurueck, weil ein einzelner Test nicht unterbrochen wird. Eine schon gesetzte Sperre (Betrieb oder fremd) wird nie fuer den Test aufgehoben: das Signal bleibt "gesperrt" und die Pruefung offen, bis die Sperre weg ist. Ergebnisse gelten je Signal: ein Umbenennen kostet nichts, ein anderes Geraet macht nur dieses Ergebnis ungueltig; "Erneut pruefen" prueft nur die offenen. Vor jeder Testsperre wird der Entwurf mit einer Marke gespeichert; faellt der Computer dabei aus, erkennt der Start die Marke, hebt eine stehengebliebene Testsperre auf und meldet es. Kann der Entwurf nicht gespeichert werden, wird nicht geschaltet.

**Grenzen (bewusst, siehe Konzept 2 und 13.6).** Die Pruefung beweist weder die reale Lage eines Signals noch die Absicherung der Strecke. Kann die Leitstelle nicht erreicht werden, gibt es keine Kennung: die Einrichtung bleibt Entwurf ("Von Hand" geht trotzdem). Noch nicht Teil dieser Stufe: Anschluesse und Fahrwege, Knotenkonflikte, Standortgruppen, Bahnhof- und Knoten-Assistenten im neuen Ablauf, gleichzeitige Aenderungen mehrerer Computer, Uebernahme alter Konfigurationen. Eine bereits aktive Node wird nicht in den gefuehrten Ablauf gezogen; "Einrichtung aendern" bleibt der bisherige Assistent. Eine nie aktivierte Anforderung (abgebrochene Einrichtung) steht in der Leitstelle auf der Seite Netz als RESERVIERT und laesst sich dort verwerfen; die Kennung bleibt vergeben.

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
