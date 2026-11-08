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
einen Kontextbereich. Die kompakte Ansicht (51x19) arbeitet mit denselben Pruefungen.

**Aufbau jedes Bildes (kompakt).** Zeile 2 ist die **Schrittleiste**: alle sechs Schritte als Nummern, der aktuelle mit Namen in Klammern (`1 2 [3 Geraete] 4 5 6`; erledigte gruen, kommende gedaempft). Die sechs Schritte heissen **Netz** (1), **Aufgabe** (2: Rolle, Kennung anfordern oder Betriebsstelle der Anmeldung), **Geraete** (3), **Gleise** (4: Gleise, Bahnhof, Beobachter), **Test** (5) und **Fertig** (6). Darunter steht die Ueberschrift des Bildes ("Gleise uebernehmen", "Bahnhof zuordnen" ...) und eine Zeile Erklaerung. **Unten immer dieselbe Navigation:** `Zurueck`, `Weiter` links, `Abbrechen` ganz rechts (zweimal antippen). Die Tasten des jeweiligen Bildes (Neu, Bearbeiten, Kopieren, Entfernen, Zuordnen ...) stehen in einer eigenen Zeile darueber, mit einer freien Zeile Abstand. Bildschirme ohne Weiter (Pruefen+Aktivieren, Aktivieren, Anlegen) setzen ihre Haupttaste neben Zurueck. Der **Hinweis** ueber den Tasten hat zwei Zeilen und wird umgebrochen; nichts wird abgeschnitten. Passen Titel und Einzelheit einer Listenzeile nicht nebeneinander, belegt der Eintrag zwei Zeilen. Die Fusszeile "Seite 1/1" erscheint nur, wenn die Liste mehrere Seiten hat. Passen die Tasten nicht in eine Zeile, kommen die uebrigen in die naechste; keine Taste wird verdeckt.

**Kein Entwurf.** Auf dem Computer wird nur eine vollstaendige, geprueft aktivierte Einrichtung gespeichert (`/crn_data/config.lua` mit Status "aktiv"). Waehrend der Einrichtung lebt alles im Arbeitsspeicher; nach einem Neustart oder Update beginnt der Assistent von vorn. Damit die Leitstelle keine zweite Kennung vergibt, merkt sich der Computer nur seine **Anforderungskennung** (`/crn_data/anforderung.lua`): derselbe Computer bekommt immer wieder dieselbe Node-Kennung (N0001 ...). Hat die Leitstelle die Anforderung verworfen, stellt der Assistent von selbst eine neue. Ein Entwurf aus einer aelteren Programmversion wird beim ersten Start vom Integrator verworfen (Sicherung bleibt; Anforderungskennung und eine stehengebliebene Testsperre-Marke werden uebernommen).

**Name.** Der Name der Node ist nur Anzeige und blockiert nie: im Verzeichnis vergibt die Leitstelle Name und Kennung, von Hand schlaegt der Assistent einen Namen vor (Feld leeren geht), ohne Namen gilt die Kennung (Titelzeile, Uebersicht).

**Freigabe der Abfahrt.** Es gibt keinen Freigabeausgang (Redstone am Computer) mehr: die Freigabe laeuft allein ueber die Train Station (Fahrplan, siehe `docs/FREIGABE_PER_FAHRPLAN.md`). Ein Ausgang aus einer Einrichtung vor Datenformat 3 wird beim ersten Start entfernt (`docs/DATENFORMAT.md`).

## Gefuehrte Einrichtung (Node-Verzeichnis)

Die Leitstelle vergibt jeder Node Kennung, Namen und Computerlabel; die Strecke selbst beschreibt niemand: Signale, Bloecke, Weichen und Kreuzungen regelt Create (siehe `docs/NETZVERZEICHNIS.md`). Die Node ordnet nur ihre Train Stations und Beobachter den Gleisen zu.

**1. In der Leitstelle (nur fuer die Anmeldung).** Seite **Betriebsstellen**: "Neu" legt eine Betriebsstelle an (Name, Art personenbahnhof, gueterbahnhof oder depot, optional ein Standort). Die Leitstelle vergibt dauerhafte Kennungen: Betriebsstelle `BF0001`, spaeter Node `N0001`; sie werden nie wiederverwendet. Eine Betriebsstelle, die eine Anmeldung nutzt, laesst sich nicht loeschen. Zweimal tippen loescht.

**2. Auf der Node (Bahnhof, Depot).** Einrichtung starten, Beitreten, Netz waehlen, Rolle (Passagierbahnhof, Gueterbahnhof, Depot, auf Wunsch zusammen mit Anmeldung; ist auf dem Computer nur ein Rollenpaket installiert, entfaellt die Rollenauswahl). Dann:

