# Grosser Test

Der Test findet statt, wenn alle Stufen gebaut sind (Plan: `docs/STUFENPLAN.md`). Jede Stufe traegt hier ihre Schritte ein; du fuehrst sie im Spiel aus und schreibst das Ergebnis in die letzte Spalte. Gebaut ist jeweils nur, was auch ausserhalb des Spiels getestet ist; ob es im Spiel funktioniert, zeigt erst dieser Test.

Installation fuer den ganzen Test (Testbranch `beta`): `wget https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/beta/installer_beta.lua installer.lua`, dann `installer` (Dialog, fragt keine Version: sie ergibt sich aus dem Befehl). Der stabile Stand steht auf `main`: `wget https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/main/installer.lua installer.lua`.

## Stufe 1: Kern (Uhr, Speichern, Journal, Funk)

Zwei Computer mit Funkmodem (Ender-Modem) an beliebiger Rolle, die Rolle spielt hier keine Rolle.

| Nr | Schritt | Erwartung | Ergebnis |
|---|---|---|---|
| 1.1 | Computer A: `crn/app/main selftest` | Alle Zeilen "ok", am Ende "Alle lokalen Pruefungen bestanden."; `Uhr laeuft in Spielzeit` zeigt etwa 3,5 s | |
| 1.2 | Computer B: `crn/app/main selftest listen zentrale-1` | "Antwortet als 'zentrale-1' ..." und die Funkmodem-Zeile | |
| 1.3 | Computer A: `crn/app/main selftest ping bahnhof-1 zentrale-1` | "5 von 5 Antworten", Laufzeit in Spielsekunden je Ping; B zeigt fuenf "Ping von bahnhof-1" | |
| 1.4 | Computer B mit Strg+T beenden, A erneut pingen | "keine Antwort" fuenfmal, "0 von 5 Antworten" | |
| 1.5 | Computer A waehrend `selftest` (beim Warten) ausschalten und neu starten, dann `crn/app/main selftest` | Test laeuft wieder sauber durch (keine Reste aus dem Abbruch) | |
| 1.6 | `ls /crn_data` | Kein Rest von `selftest` | |

## Stufe 2: Geraete (Bahnhof, Beobachter)

Ein Computer mit Create-Geraeten am Kabelmodem (mindestens ein Bahnhof und ein Beobachter). Waehrend der Pruefung duerfen Zuege fahren.

| Nr | Schritt | Erwartung | Ergebnis |
|---|---|---|---|
| 2.1 | `crn/app/main selftest geraete` | Liste aller Geraete mit Typen; fuer jeden Bahnhof und jeden Beobachter "ok" bei Methoden und "lesbar"; vorhandene Create-Signale werden nur gezaehlt (die Strecke regelt Create); am Ende "Alle Geraetepruefungen bestanden." Ein Bahnhof ohne Zug zeigt "kein Zug", nicht "FEHLER" | |
| 2.2 | Zug am Bahnhof halten lassen, dann `crn/app/main selftest geraete` | Bei diesem Bahnhof steht "Zug <Name>" | |
| 2.3 | entfaellt: die Software setzt keine Signalsperren mehr | entfaellt | entfaellt |
| 2.4 | entfaellt: die Software setzt keine Signalsperren mehr | entfaellt | entfaellt |
| 2.5 | Einen Beobachter vom Kabelmodem trennen, `selftest geraete` | Er fehlt in der Liste; kein Absturz des Programms | |

## Stufe 3: Oberflaeche und Assistent

Ein Computer ohne Einrichtung (alte `/crn_data` mit `delete /crn_data` entfernen), Advanced Computer, Funkmodem; moeglichst ein Monitor am Kabelmodem (Advanced Monitor, fuer das grosse Layout mindestens 5x4 Bloecke bei Textgroesse 0,5 oder 10x6 bei der Vorgabe 1,0; kleinere zeigen die kompakte Ansicht ab 6x3 Bloecken bei 1,0; Rechnung in `docs/MESSWERTE.md`, Q02/Q03). Start mit `crn/app/main` (oder Neustart).

