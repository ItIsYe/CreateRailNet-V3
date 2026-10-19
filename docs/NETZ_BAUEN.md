# Ein neues Netz bauen: Beschreibung, Plan, Bauliste

Ein Netz besteht aus Bahnhöfen, Strecken, Blöcken mit Signalen und Meldern, Weichen, Routen, Zügen und ihren Fahrplänen. Das von Hand in
`configs/network.json` zu schreiben ist mühsam und fehleranfällig. Stattdessen beschreibst du das Netz in wenigen Zeilen, und der Master macht
daraus den ganzen Plan und eine Bauliste:

    scripts/setup.lua --layout            (am Master)

## Schnellstart

1. Am Master (eingerichtet als Master): `scripts/setup.lua --layout`. Gibt es noch keine Beschreibung, bietet er ein Beispiel als `configs/layout.txt` an.
2. Beschreibung ändern: `edit configs/layout.txt` (Aufbau unten).
3. Noch einmal `scripts/setup.lua --layout`. Er nennt, was herauskommt (Bahnhöfe, Blöcke, Routen, Computer), und fragt:
   - **Bauliste schreiben?** (Standard Ja): `crn_bauliste.txt`, zum Lesen mit `edit crn_bauliste.txt`.
   - **Den Plan als configs/network.json speichern?** (Standard **Nein**): ersetzt den Plan ganz, die alte Datei bleibt als `.prev`.
4. Master neu starten (`reboot`).
5. Die Computer nach der Bauliste aufstellen und einrichten: Installer, Rolle wählen, im Assistenten **Kurzplan** und die **ID genau wie in der Liste**.
   Der Master kennt die ID schon aus diesem Plan, es muss nichts angenommen werden. Bahnhof und Depot holen sich am Ende ihre Bahnsteige
   (`scripts/setup.lua --fetch-plan`, `docs/INGAME_SETUP.md`).
6. Prüfen: an jedem Computer `scripts/setup.lua --doctor` und `--test`, am Master die Seite EINRICHTUNG.

Was du an der Beschreibung änderst, gilt nach einem neuen Lauf von `--layout`: der Plan wird jedes Mal ganz neu gebaut. Computer, die im alten Plan standen und im
neuen fehlen, nennt der Befehl mit ihrer ID, bevor du ja sagst. Kanal, ID und Monitor/Modem dieses Masters bleiben, wie sie waren.

## Die Beschreibung

Eine Angabe pro Zeile, `#` beginnt einen Kommentar, Namen mit Leerzeichen in Anführungszeichen. Nur einfache Zeichen (keine Umlaute: ae, oe, ue, ss).

| Zeile | Bedeutung |
|---|---|
| `netz Mein Netz` | Name des Netzes (nur für die Bauliste) |
| `kanal 777` | Funkkanal; ohne Angabe bleibt der Kanal des bisherigen Plans, sonst 777 |
| `master MASTER-1` | muss die ID dieses Masters sein; kann entfallen |
| `bahnhof ST-A "Station A" passenger 2` | Bahnhof mit Namen (der Name des Create-Bahnhofsblocks!), Typ `passenger`/`freight`/`mixed` (oder `personen`/`fracht`/`gemischt`) und Zahl der Bahnsteige (1 bis 6) |
| `depot DEPOT-1 "Depot 1" 2` | Depot mit 1 bis 6 Gleisen |
| `strecke ST-A ST-B 2 passenger` | Strecke von A nach B mit 2 Blöcken (1 bis 20) je Richtung; Art `passenger`/`freight`/`mixed`/`depot` (ohne Angabe nach den Enden); **in beide Richtungen** als zwei getrennte Gleise. `einrichtung` baut nur die Richtung A nach B |
| `zug TRAIN-1 "Regio 1" ST-A ST-B:2 ST-A pause=15` | Zug mit seinen Halten, `ST-B:2` = Bahnsteig 2, `pause=` Sekunden am Halt (Standard 10), `wiederholen` / `einmalig` (Standard: wiederholen, wenn der erste Halt der letzte ist) |
| `panel ja` | ob ein Panel-Computer gebaut wird (Standard ja) |
| `standard signal peripheral Create_Signal_0` | womit Signale / Melder / Weichen standardmäßig angebunden sind (`redstone <Seite>` oder `peripheral <Name>`); der Assistent des Computers fragt trotzdem nach |

Dasselbe als JSON-Datei (`scripts/setup.lua --layout netz.json`): `{"name": ..., "stations": [{"id", "name", "type", "platforms"}], "depots": [{"id", "name", "tracks"}],
"lines": [{"from", "to", "blocks", "kind", "oneway"}], "trains": [{"id", "name", "stops": ["ST-A", {"id": "ST-B", "platform": 2}], "dwell"}], "panel": true}`.

Fehler nennen die Zeile (`Zeile 7: ...`), alle auf einmal (höchstens 20 werden gezeigt). Ein Zug kann nur Strecken fahren, die es gibt, in der Richtung, die sie haben;
zwischen Halten ohne Strecke dazwischen nimmst du den Zwischenhalt mit auf.

## Was daraus wird

Das Modell ist das des Dispatchers (`docs/DISPATCHER_SAFETY.md`), nicht ein eigenes:

