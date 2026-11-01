# Netzverzeichnis und gefuehrte Einrichtung: Stand der Umsetzung

Bezug: Konzept "Modulares Streckennetz und vereinfachte Einrichtung" (Abschnittsnummern wie dort). Dieser Stand ist der erste Schnitt: der Zielablauf der Signal-Einrichtung. Bedienung: `docs/SETUP_UI.md` (Abschnitt "Gefuehrte Einrichtung einer Signal-Node"), Abnahme im Spiel: `docs/GROSSER_TEST.md` 3.22 bis 3.30.

| Abschnitt | Inhalt | Stand | Wo |
|---|---|---|---|
| 3, 4.1, 4.2 | Bereiche, Gleise, Anschlussnamen | umgesetzt (Bereich mit zwei benannten Anschluessen und seinen Gleisen) | `src/domain/netz.lua` |
| 4.3, 4.4 | weitere Bereichsgrenzen (Nachbarbereich, offenes Ende, "im Bau") | offen | |
| 5.1 | Gleise einmal zentral anlegen, Vorlagen | umgesetzt (gegenlaeufig, gleich, beide; beliebige Zahl bis 40; Aendern auf der Seite Gleise) | Leitstelle, Seiten Bereiche und Gleise |
| 5.2 | dauerhafte Gleisidentitaet | umgesetzt (Kennung A0001, unabhaengig von Name und Reihenfolge) | `netz.lua` |
| 5.3 | Richtung mit Bezug ("Richtung Ostbahnhof") | umgesetzt (Anschlussname oder "beide"), nur Anzeige | `netz.lua`, Assistent |
| 5.4 | Wirkrichtung eines Signals, Funktion | offen (Zuordnung Signal zu Gleis ja, Wirkrichtung nein) | |
| 6, 7, 8 | Nebenanschluesse, Standortgruppen, Knoten, Fahrwege, Konflikte, Schleifen | offen | |
| 9.2 | Node betreut ein oder mehrere Gleise, auch nur einen Teil eines Bereichs | umgesetzt (Gleise abwaehlbar) | Assistent, Bildschirm Gleise |
| 9.3 | genau eine steuernde Verantwortung je Geraet | teilweise: ein Signal gehoert in der Einrichtung nur einem Gleis; Pruefung ueber mehrere Nodes noch nicht | `wizard.lua` |
| 10.1, 10.2 | zentrales Verzeichnis, Einrichtung von einem Node-Assistenten aus | umgesetzt (Leitstelle haelt es, die Node fragt Bereiche, Gleise und Kennung ab; Antworten werden auf Form geprueft) | `zentrale.lua`, `node.lua` |
| 10.3 | Aenderungen als Entwurf | teilweise (Node-Einrichtung ist Entwurf bis zur Pruefung; im Verzeichnis gilt jede Aenderung sofort, benutzte Objekte sind vor Loeschen geschuetzt) | |
| 11.1 | automatische dauerhafte Kennungen B/A/N, nie wiederverwendet | umgesetzt (BF und K noch nicht) | `netz.lua` |
| 11.2 | automatische Namen | umgesetzt in der Form "Signal West-Ost N0017" (ohne Sonderzeichen) | |
| 11.3 | Computerlabel `N0017 \| SIG \| B0042` | umgesetzt (Aufruf beim Aktivieren und beim Start; Wirkung im Spiel zu pruefen) | `node.lua`, `main.lua` |
| 11.4 | Austausch und Kopien | teilweise (Ersatz ueber die vorhandene Konfigurationssicherung; Kopie-Erkennung nur ueber die Node-Kennung) | |
| 12.1 | Zielablauf der Signal-Einrichtung | umgesetzt | `setup/page.lua`, `setup/wizard.lua` |
| 12.2 | Rolle vorbelegen, wenn nur eine installiert ist | offen | |
| 12.3 | Bereichsassistent (Vorlagen) | umgesetzt in der Leitstelle fuer gerade Strecken; Nebenanschluss, Verzweigung, freie Einrichtung offen | |
| 12.4 | schnelle Geraetezuordnung | umgesetzt (Tabelle, naechstes offenes Gleis, mehrere Signale je Gleis, "(neu)"); Name und Richtung direkt auf der Node bearbeiten: offen (nur in der Leitstelle) | |
| 13.1 bis 13.5 | Abschlusspruefung | umgesetzt fuer Signale (gemeinsame Bestaetigung, Schritt fuer Schritt, Abbruch, Marke und Wiederanlauf, Ergebnisse je Geraet, fremde Sperre unangetastet, Aktivierung nur bei Erfolg) | `src/setup/pruefung.lua` |
| 13.6 | Aussagegrenzen | in der Bedienung genannt | |
| 14 | Oberflaeche klein und gross | umgesetzt fuer die neuen Bildschirme (51x19 und 100x40 getestet) | |
| 15 | Verhalten bei Stoerungen | teilweise (Leitstelle nicht erreichbar: keine Kennung, Entwurf, "Von Hand" moeglich; fehlende Meldungen gelten nicht als frei) | |
| 16, 17 | Betriebsarten, Karten | nicht Teil der Einrichtung | |
| 18 | noch auszuarbeiten (Datenformat und Versionierung, gleichzeitige Aenderungen, Geraeteverantwortung, Pflichtprueflisten je Rolle, Uebernahme alter Konfigurationen) | offen | |

Grenzen dieses Standes:

- Welches Signal an welchem echten Gleis steht, liest der Computer nicht aus; die Zuordnung ist Handarbeit (Konzept 2).
- Bahnhof, Depot, Knoten und Anmeldung richten sich weiter ueber den bisherigen Assistenten ein.
- Eine bereits aktive Node bleibt im bisherigen Assistenten.
- Das Verzeichnis liegt nur in der Leitstelle (`/crn_data/netz.lua`); es hat keine eigene Sicherung ausser der atomaren Speicherung mit Vorgaengerfassung.
- Nachrichten sind unbeglaubigt (Rednet): die Leitstelle nimmt Anforderungen von jedem Sender in Funkreichweite an (hoechstens 500 Eintraege); die Node uebernimmt nur Antworten in der erlaubten Form.