| Nr | Schritt | Erwartung | Ergebnis |
|---|---|---|---|
| 3.1 | Start ohne Einrichtung | Seite "Einrichtung", Betriebszustand "Einrichtung", Kopfzeile "CRN - noch nicht eingerichtet" | |
| 3.2 | Assistent: Schritt 1 ohne Netzname auf "Weiter" | Hinweis "Der Netzname fehlt."; mit Namen geht es weiter | |
| 3.3 | Schritt 2: ohne Rolle auf "Weiter"; dann Rolle Leitstelle waehlen oder (Netz beitreten) Bahnhof | Hinweis; danach Eingabe des Namens (nur Buchstaben, Ziffern, Leerzeichen, - und _) | |
| 3.4 | Schritt 3 (Geraete) | Alle Create-Geraete mit Typ; Funk- und Kabelmodem getrennt genannt (z.B. "Funk: left   Kabel: right"); Antippen setzt "[x]" | |
| 3.5 | Schritt 4 (Gleise): Gleis anlegen (Name und Train Station auf einem Bildschirm, keine Frage nach Richtung oder Beobachter), "Kopieren" | Ein Geraet laesst sich nur einem Gleis geben; es gibt keine Frage nach einem Ausgang und keine nach Signalen; die Kopie hat keine Geraete | |
| 3.6 | Schritt 5 (Test): "Alle pruefen" | Alle Pruefungen (Train Station lesen) stehen schon beim Oeffnen auf ok; es gibt nichts zu schalten und keinen Bestaetigungsbildschirm | |
| 3.7 | Schritt 6, "Aktivieren" | Zustand "Bereit"; nach einem Neustart (`reboot`) startet der Node mit derselben Einrichtung | |
| 3.8 | Schritt 6 ohne alle Pruefungen | "Aktivieren" ist gesperrt (Hinweis nennt den Grund); es gibt keinen Entwurf-Knopf; nichts wird gespeichert | |
| 3.9 | Monitor: berühren der Reiter, Einrichtung dort bedienen, waehrend der Terminal eine andere Seite zeigt | Jede Ansicht hat ihre eigene Seite; bearbeitet die eine die Einrichtung, zeigt die andere "Einrichtung wird bearbeitet." | |
| 3.10 | Monitor verkleinern/vergroessern (Skalierung ueber `monitor.setTextScale` von Hand) oder anderen Monitor nehmen | Layout wechselt zwischen gross (ab 100x40), kompakt (ab 51x19) und Statusansicht; Eingaben bleiben | |
| 3.10a | Seite "Geraete" (am Computer oder am Monitor): den Monitor in der Liste waehlen, Taste "Textgroesse 0,5" (bzw. "1,0") druecken; danach den Computer neu starten | Der Monitor wechselt die Textgroesse, der Hinweis nennt Wert und Raster (zum Beispiel "monitor_0: Textgroesse 0,5, 100x52 Zeichen."), das Layout passt sich an (5x4 Bloecke: bei 1,0 nur Statusansicht, bei 0,5 gross); die Taste bietet den Rueckweg an; nach dem Neustart gilt der Wert weiter; ein Monitor, an dem nie umgeschaltet wurde, behaelt eine von Hand gesetzte Textgroesse | |
| 3.11 | Ein Create-Geraet im Betrieb abziehen und anschliessen | Meldungen "Geraet entfernt" und "Geraet angeschlossen" | |
| 3.12 | Seite "Geraete" und "Meldungen", Meldung quittieren | Quittiert aendert nur die Meldung | |
| 3.13 | Laufende (aktive) Node: Seite "Einrichtung", "Einrichtung aendern", dann "Abbrechen" (zweimal) | Hinweis "Verworfen; die laufende Einrichtung bleibt"; Zustand bleibt "Bereit" | |
| 3.14 | Schritt 2: eine Rolle abwaehlen, zu der schon Geraete oder Gleise gewaehlt sind | Hinweis nennt, wie viele Geraete und Gleise entfallen; erst das erneute Antippen entfernt sie | |
| 3.15 | Schritt 3 bis 5 laenger offen lassen, dazwischen ein Geraet abziehen | Die Anzeige liest nicht dauernd neu; "Neu lesen" und "Weiter" erkennen den Ausfall (Weiter sperrt, Tests werden ungueltig) | |
| 3.16 | Zweiter Computer (zum Beispiel Bahnhof), Einrichtung starten, "Diesem bestehenden Netz beitreten", Weiter. Die Leitstelle laeuft in Funkreichweite (Ender-Modem) | Seite "Welchem Netz soll dieser Computer beitreten?": nach wenigen Sekunden steht dort das Netz der Leitstelle mit "Leitstelle <Kennung>". Auswaehlen und Weiter fuehrt direkt zur Rolle (Netzname und Leitstelle werden nicht mehr getippt) | |
| 3.17 | Dasselbe mit ausgeschalteter Leitstelle oder ausser Reichweite | "Kein Netz gefunden ..."; "Netz von Hand eingeben" fuehrt zu den Feldern Netzname und Leitstelle; "Neu suchen" wiederholt die Suche | |
| 3.22 | **Node-Verzeichnis**: neuer Computer, Rolle Bahnhof, Kennung anfordern; denselben Computer die Anforderung noch einmal senden (Weiter ohne Aenderung) | Kennung `N000x`, Label `N000x \| BHF`; die zweite Anforderung liefert dieselbe Kennung, kein zweiter Eintrag unter *Netz* | |
| 3.23 | Neuer Computer mit einer Train Station: Einrichtung starten, Beitreten, Netz waehlen, Rolle Bahnhof, Weiter | Bildschirm "Kennung anfordern"; "Von Hand" fuehrt auf den Weg ohne Verzeichnis (eigener Name) | |
| 3.24 | Auf "Kennung anfordern" Weiter | Die Leitstelle vergibt die Kennung (Hinweis "Kennung N0001"), Name "Personenbahnhof N0001"; in der Leitstelle Seite "Netz": N0001 RESERVIERT | |
| 3.25 | Geraete waehlen, bei den Gleisen "Neu": Name und Train Station auf einem Bildschirm; ein zweites Gleis | Mit "Weiter" geht es zurueck zur Gleisliste; Weiter ist erst moeglich, wenn jedes Gleis eine Train Station hat; welche Train Station welche ist, bestaetigst du von Hand | |
| 3.26 | Test, Aktivieren | Die lesenden Pruefungen stehen auf ok; die Node ist aktiv, das Computerlabel lautet `N0001 \| BHF` (im Spiel pruefen); die Leitstelle fuehrt N0001 nach wenigen Sekunden als aktiv | |
| 3.27 | entfaellt: keine Signalsperren mehr, die eine Pruefung beachten muesste | entfaellt | entfaellt |
| 3.28 | entfaellt: keine schaltende Abschlusspruefung mehr | entfaellt | entfaellt |
| 3.29 | Waehrend der Einrichtung den Computer ausschalten (Strom/Chunk), neu starten | Die Einrichtung beginnt von vorn (es gibt keinen Entwurf); derselbe Computer bekommt dieselbe Kennung (keine zweite Node in der Leitstelle) | |
| 3.30 | Aktive Node in der Leitstelle: Seite "Netz" | N0001 steht mit Zustand und Gleisen; die Reservierung ist "aktiv" | |
| 3.31 | entfaellt: es gibt keine Bereiche und Anschluesse mehr | entfaellt | entfaellt |
| 3.32 | Seite "Bahnhoefe": einen Bahnhof mit mehreren Gleisen umbenennen (Aendern) | Die Anmeldung, die diesen Bahnhof nennt, traegt den neuen Namen (Seite *Netz*, Kennung und Label bleiben); die Halte der Vorlagen folgen | |
| 3.33 | entfaellt: Bereiche, Knoten und Signale gibt es nicht mehr (Create regelt die Strecke) | entfaellt | entfaellt |
| 3.34 | entfaellt: Bereiche, Knoten und Signale gibt es nicht mehr (Create regelt die Strecke) | entfaellt | entfaellt |
| 3.35 | entfaellt: Bereiche, Knoten und Signale gibt es nicht mehr (Create regelt die Strecke) | entfaellt | entfaellt |
| 3.36 | entfaellt: Bereiche, Knoten und Signale gibt es nicht mehr (Create regelt die Strecke) | entfaellt | entfaellt |
| 3.37 | entfaellt: Bereiche, Knoten und Signale gibt es nicht mehr (Create regelt die Strecke) | entfaellt | entfaellt |
| 3.38 | entfaellt: Bereiche, Knoten und Signale gibt es nicht mehr (Create regelt die Strecke) | entfaellt | entfaellt |
| 3.39 | Computer mit Train Station: Beitreten, Netz, Rolle Bahnhof, Weiter (Kennung anfordern) | Die Leitstelle vergibt eine Kennung `N000x`; es folgen Geraete und Gleise; bei den Gleisen "Neu", Bearbeiten, Kopieren, Entfernen wie bei jeder Node | |
| 3.40 | Schritt Test: nichts antippen, Liste ansehen; dann "Alle pruefen" | Die lesenden Pruefungen stehen schon auf ok; es wird nichts geschaltet, es gibt keinen Bestaetigungsbildschirm; kein wartender Zug faehrt ab | |
| 3.41 | Nach dem Aktivieren Computerlabel ansehen und in der Leitstelle die Seite "Netz" | Label `N000x \| BHF`; die Node steht als aktiv | |
| 3.42 | entfaellt: Bereiche, Knoten und Signale gibt es nicht mehr (Create regelt die Strecke) | entfaellt | entfaellt |
| 3.43 | entfaellt: Bereiche, Knoten und Signale gibt es nicht mehr (Create regelt die Strecke) | entfaellt | entfaellt |
| 3.44 | entfaellt: Bereiche, Knoten und Signale gibt es nicht mehr (Create regelt die Strecke) | entfaellt | entfaellt |
| 3.45 | Eine schon laufende Bahnhof-Node (bisherige Einrichtung): auf der Node "Einrichtung aendern", beitreten (das eigene Netz ist vorgewaehlt, Weiter), Kennung anfordern | Gleise und Geraete bleiben, wie sie sind; die Leitstelle zeigt eine reservierte Kennung `N000x` | |
| 3.46 | Test und Aktivieren | Die Node behaelt ihre bisherige Kennung, bekommt das Label `N000x \| BHF`, die Leitstelle fuehrt `N000x` danach als aktiv | |
| 3.47 | entfaellt: Bereiche, Knoten und Signale gibt es nicht mehr (Create regelt die Strecke) | entfaellt | entfaellt |
| 3.48 | entfaellt: Bereiche, Knoten und Signale gibt es nicht mehr (Create regelt die Strecke) | entfaellt | entfaellt |
| 3.49 | entfaellt: Bereiche, Knoten und Signale gibt es nicht mehr (Create regelt die Strecke) | entfaellt | entfaellt |
| 3.50 | Computer mit Train Stations: Beitreten mit den Rollen Bahnhof und Anmeldung | Eine Kennung, Label `N000x \| BHF ANM`; je Gleis Name und Bahnhof, danach die Anmeldestation; nach dem Test aktiv | |
| 3.51 | Computer mit einer Train Station: Beitreten mit der Rolle Anmeldung, Bahnhof waehlen | Die Liste zeigt die gemeldeten Bahnhoefe (Bahnhoefe mit mehreren Gleisen unter ihrem Namen); Kennung `N000x`, Label `N000x \| ANM`, Name `Anmeldung <Bahnhof> N000x`; Geraete, Anmeldestation, Test, aktiv | |
| 3.52 | entfaellt: Bereiche, Knoten und Signale gibt es nicht mehr (Create regelt die Strecke) | entfaellt | entfaellt |
| 3.53 | entfaellt: Bereiche, Knoten und Signale gibt es nicht mehr (Create regelt die Strecke) | entfaellt | entfaellt |
| 3.54 | entfaellt: die Warnung vor doppelter Gleis-/Signalzuordnung entfaellt (nur gleiche Node-Kennungen werden gemeldet) | entfaellt | entfaellt |
| 3.55 | entfaellt: Bereiche, Knoten und Signale gibt es nicht mehr (Create regelt die Strecke) | entfaellt | entfaellt |
| 3.56 | entfaellt: Bereiche, Knoten und Signale gibt es nicht mehr (Create regelt die Strecke) | entfaellt | entfaellt |
| 3.57 | entfaellt: Bereiche, Knoten und Signale gibt es nicht mehr (Create regelt die Strecke) | entfaellt | entfaellt |
| 3.58 | entfaellt: Bereiche, Knoten und Signale gibt es nicht mehr (Create regelt die Strecke) | entfaellt | entfaellt |
| 3.59 | entfaellt: Bereiche, Knoten und Signale gibt es nicht mehr (Create regelt die Strecke) | entfaellt | entfaellt |
| 3.60 | Ersatzcomputer: Seite Einrichtung -> "Ersatz", Leitstelle eintragen, "Liste" | Alle Nodes mit Sicherung stehen mit Zustand in der Liste; eine laufende Node ist "NOCH AKTIV" und wird beim Holen abgelehnt | |
| 3.61 | entfaellt: es gibt keine Signalzuordnung und keine Knoten-Node mehr | entfaellt | entfaellt |
| 3.62 | entfaellt: es gibt keine Signalzuordnung und keine Knoten-Node mehr | entfaellt | entfaellt |
| 3.63 | entfaellt: es gibt keine Signalzuordnung und keine Knoten-Node mehr | entfaellt | entfaellt |
| 3.64 | entfaellt: es gibt keine Signalzuordnung und keine Knoten-Node mehr | entfaellt | entfaellt |
| 3.65 | entfaellt: es gibt keine Signalzuordnung und keine Knoten-Node mehr | entfaellt | entfaellt |
| 3.66 | Funk kurz stoeren (Modem entfernen) an einer Bahnhof-Node mit vielen Gleisen, dann wieder anschliessen | Nach hoechstens 10 Sekunden ist die Anmeldung vollstaendig, der Zustand wieder frisch; es entstehen keine Fehlermeldungen im Sekundentakt | |
| 3.67 | Ersatz einer Bahnhof-Node mit 12 Gleisen (alte Node aus, Ersatzcomputer: Ersatz, Liste, Node waehlen, Holen) | Der Zustand zeigt "Empfange Konfiguration: Teil k von n", danach "empfangen"; Uebernehmen zeigt alle 12 Gleise | |
| 3.68 | Zwei frische Computer nacheinander (und einmal ein Neustart mitten in der Einrichtung) mit Rolle Bahnhof oder Depot einrichten | Jeder bekommt eine eigene Kennung (`N0001`, `N0002`, ...), auch wenn die Einrichtung des zweiten gleich nach dem ersten beginnt; kein Computer meldet "Leitstelle antwortet nicht"; nach einem Neustart und neuem Anfang bekommt derselbe Computer wieder seine Kennung | |
| 3.69 | Bahnhof-Node mit vielen Gleisen (zum Beispiel 12 Gleise, jedes mit Create-Station) einrichten und aktivieren | Die Leitstelle kennt alle Gleise (Seite Gleise/Bahnhoefe), der Zustand aller Gleise wird frisch gezeigt, keine Meldung "Nachricht zu gross"; der Bahnhof nimmt Aufgaben an | |
| 3.70 | Leitstelle neu aufsetzen (Daten der Leitstelle loeschen, Programm neu installieren, gleiche Node-Kennung), ohne die laufenden Nodes neu zu starten | Die Nodes folgen der neuen Leitstelle nach hoechstens zwei Minuten (Anmeldung, Zustand); Aufgaben der Leitstelle werden nicht als "veraltet" verworfen | |
| 3.71 | Mehr als 30 Fahrtvorlagen und mehr als 20 Bahnhoefe anlegen; neue Anmeldung: Bahnhof waehlen; Anmeldestation: Vorlagenliste ansehen | Alle Bahnhoefe und Vorlagen erscheinen vollstaendig (mehrere Seiten), nichts doppelt, nichts fehlt | |
| 3.72 | Chunk der Leitstelle entladen (Spieler weit weg gehen, kein Chunk-Lader), 2 Minuten warten, wieder laden | Die Leitstelle startet neu; nach hoechstens etwa 5 Sekunden stehen alle Nodes und Bahnhoefe wieder in der Liste; eine laufende Fahrt wird zu Ende gefuehrt; auf den Nodes ist keine Meldung "Antwort verworfen" oder "veraltet" | |
| 3.73 | Chunk eines Bahnhofs entladen, waehrend ein Zug mit gesetzter Freigabe abfaehrt, dann wieder laden | Die Freigabe des Bahnhofs ist verbraucht, der Auftrag steht in der Klaerung ("Zug nicht mehr am Bahnhof"), die Node meldet "fiel in die Zeit ohne Betrieb"; ein nachfolgender Zug faehrt nicht ohne Freigabe ab | |
| 3.74 | Chunk eines Bahnhofs entladen, Zug bleibt mit gesetzter Freigabe stehen, wieder laden | Freigabe bleibt, der Zug faehrt nach Beladung ab, der Auftrag schliesst ab | |
| 3.75 | Neue Node einrichten, waehrend der Chunk der Leitstelle entladen ist | Meldung "Kein Netz gefunden: Leitstelle an, Chunk geladen?"; nach dem Laden der Leitstelle findet "Neu suchen" das Netz | |
| 3.76 | Notieren: Laufen Create-Zuege weiter, wenn die Chunks der Strecke nicht geladen sind? Bleibt der Fahrplan eines Zuges erhalten, dem vor dem Entladen ein Abschnittsfahrplan gesetzt wurde? | Nur Messwerte fuer `docs/MESSWERTE.md`, kein Soll | |
| 3.77 | Neue Leitstelle ohne Daten: Einrichtung starten, *Erste Leitstelle dieses Netzes erstellen*, Netzname, weiter | Auf der Rollenseite ist *Leitstelle* schon angehakt; keine Anleitungszeile endet mit `~`; die Zusammenfassung nennt Netz, Node und Rolle auf getrennten Zeilen | |
| 3.78 | Nach dem Aktivieren die Seite *Uebersicht* ansehen, dann die erste Node einrichten | Zuerst steht dort "Naechster Schritt: andere Computer einrichten ...", nach der ersten gemeldeten Node keiner mehr | |
| 3.79 | Auf der Leitstelle `installer zentrale` fuer eine neuere Version, wenn schon Daten in `/crn_data` liegen | Reicht der Platz nicht, nennt die Meldung `--replace`; im Dialog gibt es die Wahl *Bisherige Version ersetzen*; danach laeuft die Leitstelle mit den alten Daten (Netz, Nodes, Auftraege) weiter | |
| 3.80 | Funkmodem einer Node abziehen, Computer neu starten, Modem wieder anschliessen | Die Seite *Uebersicht* zeigt erst `KEIN FUNKMODEM`, nach dem Anschliessen kommt die Meldung "Funkmodem angeschlossen" und die Node meldet sich ohne Neustart bei der Leitstelle | |
| 3.81 | Seite *Update* auf einer Node oeffnen | Zeigt installierte Version und Stand, Kanal, Rolle, Betriebsart *automatisch*, "Aktuell, geprueft vor ... min" (nach einigen Minuten) | |
| 3.82 | Knopf *Modus* dreimal druecken | automatisch, nur melden, aus, wieder automatisch; die Wahl bleibt nach einem Neustart | |
| 3.83 | Neue Version auf den Kanal bringen (beta), auf einer Node *Pruefen* | "Neu: Version ... (Stand ...)"; bei *automatisch* und ruhiger Node installiert sie nach hoechstens rund 40 Minuten selbst und startet neu; bei *nur melden* kommt eine Meldung | |
| 3.84 | Nach dem Neustart die Seite *Update* ansehen | "Neuer Stand in der Probezeit", nach 2 Minuten Meldung *Update auf Version ... bestaetigt*; die Vorversion bleibt (`installer --status`) | |
| 3.85 | Rueckfall pruefen (nur wo eine Vorversion da ist): im Lua-Prompt `/crn_data/probe` mit dem Inhalt `2` und einer Zeile `bad=test` anlegen, neu starten | Die Startdatei kehrt zur Vorversion zurueck (`installer --status`), CRN startet, die Seite *Update* nennt den Stand `test` als zurueckgenommen | |
| 3.86 | Leitstelle: `crn/app/main update pruefen`, dann `jetzt` | Bei neuem Stand installiert *jetzt* die neue Version neben der alten; ist der Platz knapp (viele Daten unter /crn_data), meldet es stattdessen "Alt und neu passen nicht zugleich ... --replace" und veraendert nichts; waehrend einer Fahrt installiert sich die Leitstelle nicht von selbst | |
| 3.87 | Bahnhof einrichten, Schritt 4 *Gleise*: Gleis bearbeiten, Bahnhof waehlen, weiter | Die Frage nennt das Gleis einmal ("Welcher Create-Bahnhof gehoert zu Gleis 1"), danach geht es zurueck zur Gleisliste (kein Ausgang-Menue); nichts ist mit ~ abgeschnitten; die Titelzeile zeigt den Node-Namen, ohne Namen die Kennung | |
| 3.89 | Nach einem Update (oder `reboot`) mitten in der Einrichtung | Die Einrichtung beginnt von vorn; kein "Entwurf" in Meldungen, Uebersicht oder Titel; Weiter laeuft ohne Namenszwang; die Leitstelle fuehrt dieselbe Node-Kennung weiter, keine zweite Anforderung | |
| 3.90 | Einrichtungsbilder auf 51x19 durchgehen (Netz, Aufgabe, Geraete, Gleise, Test, Fertig) | Schrittleiste in Zeile 2 (`1 2 [3 Geraete] 4 5 6`), darunter Ueberschrift und Erklaerung; unten Zurueck/Weiter links und Abbrechen rechts; Bild-Tasten eine Zeile darueber; Hinweis bis zu zwei Zeilen, nichts abgeschnitten, keine Tasten uebereinander | |
| 3.91 | entfaellt: es gibt keine Signale im Gleis mehr | entfaellt | entfaellt |
| 3.92 | Bahnhof einrichten und aktivieren, danach Seite *Einrichtung*, *Einrichtung aendern*, Weiter | Im Schritt Netz steht "Dieser Computer gehoert schon zu diesem Netz" mit dem eigenen Netz angehakt (keine Suche, keine Meldung "schon eingerichtet"); Weiter fuehrt zu Rolle und Kennung; der Assistent laeuft bis *Aktivieren* durch, die Kennung bleibt gleich, die Leitstelle zeigt keine zweite Node | |
| 3.93 | entfaellt: es gibt keine Knoten-Node mehr | entfaellt | entfaellt |
| 3.94 | Bahnhof einrichten ohne angeschlossene Train Station, Schritt *Geraete*, Weiter | Hinweis "Keine Train Station am Computer gefunden: anschliessen, dann Neu lesen"; nach dem Anschliessen und *Neu lesen* steht die Station in der Liste, danach heisst der Hinweis wieder "muss ausgewaehlt werden" | |
| 3.95 | Computer mit nur der Rolle Leitstelle (Installer: zentrale), Einrichtung starten | Es gibt nur "Erste Leitstelle dieses Netzes erstellen" (angehakt), kein "Beitreten" | |
| 3.96 | entfaellt: keine Knoten-Messung mehr noetig (Create regelt Kreuzungen) | entfaellt | entfaellt |
| 3.97 | Messung der Abfahrt in einem Lauf: Computer mit Kabelmodem an einen Bahnhof mit Zug, `http` erlaubt: `wget https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/beta/probe/crn_alles.lua crn_alles.lua`, dann `crn_alles` und einmal `j` bestaetigen (`--ja` ohne Frage, `--ziel NAME`, `--ohne-fahrt`, `--lokal`, `--nicht-hochladen`; `crn_alles --hilfe` zeigt alle Optionen). Das Ziel des Rundlaufs darf nicht der eigene Bahnhof des Zuges sein (M20), sonst entfaellt der Rundlauf mit Hinweis; ohne `--ziel` nimmt das Programm den ersten anderen Bahnhof aus dem Fahrplan des Zuges (`--ziel auto`). Stand 2026-11-06 (M21, M22): die Proben A bis D sind gemessen. Das Programm laedt `crn_probe3` selbst und fuehrt die Fahrplan-Proben am Bahnhof aus (mit einem zweiten Bahnhof am Netz auch den Rundlauf des Zuges); Gesamtdauer etwa 2 bis 5 Minuten | Am Ende steht `Uploaded as https://pastebin.com/...`: diesen Link senden (oder `crn_alles.txt` hier einfuegen). Der Fahrplan ist wieder der urspruengliche ("IDENTISCH mit vorher"); der Bericht enthaelt die Kurzfassung und den vollstaendigen Bericht | |
| 3.98 | **Loeschen**: In der Leitstelle Seite "Vorlagen" eine Vorlage waehlen, "Loeschen" (zweimal); dasselbe, waehrend ein Auftrag aus ihr laeuft oder eine Linie sie fuehrt | Erster Druck fragt nach ("Nochmal druecken"); mit laufendem Auftrag oder Linie bleibt die Vorlage und die Meldung nennt den Grund; sonst ist sie weg | |
| 3.99 | **Node entfernen**: Seite "Netz", eine laufende Node waehlen, "Entfernen" (ausgegraut mit Grund); dann "Stilllegen" (zweimal) und "Entfernen" (zweimal) | Eine laufende Node laesst sich nicht entfernen ("erst stilllegen"); die stillgelegte verschwindet samt Gleisen aus der Liste; der alte Computer taucht nicht wieder auf | |
| 3.100 | **Einrichtung loeschen**: auf einem eingerichteten Bahnhof Seite "Einrichtung", "Einrichtung loeschen" (zweimal), danach "Einrichtung starten" | Der Computer ist "noch nicht eingerichtet"; Netze lassen sich suchen (kein "schon eingerichtet"); er behaelt seine Kennung und ist nach der Neueinrichtung wieder dieselbe Node; in der Leitstelle steht er bis zum Entfernen als nicht erreichbar | |
| 3.101 | **Bahnhof aendern**: Seite "Bahnhoefe", "Neu": Name und Gleise (Create-Namen mit ; getrennt); danach "Aendern": Namen aendern und ein Gleis dazunehmen, speichern | Es gibt weiter einen Bahnhof (kein zweiter Eintrag), mit neuem Namen und den neuen Gleisen; eine Vorlage, die den alten Namen als Halt hatte, nennt den neuen; mit laufendem Auftrag zu diesem Bahnhof bleibt der Name und die Meldung nennt den Auftrag; "Neu" mit vorhandenem Namen verweist auf "Aendern" | |
| 3.102 | **Linie und Vorlage aendern**: Seite "Linien", "Aendern": Titel und Takt aendern, Kennung im Formular veraendern; Seite "Vorlagen", "Aendern": Titel und Halte aendern | Die Linie behaelt ihre Kennung (keine zweite Linie), die Vorlage ihre Kennung und Prioritaet; die Vorlage laesst sich unter einem laufenden Auftrag nicht aendern (Meldung nennt den Auftrag); die Tasten der Vorlagenseite stehen in zwei Zeilen und sind alle sichtbar (Anfordern, Neu, Aendern, Prio, Muster, Loeschen) | |
| 3.103 | **Zug aendern**: einen Zug in Create umbenennen, Seite "Zuege", "Aendern": Anzeigenamen und Create-Zugnamen anpassen | Die Leitstelle erkennt den Zug unter dem neuen Namen wieder; "Unnamed Train" und ein vergebener Name werden abgelehnt; mit aktivem Auftrag geht es nicht | |

