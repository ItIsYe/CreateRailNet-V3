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

**2. Auf der Signal-Node.** Einrichtung starten, Beitreten, Netz waehlen, Rolle **Signal** (nur diese; ist auf dem Computer nur dieses Rollenpaket installiert, entfaellt die Rollenauswahl). Dann:

1. **Bereich waehlen** (die Leitstelle liefert die Liste, auch ueber mehrere Seiten). "Von Hand" fuehrt auf den bisherigen Weg (Name, Geraete, Gleise). **"Neu"** legt den Bereich gleich hier an (Name, zwei Anschluesse, Gleisanzahl, mit "Vorlage" gegenlaeufig, gleich oder beide); die Leitstelle speichert ihn, ein erneuter Versuch mit denselben Angaben legt nichts doppelt an, und der neue Bereich ist danach gewaehlt.
2. **Gleise uebernehmen**: alle sind angehakt; abwaehlen, was diese Node nicht betreut (eine Node darf nur einen Teil eines Bereichs betreuen). "Weiter" fordert die Kennung an: die Leitstelle antwortet mit `N0001`, dem Namen (zum Beispiel "Signal West-Ost N0001") und dem Computerlabel (`N0001 | SIG | B0001`). Dieselbe Anforderung liefert dieselbe Kennung (kein Doppeleintrag nach Wiederholung oder Neustart).
3. **Signale zuordnen**: Tabelle der Gleise mit Richtung. "Signal" oeffnet die Liste der noch freien Signale (mit Zustand; ein erst nach dem Oeffnen der Einrichtung angeschlossenes Signal ist mit "(neu)" markiert), das Antippen ordnet zu und springt zum naechsten Gleis ohne Signal. "Loesen" nimmt das zuletzt zugeordnete Signal weg; mehrere Signale je Gleis sind moeglich. Mit **"Gleis"** lassen sich Name und Richtung des gewaehlten Gleises direkt aendern (die Leitstelle fuehrt die Aenderung aus, nur fuer die Gleise dieser Node und nur, wenn niemand sie inzwischen anders geaendert hat; die Wirkrichtung der Signale wird neu bewertet). **"Details"** zeigt je Signal Funktion (Streckensignal, Knoteneinfahrt, Knotenausfahrt), Wirkrichtung und Standort; Vorgabe ist Streckensignal und die Richtung des Gleises, bei einem Gleis mit "beide" muss die Wirkrichtung gewaehlt werden (Pflichtangabe vor dem Aktivieren). Weiter geht es erst, wenn jedes uebernommene Gleis ein Signal hat. Welches Signal an welchem echten Gleis steht, kann der Computer nicht lesen: Das ist die einzige Angabe, die von Hand bestaetigt wird.
**Mehrere Signale hintereinander auf einem Gleis.** Ein Gleis darf beliebig viele Signale tragen (gemessen bis 280 Signale an einer Node). Ab zwei Signalen verlangt die Einrichtung die **Reihenfolge**: Sie geht von Anschluss 1 nach Anschluss 2 des Bereichs (zum Beispiel von Westbahnhof nach Ostbahnhof), das erste Signal liegt also am naechsten bei Anschluss 1. Die Tabelle zeigt dann `Reihenfolge?` am Gleis, und **Weiter** bleibt gesperrt. Unter **Details** sind die Signale nummeriert; **Hoch** und **Runter** schieben das gewaehlte Signal, **Reihenf. bestaet.** bestaetigt die Reihenfolge. Jede Aenderung der Signale oder der Reihenfolge nimmt die Bestaetigung zurueck. Wo die Lage der Signale gebraucht wird, steht sie als "Signal 2/5" und "zwischen Sig_A und Sig_C" (an den Enden steht der Anschlussname): auf der Seite Signale der Node, wo die Zeile unter der Liste das gewaehlte Signal beschreibt, und auf der Seite Signale der Leitstelle. Das ist Wissen fuer Anzeige und Pruefung; die Steuerung wertet die Reihenfolge nur beim Knoten aus (siehe unten). Die Software steuert die Signale einzeln, Create regelt die Streckenabschnitte dazwischen selbst. Im bisherigen ("Von Hand") Ablauf gibt es die Reihenfolge nicht.