1. **Kennung anfordern.** "Weiter" fragt die Leitstelle; sie antwortet mit `N0001`, dem Namen (zum Beispiel "Personenbahnhof N0001") und dem Computerlabel (`N0001 | PBF`). Dieselbe Anforderung liefert dieselbe Kennung (kein Doppeleintrag nach Wiederholung oder Neustart). "Von Hand" fuehrt auf den Weg ohne Verzeichnis (eigener Name, keine Kennung der Leitstelle).
2. **Geraete** waehlen: die Train Stations und Beobachter des Computers.
3. **Gleise**: "Neu" legt ein Gleis an (Name, Richtung), danach Train Station und Beobachter des Gleises waehlen. Bearbeiten, Kopieren und Entfernen gehen wie bei jeder Node. Weiter geht es erst, wenn jedes Gleis eine Train Station hat. Welche Train Station an welchem echten Gleis steht, kann der Computer nicht lesen: das ist die einzige Angabe, die von Hand bestaetigt wird.
4. **Test und Aktivieren.** Beim Oeffnen des Schritts Test laufen die lesenden Pruefungen von selbst (Train Station und Beobachter lesen); es gibt nichts zu schalten. Das Computerlabel wird beim Aktivieren gesetzt.

**Mehrere Rollen auf einem Computer** (Bahnhof und Depot, auch mit Anmeldung) gehen denselben Weg: eine Anforderung, eine Kennung; Name und Label nennen die Rollen (`N0001 | PBF ANM`). Bei den Gleisen folgen je Gleis Bahnhof und Beobachter, danach gegebenenfalls die Anmeldestation.

**Anmeldung allein** gehoert zu einer Betriebsstelle des Netzes (Seite Betriebsstellen in der Leitstelle): Betriebsstelle waehlen, Kennung (`N0005 | ANM | BF0001`), Geraete, Anmeldestation, Test, Aktivieren.

**Grenzen (bewusst, siehe Konzept 2).** Die Pruefung beweist nicht, dass die Train Station am vorgesehenen Gleis steht. Kann die Leitstelle nicht erreicht werden, gibt es keine Kennung: die Einrichtung laesst sich ueber das Verzeichnis nicht abschliessen ("Von Hand" geht trotzdem). Eine nie aktivierte Anforderung (abgebrochene Einrichtung) steht in der Leitstelle auf der Seite Netz als RESERVIERT und laesst sich dort verwerfen; die Kennung bleibt vergeben.

**Pruefungen (Konzept 13.1, 13.2, 13.5).** Alle Pruefungen eines Bahnhofs lesen nur ("Alle pruefen" wiederholt sie, "Einzeln" fuehrt die markierte aus). Ein Ergebnis bleibt gueltig, solange das geprueftes Geraet dasselbe ist und die Zuordnung seines Gleises unveraendert ist: eine Namensaenderung, ein weiteres Gleis oder ein anderes Geraet entwertet die uebrigen Ergebnisse nicht. Ist eine Pruefung fehlgeschlagen oder offen, nennt der Hinweis unter dem Bildschirm sie mit ihrem Namen.

## Ersatzcomputer (Konzept 11.4)

Seite Einrichtung -> "Ersatz" (nur auf einem nicht eingerichteten Computer): Kennung der Leitstelle eingeben, **"Liste"** zeigt alle Nodes mit Sicherung in der Leitstelle samt Zustand: *ausgefallen* (meldet sich nicht mehr) oder *stillgelegt* sind uebernehmbar, *NOCH AKTIV* wird abgelehnt, bis der alte Computer aus ist oder in der Leitstelle stillgelegt wurde. Die Auswahl in der Liste ersetzt das Tippen der Kennung ("Eingeben" schaltet zurueck); "Holen" fordert die Konfiguration an, "Uebernehmen" fuehrt in den letzten Schritt, wo die Geraete des neuen Computers geprueft und aktiviert werden. Die Antwort der Leitstelle ist unbeglaubigt: Kennungen und Zustaende werden auf die erlaubte Form geprueft, ein Name in falscher Form wird weggelassen, andere Abweichungen verwerfen die Liste.

## Bestehende Node ins Verzeichnis uebernehmen

Auf einer schon eingerichteten Bahnhof- oder Depot-Node: Seite Einrichtung, "Einrichtung aendern", beitreten. Das eigene Netz ist vorgewaehlt ("Dieser Computer gehoert schon zu diesem Netz", keine Suche, kein "Neu suchen"); Weiter genuegt, "Netz von Hand eingeben" bleibt fuer einen Wechsel des Netzes. Dann *Kennung anfordern*: die Node behaelt ihre bisherige Kennung, die Leitstelle fuehrt sie unter der neuen Kennung. Gleise und Geraete bleiben, wie sie sind; danach laeuft die Pruefung wie gewohnt.