## Stufe 4: Erster Bahnhof (Zugregister, Fahrtauftrag, Freigabe)

Aufbau (drei Computer, alle mit Funkmodem, alle mit `installer` auf die gleiche Version gebracht und eingerichtet wie in Stufe 3):

- **Leitstelle** `hauptstelle`, Rolle "Leitstelle" (zentrale). Kein Create-Geraet noetig.
- **Weizenhof** `weizenhof`, Rollen "Bahnhof" und "Anmeldung". Ein Gleis mit dem Create-Bahnhof "Weizenhof". Einen Freigabeausgang (Redstone) gibt es nicht mehr: die Abfahrt wird ueber den Fahrplan der Train Station freigegeben (`docs/FREIGABE_PER_FAHRPLAN.md`).
- **Zentrallager** `lager`, Rolle "Bahnhof", ein Gleis mit dem Create-Bahnhof "Zentrallager".
- Ein Zug, der noch **"Unnamed Train"** heisst, steht am Weizenhof. Zwischen beiden Bahnhoefen liegt Gleis, auf dem der Zug fahren kann.
- Uhrzeit-/Wartezeiten sind Betriebszeit (E1); alle Zeitangaben unten in Spielsekunden.

| Nr | Schritt | Erwartung | Ergebnis |
|---|---|---|---|
| 4.1 | Alle drei Computer starten (`crn/app/main`) | Nach spaetestens 30 s zeigt die Leitstelle auf "Netz" beide Bahnhoefe als erreichbar mit je einem Gleis und dem Bahnhofsnamen | |
| 4.2 | Weizenhof, Seite "Gleise" | Gleis, Bahnhofsname, "Zug: Unnamed Train" | |
| 4.3 | **Vor der Anmeldung**, Zug heisst noch "Unnamed Train": in Create am stehenden Zug einen Fahrplan mit einer Mengenbedingung anlegen (Ziel Weizenhof, Bedingung "Gegenstaende ... Weizen ... Menge 7"; die Zahl 7 nur dort verwenden). Leitstelle, Seite "Vorlagen", "Muster": Bahnhof `Weizenhof`, Zahl `7`, "Fahrplan lesen" | "Muster gespeichert (Feld data.threshold)". Bei einer Zahl, die mehrfach vorkommt (z.B. 0), kommt "kommt mehrfach vor"; ohne Mengenbedingung "keine Mengenbedingung" | |
| 4.4 | Weizenhof, Seite "Anmeldung", "Zug anmelden": Kennung `GZ-001`, Create-Zugname `GZ-001`, Anzeigename frei, Laenge, Fracht, Bedarfsbetrieb, "Anmelden" | "Angemeldet: GZ-001". Der Zug heisst in Create jetzt `GZ-001` und steht mit einem Warteauftrag (zyklisch, Ziel "Weizenhof", der Probefahrplan aus 4.3 ist ersetzt) am Gleis. Leitstelle, Seite "Zuege": GZ-001 "gesteuert", am Bahnhof Weizenhof | |
| 4.5 | Dieselbe Anmeldung mit dem Namen "Unnamed Train" mit einem anderen Zug versuchen | "Abgelehnt: Der Standardname ..." | |
| 4.6 | Leitstelle, "Vorlagen", "Neue Vorlage": Kennung `weizen`, Titel `Weizen liefern`, Zug `GZ-001`, Halte `Weizenhof:5:640; Zentrallager:3`, "Speichern" | Vorlage steht in der Liste | |
| 4.7 | Weizenhof, Seite "Fahrten" (nach spaetestens 10 s) | Taste "Weizen liefern", Zustand "bereit" | |
| 4.8 | Taste druecken (genau einmal) | Auftrag laeuft: "angefordert" -> "wird geprueft" -> "Fahrplan uebergeben" (der Zug behaelt den Warteauftrag) -> "Abfahrt freigegeben (noch nicht bestaetigt)". In Create hat der Zug jetzt den **Abschnittsfahrplan** mit genau zwei Eintraegen: Weizenhof (Wartezeit 5 s abzueglich der schon gestandenen, danach Menge 640) und Zentrallager (Bedingung "Redstone-Signal an" als Halt). Die Seite "Gleise" zeigt "Abfahrt freigegeben, noch nicht bestaetigt" | |
| 4.9 | Die Menge im Zug (Weizen) unter 640 lassen und 40 s warten | Der Zug faehrt **nicht**; Auftrag bleibt "Abfahrt freigegeben (noch nicht bestaetigt)", keine Klaerung (Create prueft die Menge im ersten Eintrag des Abschnitts; **nicht gemessen**: bitte bei Abweichung den Fahrplan notieren) | |
| 4.10 | 640 oder mehr Weizen in den Zug laden | Abfahrt (rund 1,2 s nach Erreichen der Bedingungen); Auftrag "unterwegs"; die Seite "Gleise" zeigt keine offene Freigabe mehr | |
| 4.11 | Ankunft Zentrallager | Auftrag "am Ziel", danach neue Freigabe am Zentrallager (Abschnitt Zentrallager -> Weizenhof, Wartezeit 3 s, Restzeit nach dem Stehen), nach der Abfahrt keine offene Freigabe | |
| 4.12 | Rueckkehr zum Weizenhof | Auftrag "abgeschlossen"; Zug wartet wieder mit dem Warteauftrag (ein zyklischer Eintrag Weizenhof mit "Redstone-Signal an" als Halt) | |
| 4.13 | Taste zweimal kurz hintereinander druecken, waehrend kein Auftrag laeuft | Genau ein Auftrag; die zweite Rueckmeldung zeigt "Auftrag A-n laeuft" | |
| 4.14 | Nach 4.8 (vor der Abfahrt) die Leitstelle neu starten (`reboot`) | Nach dem Start: derselbe Auftrag, Zustand bleibt; kein neuer Auftrag, kein erneutes Setzen des Fahrplans; die Fahrt wird zu Ende gefuehrt | |
| 4.15 | Nach 4.8 den Computer Weizenhof neu starten | Die Freigabe bleibt, der Fahrplan am Zug wird nicht erneut gesetzt, danach wird die Abfahrt normal gemeldet | |
| 4.16 | Nach 4.8 den Zug von Hand abfahren lassen (Create-Eingriff), bevor die Menge erreicht ist, oder die Menge vorab erreichen und der Train Station von Hand ein Redstone-Signal geben | Leitstelle: Auftrag "KLAERUNG erforderlich" mit Grund; es wird nichts als Erfolg gewertet | |
| 4.17 | Am Weizenhof den Zug in Create von Hand auf einen **eigenen** Fahrplan umstellen (nicht der Warteauftrag), dann Taste druecken | Auftrag "KLAERUNG erforderlich" ("Ausgangslage unklar" / "Fahrplan unbekannt"); der fremde Fahrplan bleibt unveraendert, es wird nichts ueberschrieben | |
| 4.18 | Funkmodem der Leitstelle waehrend 4.8 fuer 20 s entfernen und wieder anschliessen | Die Fahrt laeuft nach dem Wiederanschluss weiter; hoechstens ein Auftrag, keine doppelte Freigabe | |
| 4.19 | Nach 4.8 (Zug steht noch wegen fehlender Menge) Seite "Gleise" am Weizenhof, "Freigabe zurueck" (zweimal tippen) | Nur nach Bestaetigung wird dem Zug wieder der Warteauftrag gesetzt; er faehrt auch bei erreichter Menge nicht ab. Der Auftrag steht danach in der Klaerung oder wartet auf eine neue Freigabe | |
| 4.20 | **Gleicher Zugname (M14)**: einen Zug in Create `Express` nennen und am Zentrallager stehen lassen; einen zweiten Zug am Weizenhof ebenfalls `Express` nennen und anmelden (Kennung `GZ-002`, Create-Zugname `Express`) | "Abgelehnt: Einen Zug namens Express gibt es im Netz schon (steht an Zentrallager). Bitte einen anderen Namen waehlen." (umgebrochen, nicht abgeschnitten); der Zug am Weizenhof bleibt unbenannt und ist nicht registriert. Mit dem Namen `Express 2` klappt die Anmeldung. Faehrt der erste Zug weiter, bleibt der Name vergeben ("gesehen an") | |
| 4.20 | Messprogramm `crn_probe` oder Create-Fahrplananzeige: bei 4.4 und 4.8 den Zugfahrplan ansehen | Bei 4.4: ein Eintrag, letzte Bedingung "Redstone-Signal an". Bei 4.8: zwei Eintraege, im ersten keine Redstone-Bedingung, im zweiten "Redstone-Signal an" als letzte; je Eintrag nur eine Bedingungsgruppe | |