4. **Pruefen und aktivieren**: Der Knopf **Pruefen+Aktivieren** bestaetigt die Zuordnung und dass der Bereich fuer die Schaltpruefung vorbereitet ist. Danach laeuft die Abschlusspruefung ohne weitere Rueckfragen (siehe unten) und aktiviert bei vollstaendigem Erfolg selbst. Das Computerlabel wird beim Aktivieren gesetzt.

**Abschlusspruefung (Konzept 13).** Reihenfolge: Pflichtangaben (Modem, Kennung der Leitstelle, Gleise, Signale, Geraete angeschlossen), dann je Signal lesen und eine kurze eigene Testsperre setzen, zuruecklesen, aufheben, zuruecklesen. Sie laeuft Schritt fuer Schritt im Sekundentakt (hoechstens etwa 0,8 s Arbeit je Takt), zeigt Signal fuer Signal den Fortschritt und laesst sich mit "Stoppen" abbrechen; es bleibt nie eine Testsperre zurueck, weil ein einzelner Test nicht unterbrochen wird. Eine schon gesetzte Sperre (Betrieb oder fremd) wird nie fuer den Test aufgehoben: das Signal bleibt "gesperrt" und die Pruefung offen, bis die Sperre weg ist. Ergebnisse gelten je Signal: ein Umbenennen kostet nichts, ein anderes Geraet macht nur dieses Ergebnis ungueltig; "Erneut pruefen" prueft nur die offenen. Vor jeder Testsperre wird der Entwurf mit einer Marke gespeichert; faellt der Computer dabei aus, erkennt der Start die Marke, hebt eine stehengebliebene Testsperre auf und meldet es. Kann der Entwurf nicht gespeichert werden, wird nicht geschaltet.

**Grenzen (bewusst, siehe Konzept 2 und 13.6).** Die Pruefung beweist weder die reale Lage eines Signals noch die Absicherung der Strecke. Kann die Leitstelle nicht erreicht werden, gibt es keine Kennung: die Einrichtung bleibt Entwurf ("Von Hand" geht trotzdem). Bahnhof-, Depot-, Anmeldung- und Knoten-Nodes werden im selben Ablauf eingerichtet (siehe unten und `docs/NETZVERZEICHNIS.md`). Eine bereits eingerichtete Node kann ueber "Einrichtung aendern" in das Verzeichnismodell uebernommen werden (siehe unten). Eine nie aktivierte Anforderung (abgebrochene Einrichtung) steht in der Leitstelle auf der Seite Netz als RESERVIERT und laesst sich dort verwerfen; die Kennung bleibt vergeben.

**Abgleich mit dem Verzeichnis (Konzept 15).** Eine aktive, ueber das Verzeichnis eingerichtete Signal-Node fragt zwanzig Sekunden nach dem Start und danach alle zehn Minuten nach Namen und Richtungen ihrer Gleise. Auf der Seite **Signale** steht das Ergebnis (stimmt / Abweichung / frage / keine Antwort); eine Abweichung wird einmal gemeldet und nur auf Druck von **"Uebernehmen"** uebernommen (Name, Richtung, Bereich, Stand, Wirkrichtung der Signale; die Konfiguration wird gespeichert, bei einem Speicherfehler bleibt alles wie vorher). Wird dabei eine Wirkrichtung offen (die Richtung ist jetzt "beide" und die bisherige Wirkrichtung ist kein Anschluss des Bereichs mehr), steht das im Hinweis und als Meldung; die Schaltpruefungen bleiben gueltig, die Wirkrichtung ist unter "Einrichtung aendern" festzulegen. **"Abgleich"** fragt sofort. Antwortet die Leitstelle nicht oder unlesbar, bleibt die lokale Einrichtung unveraendert und es wird keine Abweichung behauptet. Ein im Verzeichnis geloeschtes Gleis wird gezeigt, aber nie automatisch entfernt.

## Bereichsassistent (Leitstelle, Seite Assistent)