### Pflichtangaben und Pruefungen je Rolle

| Rolle | Pflichtangaben vor dem Aktivieren | Pruefungen |
|---|---|---|
| Passagier-/Gueterbahnhof | je Gleis eine Train Station | Train Station und Beobachter lesen |
| Depot | je Gleis eine Train Station | Train Station und Beobachter lesen |
| Anmeldung | eine Station fuer die Anmeldung | Station lesen |
| Leitstelle | Netzname, keine zweite Leitstelle | keine Geraetepruefung |

Eine Funktion erzeugt erst dann Pflichtangaben, wenn ihre Rolle gewaehlt ist (Konzept 12.5). Beobachter sind optional; wer sie waehlt, muss sie erreichen und lesen koennen.

## Netz beitreten (Netzsuche)

Beim Beitreten ruft der Assistent einmal per Funk (Rundruf, Anfrage `netze`, vorlaeufige Kennung `neu-...`). Jede laufende Leitstelle in Reichweite antwortet mit Netzname und ihrer Kennung (und der Zahl der bekannten Nodes), sonst nichts. Der Assistent bietet die Treffer zur Auswahl an; die Wahl setzt Netzname und Leitstelle, die beiden Eingabefelder entfallen. "Netz von Hand eingeben" und "Neu suchen" stehen immer zur Verfuegung. Die Antworten sind unbeglaubigt (Rednet ist keine Anmeldung, siehe Konzept 13.5): angenommen werden nur Name und Kennung in der erlaubten Form (Buchstaben, Ziffern, Leerzeichen, - und _, hoechstens 30 Zeichen), und nur als Antwort auf den eigenen Rundruf.

## Rollen

- Leitstelle: keine lokalen Gleise erforderlich, Monitor freiwillig.
- Passagier-, Gueterbahnhof und Depot: eine Station je Gleis; kein Freigabeausgang.
- Anmeldung: ausgewaehlte, gueltige Station.
- Nur Rollen mit installierten Laufzeitmodulen werden angeboten.
- Zusaetzliche Beobachter eines Bahnhofs sind optional. Ohne Auswahl
  erscheint ihre Zuordnungsseite nicht. Eine gewaehlt aktivierte Erweiterung
  muss erreichbar und pruefbar sein.

## Sperren

Geraete, Methoden, Modem, Zuordnungen, Ausgangsseiten und Tests werden vor dem
jeweiligen Hauptschritt geprueft. Die Aktivierung prueft nochmals frisch.
Gesperrte Aktionen werden auch bei Tastatur und direkter Aktionsausloesung
abgewiesen. Ein Geraeteausfall entwertet die bisherigen Testnachweise.
Konfigurationsaenderungen entwerten Tests ueber eine Konfigurationssignatur.
Es gibt keinen Entwurf: gespeichert wird erst mit "Aktivieren". Bei einer
laufenden (aktiven) Node erfolgt die Bearbeitung auf einer Kopie, die erst mit
"Aktivieren" gespeichert wird; "Abbrechen" verwirft sie.
Das Zeichnen liest die Geraete nicht neu; neu gelesen wird bei "Neu lesen", beim
Betreten von Schritt 3, bei "Weiter" und bei der Aktivierung.
Wer eine Rolle abwaehlt, zu der schon Geraete oder Gleise gewaehlt sind, bekommt
vorher gesagt, was entfaellt, und muss erneut antippen.

## Spielabnahme (noch offen)

1. Installer auf Advanced Computer mit 51x19 starten (Befehl von `beta` und von `main`: der Kanal in Menue und Zusammenfassung stimmt). Rolle, Zusammenfassung
   und fremdes Startprogramm pruefen. Lange Hinweise und alle Rollen erreichen.
2. Setup auf 51x19, 100x40 und Schwarzweiss pruefen; Touch, Tastatur und Resize.
3. Bahnhof: ohne Station nicht zum Test; es gibt keine Frage nach einem Ausgang und keine nach Signalen.
4. Train Station direkt vor Aktivierung abziehen: Aktivierung blockiert. Nach Wiederanschluss
   erneut pruefen. Signale, Bloecke und Weichen regelt Create allein.
5. Tests auslassen: Weiter blockiert; nach einem Neustart beginnt die Einrichtung von vorn, die Node behaelt ihre Kennung.
6. Zuordnung nach bestandenen Tests aendern: Tests erneut erforderlich.

Offline-Pruefungen ersetzen diese Spielabnahme nicht. Kein automatischer Merge.

Nachtrag: Eine Ausnahme in einem Ereignis (Touch, Funk, Geraet) beendet das Programm nicht mehr; sie erscheint als Meldung "Ereignis ..." (hoechstens einmal je Minute je Text).