Hinweis fuer den Test: Gemessen sind `create:powered` ohne Strom (haelt), `setSchedule` mit geaendertem Inhalt, die Abfahrt 1,2 s nach dem Setzen (H1 bis H5, M21/M22). Nicht gemessen ist die Mengenbedingung im ersten Eintrag eines Abschnitts bei einem stehenden Zug (4.9/4.10) und die Restwartezeit (4.11). Bitte bei Abweichung den Fahrplan der Create-Anzeige notieren.

## Stufe 5: Zweiter Bahnhof, mehrere Gleise, Linien und Takt, Tafel

Aufbau: wie Stufe 4, dazu ein **Personen-/Hauptbahnhof mit drei Haltegleisen** (`hbf`, Rolle "Bahnhof"; drei Create-Bahnhoefe "Hbf Gleis 1" bis "Hbf Gleis 3", jedes Gleis mit - falls bekannt - der Gleislaenge in Wagen im Assistenten). Beide Zuege (`GZ-001`, ein zweiter angemeldeter Zug) stehen auf Gleisen des Hauptbahnhofs. Das Gleisnetz verbindet alle Gleise mit dem Zentrallager. Fuer die Anmeldung weiterer Zuege am Hauptbahnhof muss dort eine Anmeldestation gewaehlt sein (Rolle "Anmeldung").