- **Gleis und Block.** Jede Richtung einer Strecke ist ein Gleis aus so vielen Blöcken, wie du angibst. Jeder Block hat ein Einfahrtsignal, ein Ausfahrtsignal und einen
  Melder (Train Observer), je auf einem eigenen Computer (`SIG-A-B-1-IN`, `SIG-A-B-1-OUT`, `SEN-A-B-1`; A und B sind die IDs ohne `ST-`).
- **Der Bahnsteig ist kein Block.** Der Zug wartet vor dem Einfahrtsignal des ersten Blocks der Strecke und ist angekommen, wenn er den letzten Block verlassen hat. Die Fahrten
  eines Zuges folgen deshalb Strecke für Strecke aufeinander, ohne dass eine Route die vorige blockiert.
- **Mehrere Bahnsteige.** Ein Bahnhof mit p Bahnsteigen bekommt je Bahnsteig einen Einfahrblock und einen Ausfahrblock und eine **Weichenleiter** aus p - 1 Weichen
  (`SW-B-ARR-1` ...): Weiche 1 steht geradeaus auf Bahnsteig 1, auf Abzweig führt sie zu den weiteren, Weiche 2 geradeaus auf Bahnsteig 2 und so fort. Die Stellungen trägt
  der Einfahrblock des Bahnsteigs; was der Zug fahren soll, entscheidet die Route.
- **Mehrere Strecken aus einem Bahnhof.** Die Weichenleiter der Ausfahrt (`SW-B-DEP-1` ...) wählt die Strecke; ihre Stellungen trägt der erste Block jeder Strecke.
- **Routen.** Für jedes Paar von Bahnsteigen entlang einer Strecke eine Route (`R-A-B`, bei mehreren Bahnsteigen `R-A.1-B.2`). Jede Route trägt die Konfliktgruppen ihrer Bahnsteige
  (`PLAT-ST-B-P2`): zwei Routen in oder aus demselben Bahnsteig schließen sich aus. Die Weichen sperrt der Dispatcher für die Dauer der Route.
- **Züge.** Jeder Zug bekommt einen Computer, einen Fahrplan (`SP-<ID>`) mit den Routen der gewählten Bahnsteige und einen Halt/Notstopp-Eintrag im Panel.

Wie viel das ist, sagt die Bauliste vorher. Faustregel: jeder Block braucht drei Computer (zwei Signale, ein Melder); ein kleines Netz mit zwei Bahnhöfen und einer Strecke
aus zwei Blöcken in beide Richtungen sind 12 Computer für die Strecke, dazu Master, Panel, Zug und die Bahnhöfe. Ein Bahnhof mit mehreren Bahnsteigen kostet je Bahnsteig zwei Blöcke.

## Die Bauliste

`crn_bauliste.txt` nennt: wie viele Computer, Modems, Signale, Melder und Weichen gebraucht werden; die **Namen der Create-Bahnhofsblöcke** (sie müssen genau so heißen, sonst findet der Zug
sein Ziel nicht); die Reihenfolge (Master, Strecke Block für Block, Weichen, Bahnhöfe und Depots, Züge); wie jeder Computer eingerichtet wird; und je Computer ID, Rolle, was daran steht
und wo (Strecke, Block, Einfahrt/Ausfahrt, Stufe der Weichenleiter). Die Zeilen sind höchstens 50 Zeichen lang, sie passen auf den Bildschirm eines Computers.

## Grenzen (ehrlich)

- **Eingleisige Strecken in beide Richtungen kennt das Modell nicht.** Signal und Melder gehören zu einem Block in einer Richtung; zwei Richtungen auf einem Gleis hätten dieselben Melder in
  zwei Blöcken. Zwei Gleise (Standard) oder eine Richtung (`einrichtung`).
- **Der Platz am Bahnsteig ist keine Sperre.** Geschützt sind Routen und Blöcke; steht ein Zug im Bahnsteig, nachdem seine Route zu Ende ist, hält den Platz nur das Create-Signal am
  Bahnhofseingang (`docs/STATION_DEPOT_TRACK_LOGIC.md`: Bahnsteig-Belegung durch Melder ist noch offen).
- **Zwischen denselben zwei Bahnhöfen** warten Züge in Gegenrichtung aufeinander, auch auf getrennten Gleisen (die bestehende Regel `opp:` des Dispatchers).
- **Nicht erzeugt:** Flankenschutz und Durchrutschweg (`interlocking_routes`), Plätze im Gleisbild (`gleisbild_pos`), Melder an den Bahnsteigen, mehrere Master.
- Der Plan darf höchstens 150 000 Byte groß sein (die Computer holen ihn in Teilen), und eine erzeugte ID höchstens 32 Zeichen lang: bei langen Bahnhof-IDs sagt der Befehl, wie er kürzen will.
- **Geprüft ist das offline gegen den echten Dispatcher:** jede erzeugte Route wird reserviert und Block für Block mit Melderereignissen abgefahren (Weichenstellungen, Signale), Fahrpläne laufen Runde um Runde,
  Gegenzüge und Züge zum selben Bahnsteig schließen sich aus, und zufälliger Verkehr hält alle Sicherheitsinvarianten ein und endet mit leerer Warteschlange. **Ob die Gleise im Spiel zu diesem Modell
  passen** (Stellung `geradeaus` / `Abzweig` an deiner Weiche, Lage der Signale), zeigt nur der Aufbau: `docs/INGAME_TESTS.md` 0bb bis 0bh.