Die gerade Strecke legt die Seite Bereiche an. Die Seite **Assistent** bietet drei weitere Vorlagen; "Waehlen" traegt die Vorlage ein, dann die Felder (Trenner `;`):
- **nebenanschluss**: Name der Hauptstrecke, Anschluesse `Westbahnhof; Ostbahnhof`, Gleisanzahl, Nebenanschluss `Hafen; gueter; Gleis 1; Ostbahnhof` (Name; Art; Hauptgleis; Fahrtrichtungen oder beide). Der Bahnhof bekommt eine Verbindung zu genau diesem Hauptgleis und den eingetragenen Richtungen; zu parallelen Gleisen wird nichts angenommen. Eine vorhandene Betriebsstelle gleichen Namens wird verwendet.
- **verzweigung**: Name des Knotens, Anschluesse `West:2; Ost:2; Sued:1` (Anschluss:Gleisanzahl). Je Anschluss entsteht ein Bereich (Anschluss bis Knoten), der Knoten fasst deren Gleisenden zusammen, Fahrwege und Konflikte werden vorgeschlagen und muessen auf der Seite Knoten bestaetigt werden.
- **frei**: Name, Anschluesse `Ein; Aus`, Gleise `Hauptgleis:Aus; Gegengleis:Ein; Abstell:beide`.
- **teilen**: Name des neuen Bereichs, dessen Anschluesse `Westbahnhof; Ostbahnhof` und `Gleise` als `Alter Bereich: Gleis 3; Gleis 4`. Die genannten Gleise wechseln mit unveraenderter Kennung in den neuen Bereich (Anschluss 1 und 2 entsprechen denen des alten, die Richtungen der Gleise ziehen mit); der alte Bereich behaelt mindestens ein Gleis. Nodes, deren Gleise alle wechseln, gehen mit und bekommen ein neues Label; eine Node mit Gleisen auf beiden Seiten verhindert das Aufteilen, bis sie sich auf eine Seite beschraenkt. Eine Signal-Node, die dort eingerichtet ist, zeigt im Abgleich "Bereich", Uebernehmen setzt die neue Zuordnung.
Jede Vorlage ist alles oder nichts; die Ergebnisse sind normale Objekte und lassen sich danach auf den Seiten Bereiche, Gleise, Betriebsstellen, Beziehungen und Knoten aendern. Ein zweiter Anschluss derselben Betriebsstelle (zum Beispiel bei einer Ringstrecke) steht auf der Seite Anschluesse: Art `betriebsstelle`, Ziel `Hafen`, Zusatz `Nord`.

## Ersatzcomputer (Konzept 11.4)

Seite Einrichtung -> "Ersatz" (nur auf einem nicht eingerichteten Computer): Kennung der Leitstelle eingeben, **"Liste"** zeigt alle Nodes mit Sicherung in der Leitstelle samt Zustand: *ausgefallen* (meldet sich nicht mehr) oder *stillgelegt* sind uebernehmbar, *NOCH AKTIV* wird abgelehnt, bis der alte Computer aus ist oder in der Leitstelle stillgelegt wurde. Die Auswahl in der Liste ersetzt das Tippen der Kennung ("Eingeben" schaltet zurueck); "Holen" fordert die Konfiguration an, "Uebernehmen" fuehrt in den letzten Schritt, wo die Geraete des neuen Computers geprueft und aktiviert werden. Die Antwort der Leitstelle ist unbeglaubigt: Kennungen und Zustaende werden auf die erlaubte Form geprueft, ein Name in falscher Form wird weggelassen, andere Abweichungen verwerfen die Liste.

## Bestehende Node ins Verzeichnis uebernehmen

Auf einer schon eingerichteten Signal-, Bahnhof- oder Depot-Node: Seite Einrichtung, "Einrichtung aendern", beitreten, "Netz von Hand eingeben" (Netzname und Leitstelle sind vorbelegt), dann wie oben Bereich waehlen und Gleise uebernehmen. Die bisherigen Gleise werden nach ihrem Namen (Gross-/Kleinschreibung egal) den Gleisen des Bereichs zugeordnet und behalten Signale, Bahnhoefe und Ausgaenge. Gibt es zu einem bisherigen Gleis kein gleichnamiges im Bereich, steht das vor der Anforderung da ("Diese Gleise der bisherigen Einrichtung gibt es im Bereich nicht"): dann das Gleis im Bereich anlegen oder umbenennen. Die Node behaelt ihre bisherige Kennung; die Leitstelle fuehrt sie unter der neuen Kennung. Danach laeuft die Pruefung wie gewohnt; sie setzt kurze eigene Testsperren (bestehende Sperren bleiben). Eine Knoten-Node mit eigener Einrichtung laesst sich nicht vermischen: "Von Hand" behaelt sie.

## Bahnhof und Depot ueber das Netzverzeichnis