| Nr | Schritt | Erwartung | Ergebnis |
|---|---|---|---|
| 5.1 | Leitstelle, Seite "Bahnhoefe", "Neu": Name `Hauptbahnhof`, Gleise `Hbf Gleis 1; Hbf Gleis 2; Hbf Gleis 3` (das bevorzugte zuerst), "Speichern" | Der Bahnhof steht in der Liste mit den drei Gleisen. Ein Gleis in zwei Bahnhoefen wird abgelehnt ("gehoert schon zum Bahnhof ...") | |
| 5.2 | Seite "Vorlagen", "Neu": Kennung `pendel`, Zug `GZ-001`, Halte `Hauptbahnhof:0; Zentrallager:20`, "Speichern" | Vorlage steht in der Liste (Bahnhofsgruppen und einzelne Bahnhoefe sind als Halte erlaubt) | |
| 5.2a | Seite "Vorlagen", "Neu": Halte `Hauptbahnhof:0; Hauptbahnhof:5; Zentrallager:20`, danach nur `Zentrallager`, danach `Hauptbahnhof:0; Zentrallager:20; Hauptbahnhof:0` | Alle drei werden abgelehnt, mit Hinweis wie "Hauptbahnhof zweimal hintereinander (Halt 1, 2).", "Zentrallager zweimal hintereinander (Halt 1, Rueckfahrt)." und "... (Halt 3, Rueckfahrt)"; ein Zug wird nicht direkt wieder zum selben Bahnhof geschickt (Create, `docs/MESSWERTE.md` M20); mit einem anderen Bahnhof dazwischen wird die Vorlage gespeichert | |
| 5.3 | "Anfordern" mit dem Zug auf **Gleis 2** | Im Fahrplan des Zuges steht Start "Hbf Gleis 2", Ziel "Zentrallager", danach das **bevorzugte freie Gleis** des Hauptbahnhofs (Gleis 1). Die Fahrt laeuft bis "abgeschlossen"; der Zug wartet danach auf Gleis 1 mit dem Warteauftrag | |
| 5.4 | Dasselbe, waehrend ein anderer Zug auf Gleis 1 steht | Rueckfahrt zu Gleis 2 (oder 3), nie auf das belegte Gleis; im Auftrag steht kein Fehler | |
| 5.5 | Seite "Bahnhoefe", Eintrag waehlen, "Sperre" (sperrt das erste Gleis) und eine Fahrt anfordern | Das gesperrte Gleis wird nicht zugewiesen; "Sperre" nochmal hebt die Sperre auf. Ein Zug, der schon auf dem gesperrten Gleis steht, bleibt unberuehrt | |
| 5.6 | Bei der Laenge: ein Gleis kuerzer als der Zug (im Assistenten Gleislaenge eintragen) | Dieses Gleis wird als Ziel uebersprungen ("zu kurz") | |
| 5.7 | Alle Gleise des Hauptbahnhofs belegen oder sperren und eine Fahrt anfordern | Auftrag "wartet" mit Begruendung je Gleis; sobald eins frei ist, geht es von selbst weiter (spaetestens nach 10 s) | |
| 5.8 | Zwei Zuege mit je einer Vorlage zum selben Zielbahnhof anfordern (gleiche Sekunde) | Beide Fahrten kommen zustande; der zweite Zug wartet, bis das Ziel frei ist ("dem Auftrag A-n zugewiesen"), danach faehrt er | |
| 5.9 | Vorlage waehlen, "Prio" (bevorzugt) und zwei Fahrten konkurrieren | Die bevorzugte bekommt das Zielgleis zuerst; ein normaler Auftrag, der schon laenger als 2 Minuten wartet, wird nicht dauernd verdraengt | |
| 5.10 | Seite "Linien", "Neu": Kennung `pendel`, Titel `Pendel`, Vorlage `pendel`, Zuege `GZ-001; GZ-002`, Takt `120`, "Speichern" | Erster Termin nach 120 s; die Liste zeigt "naechster Termin in ... s" | |
| 5.11 | 10 Minuten laufen lassen | Jeder Termin erzeugt genau einen Auftrag (Seite "Auftraege": Quelle Linie); die beiden Zuege wechseln sich ab; ist kein Zug bereit, steht "Termin ausgelassen: kein Zug bereit am Start" und der Zaehler "ausgelassen" steigt, ohne dass Fahrten nachgeholt werden | |
| 5.12 | "Ein/Aus" bei der Linie | Ausgeschaltet entstehen keine neuen Termine; laufende Fahrten bleiben | |
| 5.13 | Leitstelle waehrend einer Linienfahrt neu starten | Die Fahrt laeuft weiter; nach dem Start kommt kein Schwall an Terminen, sondern hoechstens einer, falls einer faellig war | |
| 5.14 | Seite "Linien" der Leitstelle und Seite "Tafel" auf den Bahnhofs-Nodes | Die Tafel der Bahnhoefe zeigt zwei getrennte Zeilen je Linie: **Plan** (naechster Termin in ... s) und **Ist** (Zug, Zustand, Halt k/n); die Leitstelle zeigt beides in der Zeile der Linie ("in 30 s, GZ-1 unterwegs 1/2" oder "kein Zug") und hat keine eigene Tafelseite | |
| 5.15 | Zug bei einer Linienfahrt auf ein anderes Gleis des Ziels umleiten (Create-Eingriff) | Ankunft "an unerwarteter Station" -> Auftrag "KLAERUNG erforderlich", kein stiller Erfolg | |

Zu 5.x: Die Fahrzeit der Linien wird in dieser Stufe nicht geschaetzt; die Tafel zeigt deshalb nur den Plan-Termin der Abfahrt und den gemeldeten Ist-Stand, keine geschaetzte Ankunftszeit.

## Stufe 6: Signal-Node und Knotenpunkt (entfallen)

Seit Datenformat 4 regelt Create die Strecke vollstaendig: Signale, Bloecke, Weichen und Kreuzungen. Es gibt keine Rollen Signal und Knoten mehr, und die Software setzt keine Signalsperren. Die Schritte 6.1 bis 6.15 und die Abnahmen A09 und A11 entfallen. A10 (Computer stoppen, Modem abziehen) steht an einem Bahnhof in 9.3.

Fuer die Strecke genuegt eine Sichtpruefung im Spiel (nicht Teil der Software): Zuege halten vor einem belegten Block und an einer belegten Kreuzung, ohne dass ein Computer beteiligt ist.

## Stufe 7: Depot und manuelle Zuege

Aufbau: wie Stufe 4 und zusaetzlich ein **Depot** (`depot1`, Rolle "Bahnhof", ein Gleis mit Create-Bahnhof "Depot Gleis 1"). Der Zug `GZ-001` ist angemeldet und steht am Weizenhof. Die Leitstelle hat die Seiten "Depot" und "Fremde".