Beim Beitreten mit den Rollen Passagierbahnhof, Gueterbahnhof, Depot (einzeln oder mit Signal kombiniert) folgt dieselbe Bereichswahl wie bei der Signal-Node (Bereich waehlen oder mit "Neu" anlegen, Gleise uebernehmen). Die Leitstelle vergibt Kennung, Namen und Computerlabel (`N0003 | PBF | B0002`); der Name der Betriebsstelle selbst wird in der Leitstelle gefuehrt. Danach geht es wie bisher weiter: **Geraete** (Train Station, Ausgaenge), **Gleise** (hier steht je Gleis nur "Zuordnen": Name und Richtung kommen aus dem Verzeichnis, Gleise lassen sich lokal weder anlegen noch kopieren noch loeschen), **Test**, **Fertig**. "Von Hand" fuehrt auf den bisherigen Weg mit eigenem Namen. **Mehrere Rollen auf einem Computer** (Bahnhof, Depot und Signal, auch mit Anmeldung) gehen denselben Weg: eine Anforderung, ein Bereich, eine Kennung; Name und Label nennen die Rollen (`N0001 | PBF SIG | B0001`). Bei den Gleisen folgen je Gleis Bahnhof, Signal und Ausgang, danach gegebenenfalls die Anmeldestation. Mit nur der Rolle Signal gilt der kurze gefuehrte Ablauf. Der Knoten wird allein angefordert.

**Anmeldung allein** gehoert zu einer Betriebsstelle des Netzes (Seite Betriebsstellen in der Leitstelle): Betriebsstelle waehlen, Kennung (`N0005 | ANM | BF0001`), Geraete, Anmeldestation, Test, Aktivieren. Die Betriebsstelle laesst sich in der Leitstelle nicht loeschen, solange die Anmeldung sie nutzt.

**Pruefungen im bisherigen Ablauf (Konzept 13.1, 13.2, 13.4, 13.5).** Beim Oeffnen des Schritts Test laufen die lesenden Pruefungen von selbst. **"Alle pruefen"** zeigt die Wirkung aller offenen schaltenden Pruefungen zusammen, verlangt eine gemeinsame Bestaetigung ("Vorbereitung erledigt: alle starten") und fuehrt sie nacheinander aus; bleibt ein Ausgang danach eingeschaltet, stoppt die Serie und meldet es. "Einzeln" fuehrt die markierte Pruefung aus, "Lesende" wiederholt die lesenden. Ein Ergebnis bleibt gueltig, solange das geprueftes Geraet beziehungsweise der Ausgang dasselbe ist und die Zuordnung seines Gleises (Richtung, Geraete, Knotenanschluss) unveraendert ist: eine Namensaenderung, ein weiteres Gleis oder ein anderes Geraet entwertet die uebrigen Ergebnisse nicht.

## Knoten ueber das Netzverzeichnis

Beim Beitreten mit genau der Rolle **Knotenpunkt** waehlt man den Knoten aus der Liste der Leitstelle (Seite Knoten dort: Anschluesse aus Gleisenden, Fahrwege, Konflikte; Vorschlaege muessen bestaetigt sein, sonst steht der Knoten als UNBESTAETIGT da und laesst sich nicht uebernehmen). Der naechste Bildschirm zeigt, was uebernommen wird: Anschluesse, Verbindungen (Fahrwege, auf Anschlussebene zusammengefasst, siehe unten), Konflikte, Einfahrten und Ausfahrten. "Weiter" fordert die Kennung an (Label `N0004 | KNO | K0001`). Danach geht es mit **Geraete** und **Gleise** weiter: jede Einfahrt bekommt Signal und Beobachter, jede Ausfahrt einen Beobachter; Anschluss und Rolle der Gleise stehen schon fest. Test und Aktivieren wie bei den Bahnhoefen.

**Was das Modell der Node kennt.** Die Knoten-Node arbeitet mit Anschluessen: eine Einfahrt belegt alle Verbindungen, die dort beginnen. Das Verzeichnis kennt Fahrwege zwischen einzelnen Gleisenden. Beim Uebernehmen werden Fahrwege zu Verbindungen zwischen Anschluessen zusammengefasst, Konflikte werden auf diese Verbindungen abgebildet (ein Konflikt zwischen Fahrwegen derselben Verbindung entfaellt, weil die Einfahrt ohnehin nur einen Zug zulaesst). Das ist vorsichtig: es wird nie weniger ausgeschlossen als im Verzeichnis. Ein Gleisende, das zugleich Start und Ziel von Fahrwegen ist, kann die Node nicht abbilden; sie nennt das Gleis und bricht ab ("Von Hand" bleibt moeglich). Gleisenden ohne Fahrweg bleiben unberuecksichtigt.