| Nr | Schritt | Erwartung | Ergebnis |
|---|---|---|---|
| 7.1 | Leitstelle, Seite "Depot": `GZ-001` waehlen, "Abstellen", Station `Depot Gleis 1`, "Abstellen" | Normale Fahrt (Seite "Auftraege": "Abstellen GZ-001"), Zug faehrt ohne Rueckfahrt ins Depot und wartet dort. Danach "abgestellt" in der Liste, Ausgaenge aus | |
| 7.2 | Leitstelle neu starten (`reboot`) | `GZ-001` bleibt "abgestellt"; es entsteht kein Auftrag. Bedarfstaste fuer diesen Zug: "nicht im gesteuerten Betrieb" | |
| 7.3 | Eine Linie, die `GZ-001` einsetzt, mehrere Termine lang laufen lassen | Der abgestellte Zug wird nicht gestartet ("kein Zug bereit am Start") | |
| 7.4 | Seite "Depot": `GZ-001` waehlen, "Aktivieren" | "Zug GZ-001 ist aktiv (gesteuert)." Zug ist wieder fuer Auftraege verfuegbar | |
| 7.5 | Vor 7.4 am Depotgleis den Zug umbenennen oder einen anderen Fahrplan setzen, dann "Aktivieren" | Abgelehnt mit Grund (anderer Zugname bzw. Fahrplan entspricht nicht dem Warteauftrag); der Zug bleibt abgestellt | |
| 7.6 | Waehrend ein Auftrag laeuft: "Ausschleusen" und "Abstellen" | Nicht moeglich ("laufender Auftrag") | |
| 7.7 | Zug steht am Bahnhof ohne Auftrag: "Ausschleusen" (zweimal tippen) | Zustand "ausgeschleust", Betriebsart manuell; Hinweis, dass der Create-Fahrplan im Zug bleibt. Bedarfstaste/Linie fassen den Zug nicht mehr an | |
| 7.8 | Ausgeschleusten Zug von Hand fahren lassen und an einem Bahnhof halten | Seite "Depot"/"Zuege": Position folgt den Meldungen (zuerst "unbekannt" unterwegs, dann der Bahnhof) | |
| 7.9 | "Aufnehmen" (zweimal tippen), Zug steht am Bahnhof, von Hand mit anderem Fahrplan | Der vereinbarte Warteauftrag ersetzt den alten Fahrplan (Uebergabe ist bestaetigt); Zustand "gesteuert", Betriebsart "bedarf" | |
| 7.10 | "Aufnehmen", obwohl der Zug nicht mehr am Gleis steht | Abgelehnt: "nicht nachgewiesen" | |
| 7.11 | "Art" (Betriebsart) am Haltepunkt: bedarf -> linie -> manuell -> bedarf | Wechselt nur am Haltepunkt und nicht waehrend eines Auftrags | |
| 7.12 | Fremden Zug (nicht registriert) in den Bahnhof fahren | Meldung "Unerwarteter Zug ..."; Seite "Stoerungen" zeigt ihn als "Fremd: ..." mit Ort; er wird keinem Auftrag zugeordnet; Zielwahl meidet das Gleis ("belegt von ...") | |
| 7.13 | Fremden Zug wegfahren lassen, dann auf "Stoerungen" die Zeile "Fremd: ..." waehlen und "Vergessen" | Erst danach moeglich; Belegungen anderer Nachweise bleiben unveraendert | |