**Einfahrtsignal bei mehreren Signalen.** Hat ein Einfahrtsgleis mehrere Signale, sperrt und gibt die Knoten-Node nur das Signal frei, das als **Einfahrt** markiert ist; die uebrigen Signale regelt Create allein. Nach der Signalwahl fuehrt der Assistent dazu in den Detailbildschirm: dort **Einfahrt** am Signal unmittelbar vor dem Knoten tippen (die anderen werden zu Streckensignalen), die Reihenfolge ist hier "zum Knoten hin", das Einfahrtsignal muss also das letzte sein, und die Reihenfolge muss bestaetigt werden. Eine falsche Lage (nicht das letzte) oder fehlende Markierung ist eine Pflichtangabe, die die Einrichtung nicht weiterkommen laesst. Aeltere Einrichtungen ohne Markierung sperren wie bisher alle Signale des Gleises (vorsichtig). Mit nur einem Signal am Einfahrtsgleis aendert sich nichts. Welches Ende des Gleises am Knoten liegt, erkennt die Software nicht von selbst: darauf beruht die Angabe "zum Knoten hin".

**Abgleich.** Eine aktive Knoten-Node fragt nach dem Start und danach alle zehn Minuten den Stand ihres Knotens in der Leitstelle ab. Hat er sich geaendert, holt sie die ganze Fassung (Anschluesse, Fahrwege, Konflikte), fragt zur Sicherheit noch einmal nach dem Stand (hat die Leitstelle inzwischen weitergeaendert, wird neu geholt) und wertet aus. Auf der Seite Knoten steht dann entweder "... Uebernehmen moeglich (Fahrwege 2 -> 2, Konflikte 0 -> 1)" oder "... nicht uebernehmbar (Grund) Einrichtung neu durchlaufen"; in beiden Faellen kommt einmal eine Meldung. **"Uebernehmen"** (zweimal tippen, der erste Druck zeigt die Aenderung) setzt neue Fahrwege, Konflikte und Gleisnamen ein, speichert und baut die Vormerkregeln der laufenden Rolle neu auf. Voraussetzungen: dieselben Gleise mit denselben Anschluessen und derselben Rolle (Ein- oder Ausfahrt), der Knoten ist frei (nichts vorgemerkt oder unterwegs), alle Gleise haben ihre Zuordnung zum Verzeichnis. Sonst oder bei einem Speicherfehler bleibt alles wie vorher; geaenderte Gleise, Anschluesse oder Rollen brauchen die Einrichtung mit Pruefung ("Einrichtung aendern"). Jede neue Abfrage macht eine halb gegebene Bestaetigung ungueltig. "Abgleich" fragt sofort.

### Pflichtangaben und Pruefungen je Rolle

| Rolle | Pflichtangaben vor dem Aktivieren | Pruefungen |
|---|---|---|
| Signal (gefuehrt) | Funkmodem, Kennung der Leitstelle, mindestens ein Gleis, je Gleis mindestens ein Signal, je Signal die Wirkrichtung | je Signal lesen und eigene Testsperre setzen, zuruecklesen, aufheben, zuruecklesen (Abschlusspruefung, ohne Einzelabfragen) |
| Passagier-/Gueterbahnhof | je Gleis eine Train Station und ein Freigabeausgang (keine doppelten Ausgaenge) | Train Station lesen; Ausgang kurz schalten und zuruecklesen (gemeinsame Bestaetigung) |
| Depot | je Gleis eine Train Station | Train Station lesen; Ausgang, falls eingerichtet |
| Anmeldung | eine Station fuer die Anmeldung | Station lesen |
| Knoten | mindestens zwei Anschluesse und eine Verbindung; je Einfahrt ein Gleis mit Signal, je Ausfahrt ein Gleis mit Beobachter | Signale und Beobachter lesen; Signal-Testsperre (gemeinsame Bestaetigung) |
| Leitstelle | Netzname, keine zweite Leitstelle | keine Geraetepruefung |

Eine Funktion erzeugt erst dann Pflichtangaben, wenn ihre Rolle gewaehlt ist (Konzept 12.5): beispielsweise wird ein Beobachter nur beim Knoten verlangt.

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