## Stufe 8: Stoerung, Wiederanlauf, Ersatzcomputer, Update

Aufbau: wie Stufe 4/5; zusaetzlich ein freier Computer (Funkmodem, wenn moeglich gleiche Create-Geraete angeschlossen wie am zu ersetzenden Bahnhof) fuer den Ersatz.

| Nr | Schritt | Erwartung | Ergebnis |
|---|---|---|---|
| 8.1 | Leitstelle, Seite "Stoerungen" ohne Stoerung | "Keine Stoerung bekannt." Unten die Zahl offener Auftraege | |
| 8.2 | **A15**: Fahrt starten, in "Abfahrt freigegeben" die Leitstelle neu starten | Derselbe Auftrag, kein zweiter, kein erneutes Setzen des Fahrplans; die Fahrt endet normal | |
| 8.3 | Fahrt starten, unterwegs "Halten" (Seite Stoerungen) | Neue Fahrten und Linientermine werden nicht angenommen/gestartet; die laufende Fahrt faehrt weiter, bekommt am Ziel aber keine neue Freigabe zur Rueckfahrt; "Auftraege ... mit Freigabe/unterwegs" zaehlt mit | |
| 8.4 | "Fortsetzen" (zweimal tippen) | Die Rueckfahrt wird freigegeben und endet normal | |
| 8.5 | Leitstelle waehrend "Halten" neu starten | Halten bleibt bestehen | |
| 8.6 | Einen Bahnhofs-Node ausschalten (Strom/Chunk) | Nach ca. 60 s: Stoerung "meldet sich nicht"; keine Freigaben an ihn; Rest laeuft. Wieder einschalten: er meldet sich, nimmt Aufgaben aber erst nach der Abstimmung mit der Leitstelle an (wenige Sekunden) | |
| 8.7 | Das Create-Geraet eines Bahnhofs entfernen (Kabel/Block) | Stoerung "Geraet nicht verfuegbar", ein Auftrag mit Freigabe dort wird "Klaerung", das Gleis wird nicht als Ziel zugewiesen; nach dem Wiederanschliessen laeuft die Pruefung neu | |
| 8.8 | Zug waehrend eines Auftrags in Create umbenennen | Meldung "heisst jetzt ..."; Auftrag "Klaerung"; Zugposition "unbekannt"; kein anderer Zug wird "aehnlich" zugeordnet. Namen zurueckaendern: der Zug ist beim naechsten Zustandsbericht wieder am Gleis belegt | |
| 8.9 | Funkverbindung eines Bahnhofs kurz stoeren (Modem entfernen, Zug faehrt waehrend dessen ab oder kommt an) | Nach dem Wiederanschliessen holt der Bahnhof die Meldungen nach (Ankunft/Abfahrt werden wiederholt, bis bestaetigt); der Auftrag geht korrekt weiter | |
| 8.10 | **A17 Ersatz**: Auf dem Ersatzcomputer installieren (`installer`), Seite "Einrichtung" -> "Ersatz": Leitstelle eintragen, "Liste" und die Node waehlen (oder die Kennung tippen), "Holen" | Die Liste zeigt alle Nodes mit Sicherung und ihren Zustand (aktiv, ausgefallen, stillgelegt). Solange der alte Computer laeuft: "noch aktiv". Nach Ausschalten (60 s) oder "Stilllegen" (Seite Netz, zweimal tippen): "Konfiguration ... empfangen" | |
| 8.11 | "Uebernehmen", Geraete pruefen, Schritt 5 Pruefungen, "Aktivieren" | Der Ersatz ist derselbe logische Node (gleiche Kennung), meldet sich bei der Leitstelle; die Leitstelle meldet, dass die alte Node nicht mehr laufen darf. Aufgaben mit alter Aufenthaltsnummer gehen in "Klaerung", nichts wird blind freigegeben | |
| 8.12 | Alte Node wieder einschalten | Meldung "Zwei Computer melden sich als ..." (Doppelbetrieb), die alte Node ist abzuschalten | |
| 8.13 | **A18 Update**: "Halten", warten bis keine Fahrt mehr "mit Freigabe/unterwegs" ist; auf allen Nodes `installer` mit der neuen Version; Neustart | Nodes starten; wurde das Modpack (Host/Methoden) geaendert, zeigt der Node "Pruefung noetig" und lehnt Aufgaben ab, bis auf der Seite Uebersicht "Pruefen" bestanden ist. Dann "Fortsetzen" | |
| 8.14 | Rueckkehr: `installer --rollback` nach einem Update, das das Datenformat geaendert hat (Format 2 ist das erste solche Update: die Version ohne Entwurf; die Sicherung `sicherung_f1` enthaelt den alten Stand) | Ist das Format neuer als das Programm, startet die Automatik nicht (Seite Uebersicht: "Datenformat zu neu"); `crn/app/main datenstand` zeigt Sicherungen, `crn/app/main daten-zurueck N` spielt sie zurueck | |
| 8.15 | Datei beschaedigen (z.B. `/crn_data/register.lua` leeren, nur an einem Testsystem) | Beim Start wird die vorherige Generation geladen (Stufe 1), aktive Vorgaenge werden mit den Bahnhoefen abgeglichen | |

## Stufe 9: Betrieb im Grossen

Dies ist der Abschluss des grossen Tests. Alle Nodes laufen, mehrere Linien sind aktiv. (Die frueher automatisch geprueften 312 Signale an 26 Computern entfallen mit den Rollen Signal und Knoten.)

| Nr | Schritt | Erwartung | Ergebnis |
|---|---|---|---|
| 9.1 | Eine Stunde Betrieb mit mindestens zwei Linien und Bedarfsfahrten, niemand greift ein | Keine Meldung "Klaerung" ohne erkennbare Ursache; keine doppelten Auftraege; Seite "Stoerungen" bleibt leer oder erklaert jeden Eintrag | |
| 9.2 | Serverlast beobachten (TPS/Lag) waehrend 9.1, auf einer Bahnhof-Node `crn/app/main selftest geraete` | Keine spuerbare Verlangsamung durch die Software; Zeiten aus Stufe 2 (Messwert M16: unter 5 ms je Aufruf) gelten weiter | |
| 9.3 | **A16** Einen Bahnhof oder das Depot ausserhalb geladener Chunks bringen (weit weglaufen, ohne Chunkloader), warten, zurueckkehren | Waehrend der Abwesenheit: "meldet sich nicht"; danach meldet er sich, gleicht sich ab (kein Freigeben auf Verdacht), offene Auftraege dort gehen in Klaerung oder laufen korrekt weiter. Bitte genau notieren, was der Computer ausserhalb geladener Chunks tut | |
| 9.4 | **A16** Chunkgrenze mit fahrendem Zug: Zug faehrt in einen ungeladenen Bereich und zurueck | Der Zug wird nicht doppelt freigegeben; Ankunft/Abfahrt kommen verspaetet oder ueber den Zustandsbericht an | |
| 9.5 | Alle Spieltest-Schritte aus Stufe 4 bis 8, die noch kein Ergebnis haben, nachholen | Ergebnisse eingetragen | |
| 9.6 | Rueckmeldung an den Entwickler | Diese Datei mit allen Ergebnissen, die Meldungen der Seite "Meldungen" der Leitstelle, die Ausgabe von `crn/app/main info` und `crn/app/main datenstand` je Computertyp, und alle Abweichungen (Fahrplan-JSON aus Schritt 4.20) | |
