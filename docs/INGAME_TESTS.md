# Spieltests (was sich offline nicht prüfen lässt)

Die Tests in `tests/` laufen ohne Minecraft. Sie beweisen die Logik (Reservierung, Stellwerk, Wiederanlauf, Updates, Netz), aber nicht, wie sich
Create und CC:Tweaked in der echten Welt verhalten. Diese Liste ist dafür da: einmal in einer **Testwelt oder auf einem abgesperrten Stück
Strecke** durchgehen, die Ergebnisse in die letzte Spalte schreiben. Wo etwas anders kommt als erwartet, steht in der Zeile, was das bedeutet.

Vorbereitung: Backup der Welt, ein kleines Netz (Master, 2 Signale, 2 Sensoren, 1 Weiche, 1 Zug, 1 Panel-Monitor), `scripts/setup.lua --check`
ohne Fehler, `docs/INGAME_SETUP.md` durchgearbeitet.

## 0. Installer (`docs/INSTALL.md`)

Der Installer ist offline gegen ein simuliertes GitHub getestet (inklusive Absturz bei jeder Dateioperation). Ob HTTP, Dateisystem und `require` im Spiel
genauso arbeiten, zeigt nur der Versuch. Auf einem **frischen** Computer, dann auf einem zweiten mit kleinem Speicher:

| # | Versuch | Erwartet | Wenn anders | Ergebnis |
|---|---|---|---|---|
| 0a | `wget run https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/<zweig>/installer --ref <zweig>` | Menü, Fortschritt, am Ende der Einrichtungs-Assistent | „HTTP ist nicht verfuegbar": `computercraft-server.toml` (http, Domain freigeben); anderer Fehler: Text notieren | |
| 0b | im Assistenten weitermachen (alles mit Enter) | läuft ohne „module not found" / „startup_template.lua is missing" durch, schreibt `startup.lua`, startet neu in die Rolle | „module not found": `require` löst Pfade aus `/scripts` anders auf als vermutet → melden, Wortlaut notieren | |
| 0c | `installer` (oder `installer --yes`) gleich noch einmal | lädt nur das Manifest, „Alle Dateien sind auf dem Stand …", Neustart in 2 s; dauert wenige Sekunden | lädt Dateien erneut: Größe/Prüfsumme weichen ab (Zeilenenden? `git config core.autocrlf`) → melden | |
| 0d | `fs.getFreeSpace("/")` vor und nach einer Master- und einer Node-Installation (Lua-Prompt) | Master laufend ca. 557 KB (mit Einrichtungs-Dateien ca. 717 KB), Panel/Flotte ca. 280/270 KB, übrige Nodes ca. 210-230 KB belegt (jede Datei zählt mind. 500 Byte), Standardspeicher (1 MB) reicht und es bleiben mind. 100 KB frei | reicht nicht: Meldung nennt, wie viel fehlt; die Zahlen aus `docs/assumptions.md` (Space budget) mit der Messung vergleichen | |
| 0d3 | Neuer Computer: Installer bis zum Ende; danach `fs.exists("src/setup/wizard.lua")` | beim Neustart des Assistenten sind die Einrichtungs-Dateien weg (`installer --slim` lief davor), `fs.getFreeSpace` entspricht der Zeile „laufend“ | Dateien bleiben liegen: `installer --slim` von Hand, Meldung notieren | |
| 0d4 | `scripts/setup.lua --doctor` auf einem laufenden Computer ohne Einrichtungs-Dateien | „Einrichtungs-Dateien … werden geladen“, Doctor läuft, danach sind sie wieder weg; ohne http oder `installer` steht, was zu tun ist | bricht ab: Meldung notieren (Stand des Servers weicht vom installierten ab? dann erst `installer`) | |
| 0d5 | Master: `scripts/setup.lua --layout` und `scripts/keys.lua issue <id>` im laufenden Betrieb | Werkzeug wird geladen, läuft, und der Master hat danach wieder 100 KB frei; der Betrieb (Signale, Heartbeats) wird nicht gestört | Ausfälle während des Ladens: Zeitpunkt notieren | |
| 0d2 | Fehlermeldung eines installierten Moduls ansehen (z. B. absichtlich falsche Konfiguration starten) | die Zeilennummer in „datei.lua:123“ ist die Zeile im Repository (verkleinerte Dateien behalten ihre Zeilen) | andere Zeile: `lua scripts/build_dist.lua --check` | |
| 0e | Computer mit zu wenig Platz (große Füll-Datei anlegen; das Limit von 1 MB bleibt) | „Der Speicher dieses Computers reicht nicht …", Platte unverändert | Platte verändert: Abbruch-Zeitpunkt notieren | |
| 0f | Strom aus / Chunk entladen während „Dateien werden geladen" | beim nächsten Start „Installation unvollstaendig." und `installer --resume` läuft von selbst bis zum Neustart | Computer bleibt in der Shell: `installer --resume --role <rolle>` | |
| 0g | eigene Konfiguration (`configs/templates/network.full.example.json`) ändern, `installer` erneut | Datei bleibt unverändert; eine gelöschte `scripts/start_*.lua` kommt zurück | Datei überschrieben: melden (Seed-Liste im Manifest) | |
| 0h | `installer --role signal` auf einem Sensor-Computer | alte Sensor-Dateien weg, Assistent richtet die Signal-Rolle ein | | |
| 0i | direkt nach einem Push auf den Zweig installieren | evtl. „… checksum of …" und Wiederholung mit Wartezeit (CDN-Cache), dann Erfolg | dauerhaft Prüfsummenfehler: `lua scripts/manifest_sync.lua --check` im Repository | |

### 0.1 Einrichtungs-Assistent (`docs/INGAME_SETUP.md`)

Der Assistent ist offline mit einem simulierten Computer getestet (jede Rolle, alle Plan-Wege, zurück, Hilfe, Abbruch, Bildschirm 51 x 19, nur ASCII).
Wie die Seiten auf einem **echten** Terminal aussehen, zeigt nur der Versuch. Auf einem frischen Computer je Rolle, dazu einmal auf einem
Computer ohne Modem und einmal auf einem Pocket-/Mini-Terminal, falls ihr eins benutzt:

| # | Versuch | Erwartet | Wenn anders | Ergebnis |
|---|---|---|---|---|
| 0j | `scripts/setup.lua` auf dem Master: Beispiel kopieren, alles mit Enter | jede Seite passt ohne Scrollen auf den Bildschirm, keine Sonderzeichen/Kästchen, Kopfzeile zeigt den Schritt | Seite läuft über oder Zeichen kaputt: Bildschirmgröße (`term.getSize()`) und Seite notieren | |
| 0k | `?` auf jeder Frage, danach Enter | Hilfe auf eigener Seite, danach dieselbe Frage wieder, nichts doppelt | Frage fehlt oder erscheint zweimal: Frage notieren | |
| 0l | `<` mehrfach, auch auf der ersten Frage | geht Schritt für Schritt zurück, Antworten bleiben als Vorschlag, auf der ersten Frage kommt „Einrichtung abbrechen?" | | |
| 0m | Signal-Computer mit Create-Signal: Kurzplan | Gerät wird erkannt (Name aus der Liste), Zusammenfassung nennt „Create_Signal_0 (gefunden)", Abschlussseite zeigt die Zeile für den Netzplan des Masters | Gerät nicht erkannt: Typ mit `peripheral.getType` notieren (Erkennung in `src/setup/hardware.lua`) | |
| 0n | die Zeile von Hand in `nodes` des Masters eintragen (der Weg ohne Pairing), `scripts/setup.lua --check` | „in Ordnung" | Fehlerliste: Pfad und Text notieren | |
| 0o | Computer ohne Modem | deutliche Warnung, Weitermachen möglich, Zusammenfassung nennt „Modem FEHLT" | | |
| 0p | Assistent bis zur Zusammenfassung, dann `A` | „Abgebrochen. Es wurde nichts geaendert.", kein `startup.lua`, keine `configs/network.json` | Datei angelegt: melden | |
| 0q | Strg+T mitten in einer Frage | Shell, nichts geschrieben | | |
| 0r | Assistent auf einem schon eingerichteten Computer | fragt zuerst „Neu einrichten?"; Nein ändert nichts | | |

### 0.2 Prüfung, Geräte-Bindung und Aufnahme am Master (`docs/INGAME_SETUP.md`)

Doctor, Verbindungstest, Pairing und die Master-Seite „Einrichtung" sind offline gegen simulierte Computer und ein simuliertes Netz getestet (Zustände, Grenzen,
böswillige Eingaben, Absturz beim Schreiben des Plans). Was nur das Spiel zeigt: wie echte Peripherie heißt, wie sich Modems verhalten und wie die Seite auf einem
echten Monitor aussieht. Master mit Netzplan und mindestens zwei weitere Computer (einer davon noch nicht im Plan), alle mit Modem:

| # | Versuch | Erwartet | Wenn anders | Ergebnis |
|---|---|---|---|---|
| 0s | `scripts/setup.lua --doctor` auf einem eingerichteten Computer | eine Zeile je Punkt (`[ OK ]`), Modem und Monitor mit dem Namen, den `peripherals` bzw. `peripheral.getNames()` im Spiel liefert | Name weicht ab oder Gerät fehlt in der Liste: Typ mit `peripheral.getType(name)` und Wortlaut notieren (Erkennung in `src/setup/hardware.lua`, `src/adapter/monitors.lua`) | |
| 0t | Master mit Monitor an der Seite und einem zweiten Monitor am Kabel; Feld `monitor` im Eintrag auf den zweiten setzen, Master neu starten | Anzeige erscheint auf dem genannten Monitor; ein falscher Name zeigt auf dem ersten Monitor an und steht einmal im Log | Anzeige bleibt leer: Namen aus `peripheral.getNames()` und Log notieren | |
| 0u | Computer mit zwei Modems (Funk und Kabel); Assistent wählt eines, danach das gewählte abbauen | Doctor: `Modem ... nicht gefunden`; der Computer funkt **nicht** über das andere Modem | er funkt über das andere: melden (`src/adapter/cc_modem.lua`) | |
| 0v | neuer Computer (nicht im Plan), Assistent bis zum Verbindungstest, Master läuft | Doctor/Verbindungstest: `[WARN] Master kennt <id> noch nicht`; nach spätestens 20 s steht der Computer auf der Master-Seite *Einrichtung*, gelbe Meldung „Neuer Computer wartet" | nichts erscheint: gleicher Kanal? Master schon auf diesem Stand (Revision 3)? Wortlaut des Tests notieren | |
| 0w | auf der Master-Seite die Zeile antippen, **[ANNEHMEN]** zweimal | beim ersten Tippen wird der Knopf zu `[SICHER?]` (gilt 8 s), beim zweiten „... ist im Netzplan eingetragen"; `configs/network.json` enthält den Eintrag, `configs/network.json.prev` die alte Fassung; der Computer loggt `pairing: known` | Eintrag fehlt oder Datei beschädigt: beide Dateien aufheben und melden | |
| 0x | zweiten neuen Computer **[ABLEHNEN]** | verschwindet, meldet sich 10 Minuten lang nicht erneut auf der Seite | taucht sofort wieder auf: melden | |
| 0y | Computer mit einer ID, die im Plan mit anderer Rolle steht | Zeile in Rot, **[ANNEHMEN]** wird verweigert mit Hinweis | | |
| 0z | Master mit mitgelieferter Vorlage (`configs/templates/...`) als Plan, Computer annehmen | Ablehnung mit dem Hinweis, einen eigenen Plan anzulegen; nichts verändert | Datei verändert: melden | |
| 0aa | Seite *Einrichtung* auf Monitoren verschiedener Größe (2x1, 3x2, 4x3), Liste mit mehr Computern als Zeilen | alle Zeilen und beide Knöpfe erreichbar, nichts läuft über den Rand, Wörter OK / OFFEN / FEHLER auch auf einem Schwarzweiß-Monitor lesbar | Layout kaputt: Größe und Foto/Beschreibung notieren | |
| 0ab | Station-Computer mit Kurzplan: `--doctor` | Hinweis „Bahnhof ohne Bahnsteige" mit dem Weg (Plan beim Master eintragen, `scripts/setup.lua --fetch-plan`) | | |
| 0ac | Installer auf einem echten Terminal und auf einem Pocket-Computer | der Fortschritt ist **eine** Zeile, die sich überschreibt; Zeilen umbrechen an Wortgrenzen; Fehler rot, Hinweise gelb | Zeilen springen oder doppeln sich: Terminalgröße und Verhalten notieren (`install/ui.lua`) | |
| 0ad | `print(string.char(228, 246, 252, 223))` am Terminal und auf einem Monitor | zeigt ä ö ü ß, dann könnten Texte später Umlaute bekommen (derzeit steht alles in ASCII: ae oe ue ss) | andere Zeichen: ASCII beibehalten | |
| 0ae | ein Computer, der **nicht** im Plan steht, als Panel eingerichtet (Rolle `panel`), versucht am Panel einen Bedienbefehl (zum Beispiel Not-Halt) | der Master ignoriert ihn; der Computer steht auf der Seite EINRICHTUNG; im Audit `event_rejected`, keine Wirkung auf Züge oder Signale | der Befehl wirkt: sofort melden, Protokoll (Audit) aufheben | |
| 0af | denselben Computer annehmen (zwei Berührungen), Master neu starten, dann dieselbe Aktion | die Meldung nach dem Annehmen nennt den Neustart; nach dem Neustart steht der Computer im Plan und das Panel funktioniert | Panel bleibt wirkungslos: `configs/network.json` und Rolle des Eintrags prüfen | |
| 0ag | auf einem laufenden Node mehrmals `scripts/setup.lua --doctor` nacheinander (Master unverändert) | jedes Mal dieselbe Zeile zum Master (`antwortet und kennt ...` oder `kennt ... noch nicht`), nie „aelterer Stand" | „aelterer Stand" erscheint beim zweiten Aufruf: melden | |
| 0ah | im Plan des Masters dem Bahnhof zwei Bahnsteige geben (`platforms`), Master neu starten, auf dem Bahnhof-Computer `scripts/setup.lua --fetch-plan`, Ja | der Computer meldet „Uebertragung: N Teil(e)", zeigt Computer/Blöcke/Routen und „2 Bahnsteig(e)", schreibt `configs/network.json` (alte Datei als `.prev`), nach `reboot` startet die Station mit ihren Bahnsteigen | „Master antwortet nicht": Kanal, Modem, Master auf dem Stand mit `plan_get`; Teile gehen verloren: Reichweite (Funkmodem?) notieren | |
| 0ai | dasselbe mit einem großen Plan (viele Blöcke, über 20 KB) und mit einem Funkmodem am Rand der Reichweite | die Übertragung gelingt (fehlende Teile werden neu angefragt) oder scheitert mit „Master antwortet nicht"; **nie** ein halber Plan auf der Platte | halber Plan auf der Platte: sofort melden, beide Dateien (`configs/network.json`, `.prev`) aufheben | |
| 0aj | Plan am Master während des Holens speichern (zweiter Computer, `edit`) | der Computer holt von vorn („hat sich geaendert") und bekommt die neue Fassung, oder meldet es | alte und neue Teile gemischt: melden | |
| 0ak | `--fetch-plan` auf einem Computer, der am Master **nicht** angenommen ist, und auf einem Signal-Computer | „Der Master kennt diesen Computer noch nicht ..." bzw. „Nur Bahnhof- und Depot-Computer ..."; nichts geschrieben | | |
| 0al | auf einem Signal-Computer mit Redstone-Anschluss `scripts/setup.lua --test`, erst „Funktionstest starten?" Ja, beim Signal **Enter allein** | der Test zeigt vorher `[liest]` / `[zeigt]` / `[SCHALTET]`; Enter schaltet nichts (das Signal bleibt, wie es war) | das Signal wurde geschaltet: sofort melden | |
| 0am | derselbe Test, beim Signal `j`, ein Zug **nicht** in der Nähe | das Signal wird 3 s freigegeben (Redstone-Ausgang an bzw. Create-Signal nicht mehr erzwungen rot) und steht danach wieder auf **ROT**; Ergebnis „bestanden", Master zeigt später „Hardwaretest" | Signal bleibt grün/offen: von Hand zurückstellen, Ausgabe notieren | |
| 0an | dasselbe mit einem echten Create-Signal (`Create_Signal`-Peripherie) und mit einer Weiche (Redstone) | das Create-Signal wechselt wirklich und fällt zurück; die Weiche geht auf Abzweig und zurück auf geradeaus | Create-Signal reagiert nicht: Peripheriename und Methoden (`peripherals`) notieren | |
| 0ao | Test mit Strg+T mitten in den 3 Sekunden beenden | das Signal ist danach ROT (bzw. die Weiche geradeaus) | Signal offen geblieben: melden | |
| 0ap | `--test` auf einem Melder, während ein Zug den Train Observer passiert | „der Wert hat gewechselt"; ohne Zug „Wert blieb gleich" (kein Fehler) | „nicht lesbar": Peripherie und Methoden notieren | |
| 0aq | `--test` auf Monitor-Rollen (Master/Panel/Bahnhof) | die Zeile „CreateRailNet Funktionstest" steht oben auf dem Monitor; Nein führt zu „Text nicht zu sehen" und zu einem Fehler im Ergebnis | Monitor leer, obwohl die Frage mit Ja beantwortet wird: Größe, Textskalierung notieren | |
| 0ar | `scripts/setup.lua --linktest` mit Funkmodem nahe am Master, dann am Rand der Reichweite, dann mit Kabelmodem | nah: „10 beantwortet, 10 sofort", 4000 Byte kommen an; am Rand: Verluste und/oder kleinere größte Nachricht; Kabelmodem: wie nah | **Modem lässt sich nicht öffnen oder senden**: Fehlermeldung notieren (der Adapter wurde bisher nur offline gegen ein streng prüfendes Modem getestet) | |
| 0as | `--linktest`, während der Master aus ist | nach drei Fragen „Keine Antwort vom Master" mit den Hinweisen | | |
| 0at | `--linktest`, danach `--fetch-plan` mit einem großen Plan (über 20 KB) | beide sagen dasselbe: kommt 3300 Byte durch, gelingt der Abruf | `--linktest` ok, aber `--fetch-plan` scheitert: Teilgröße (3000 Byte) zu groß für die Strecke, melden | |
| 0au | `scripts/setup.lua --export`, danach `pastebin put crn_diag.txt` bzw. die Datei öffnen (`edit crn_diag.txt`) | Datei unter 8000 Byte, lesbar, Gerätenamen wie in `peripherals`, keine Umlaute-Fragezeichen außer in echten Namen | Namen fehlen/falsch: Beispiel notieren | |
| 0av | Master: Computer annehmen, dann **[MASTER NEU STARTEN]** (erste Berührung liest die Folgen, zweite löst aus) | Signale gehen auf ROT, der Master startet neu, wartet im Wiederanlauf; nach `confirm_recovery` läuft alles weiter; im Audit `master_restart` | Master startet nicht neu: Log, `state/master_state.json` | |
| 0aw | Plan mit `"require_release": true`, Master starten, Zug will abfahren | Zug wird gehalten („Betrieb nicht freigegeben"), Statusseite zeigt NICHT_FREIGEGEBEN; **[BETRIEB FREIGEBEN]** geht erst, wenn alle Signal-/Melder-/Weichen-/Bahnhof-/Depot-Computer online und kein Block gestört ist (sonst nennt die Meldung, was fehlt); danach fährt der Zug | Zug fährt ohne Freigabe: sofort melden | |
| 0ax | `installer --preview --ref <zweig>` auf einem eingerichteten Computer, danach `installer --ref <zweig>` | die Vorschau nennt neu/geändert/entfernt und ändert nichts (`list` der Dateien vorher und nachher gleich); der echte Lauf tut genau das | Vorschau weicht ab: beide Ausgaben notieren | |
| 0ay | Installer mit `main` und mit einem Tag (`--ref v0.0.1`, falls vorhanden) | bei `main` die Branch-Warnung, bei dem Tag keine | | |
| 0az | `lua scripts/ota_push.lua --role signal --limit 1 --dry-run`, dann ohne `--dry-run` | die Vorschau nennt genau einen Signal-Computer; nur der bekommt die Aktualisierung | alle Signal-Computer wurden aktualisiert: melden | |
| 0ba | Monitore der Größen 1x1, 2x1, 3x2, 4x3 als Master-Monitor, jeweils ohne und mit `"monitor_scale": 0.5` im Eintrag des Masters (Neustart) | `--doctor` meldet unter 51x19 Zeichen den Hinweis mit `monitor_scale`; mit 0,5 hat der Monitor etwa doppelt so viele Zeichen (3x2 Blöcke: rund 58x24), alle Seiten lesbar, Knöpfe erreichbar; kleine Monitore bleiben ein Kompromiss (`docs/assumptions.md`) | Seite abgeschnitten, Knöpfe nicht erreichbar: Größe und Skalierung notieren | |
| 0bb | kleinstes Netz nach `docs/NETZ_BAUEN.md`: zwei Bahnhöfe, eine Strecke mit einem Block, ein Zug; `scripts/setup.lua --layout`, Bauliste lesen, alles aufstellen | alle Computer melden sich (Seite EINRICHTUNG: alle online, keiner „wartet"); der Zug fährt A → B → A nach seinem Fahrplan, die Signale wechseln mit der Fahrt, am Ende stehen alle auf ROT | ein Computer wartet auf Annahme: ID anders geschrieben als in der Liste | |
| 0bc | Bahnhof mit zwei Bahnsteigen (`bahnhof ST-B "B" passenger 2`), Zug mit `ST-B:1` und `ST-B:2` im Wechsel | die Einfahrweiche (`SW-B-ARR-1`) steht für Bahnsteig 1 auf geradeaus, für Bahnsteig 2 auf Abzweig, der Zug fährt auf das richtige Gleis | Weiche steht umgekehrt: Stellung `STRAIGHT`/`DIVERGING` gegen die echte Weiche prüfen (Feld `invert` / `active_position` am Weichen-Eintrag), Foto und Aufbau notieren | |
| 0bd | zwei Züge für denselben Bahnsteig gleichzeitig | der zweite wartet, bis die Route des ersten zu Ende ist; **dann** steht der erste noch im Bahnsteig: ob der zweite davor am Einfahrtsignal hält, hängt am Create-Signal (bekannte Grenze, `docs/NETZ_BAUEN.md`) | zweiter Zug fährt in den belegten Bahnsteig: Aufbau und Create-Signal notieren | |
| 0be | zwei Züge in Gegenrichtung zwischen denselben Bahnhöfen | der zweite wartet (Regel `opp:`), beide kommen nacheinander an | beide fahren gleichzeitig: sofort melden | |
| 0bf | `scripts/setup.lua --layout` mit Fehlern in `configs/layout.txt` (Tippfehler im Wort, unbekannter Bahnhof, Bahnsteig 3 bei einem Bahnsteig) | jede Zeile mit Fehler wird mit Zeilennummer genannt, nichts wird geschrieben | | |
| 0bg | Beschreibung ändern (einen Block mehr), `--layout` noch einmal, Plan speichern, Master neu starten | der Befehl nennt die Computer, die im alten Plan standen und jetzt fehlen; die neuen Blöcke gelten nach dem Neustart; die alte Datei liegt als `.prev` | | |
| 0bh | `crn_bauliste.txt` mit `edit` auf einem Computer lesen | alle Zeilen passen auf den Bildschirm, ID/Rolle/Ort jedes Computers sind zu finden | Zeilen laufen über: Bildschirmgröße notieren | |
| 0bi | `scripts/keys.lua init` am Master, `issue SIG-1` mit Diskette im Laufwerk, am Signal-Computer `install --id SIG-1` | Diskettendatei `crn_key_SIG-1.json` entsteht, die Prüfsumme am Signal-Computer ist dieselbe wie am Master | `getMountPath` des Laufwerks liefert etwas anderes als `disk` (z.B. `disk2`): Wortlaut melden, die Suche in `keystore.drive_mounts` anpassen | |
| 0bj | `auth_mode` auf `enforce` am Master und an allen Computern; Betrieb mit allen Nodes, Verzögerung beobachten (`--linktest`, Block-Meldungen) | alles läuft wie vorher, Master-Log ohne `auth_failed`; die Zeit für Prüfcode und Sitzung ist nicht spürbar (Heartbeats kommen alle 2 s); `scripts/auth_bench.lua` nennt als Bit-Operationen `bit32` (steht dort `arith`, gibt es `bit32` im Spiel nicht und alles ist sehr langsam: melden) | zu langsam bei vielen Nodes: Zeit pro Nachricht (`os.clock` vor/nach `net.receive`) und Anzahl Nodes notieren → `scripts/auth_bench.lua` am Master laufen lassen, die Zahlen notieren; das Prüfbudget (400 Prüfungen je Sekunde, `src/shared/auth.lua`) danach anpassen | |
| 0bk | Fremden Computer (nicht im Plan, kein Schlüssel) mit Modem auf den Kanal setzen und `pair_announce` / `register` / `cmd` senden (Lua-Prompt) | nur die Meldung des Kandidaten erscheint auf der Einrichtungsseite; kein Register, keine Befehle | Nachricht wirkt: Wortlaut und Modus (`auth_mode`) melden | |
| 0bl | `scripts/keys.lua revoke SIG-1`, kurz warten, Signal-Computer neu starten | der Master meldet SIG-1 als nicht erreichbar (Heartbeat-Timeout), seine Nachrichten werden nicht gehört; `issue` + `install` bringt ihn zurück | bleibt hörbar: die Liste wurde nicht übernommen (`state/crn_trust.json`, Master-Log) | |
| 0bm | Master mitten im Betrieb neu starten (`reboot`), Nodes laufen weiter | Nodes werden nach kurzer Zeit wieder gehört (Sitzung läuft neu an), keine Doppelausführung von Befehlen | Nodes bleiben stumm: Master-Log ansehen (`challenge`), Nodes neu starten | |
| 0bn | `scripts/ota_push.lua` im Modus `enforce` | der Versuch erreicht keinen Computer (bekannte Grenze bis Paket P9), im Modus `monitor` funktioniert er | | |
| 0bo | Zug-Computer: Master schickt `set_schedule`, Zug-Computer wird während der Übergabe neu gestartet (Strg+R), der Master wiederholt den Befehl | der Fahrplan wird **nicht** ein zweites Mal gesetzt (Create-Fahrplan des Zugs prüfen), der Master bekommt seine Antwort; war der Neustart zwischen Eintrag und Ausführung: Antwort „uncertain after restart“ und Meldung im Log | Fahrplan doppelt gesetzt: `state/node_commands.log` des Zug-Computers sichern und melden | |
| 0bp | `state/node_commands.log` im Betrieb ansehen (`edit`), danach 600 Befehle (Prüfskript oder Dauerbetrieb) | die Datei bleibt klein (unter etwa 40 KB), `.snap` und `.snap.prev` liegen daneben | wächst weiter: Größe und Zeitpunkt melden | |
| 0bq | Platte fast voll machen (Füll-Datei anlegen), dann einen Fahrplan-Befehl senden | der Zug-Computer lehnt den Befehl mit „no durable record, command refused“ ab und fährt nichts los; nach Platz schaffen und `reboot` geht es wieder | der Befehl wirkt trotzdem: Wortlaut des Fehlers von `fs.open` (Modus `a`) melden | |
| 0br | `fs.open(pfad, "a")` im Spiel: schreiben, schließen, noch einmal öffnen und anhängen (Lua-Prompt) | der Text steht hintereinander in der Datei | Datei wird ersetzt: das Journal ist dann nicht dauerhaft, melden | |
| 0bs | Zwei Master und ein Schiedsrichter nach `docs/HA.md` einrichten (`masters`, `arbiter` im Netzplan, Master B mit `--id MASTER-B`), alle starten | nach etwa 10 bis 15 s führt Master A (Meldung „Dieser Master fuehrt jetzt“ auf A, nicht auf B); B zeigt die Anlage, sendet aber nichts | beide führen oder keiner: Logs beider Master und des Schiedsrichters (`election`) sichern, Kanal/Reichweite prüfen | |
| 0bt | Master A ausschalten (Computer aus), Zug fährt gerade | B führt nach höchstens 20 s; bestehende Fahrt bleibt geschützt, der Zug hält oder fährt weiter ohne doppelte Befehle | B führt nicht: Schiedsrichter erreichbar? Log `vote_reply` | |
| 0bu | A wieder einschalten, während B führt | A führt nicht (Anzeige „fuehrt nicht“), B bleibt Führender, keine Doppelführung | A übernimmt sofort: Perioden in `state/election.json` beider Master notieren | |
| 0bv | Verbindung zwischen A und B trennen (z.B. A hinter einen anderen Kanal / außer Reichweite), Schiedsrichter bleibt erreichbar | genau ein Master führt (A, wenn er den Schiedsrichter erreicht); nach dem Wiederverbinden keine Störung | zwei Führende: Zeitpunkt und Logs melden (Pacht reicht nicht) | |
| 0bw | Alter Führender sendet einen Befehl (E-10): am ehemaligen Führenden im Lua-Prompt einen Befehl mit alter Periode an ein Signal schicken (`network.send("cmd", "SIG-1", {cmd="set_aspect", aspect="GREEN", election_epoch=1, election_leader="MASTER-A"})`) | das Signal lehnt ab, Log „command refused by the epoch check“, Signal unverändert | Signal schaltet: Version und Wortlaut melden | |
| 0ca | `occupancy_proof = on`, Master neu starten, Strecke leer | alle Blöcke `UNKNOWN`; nach etwa 2 bis 10 s melden Blöcke mit Sensoren `FREE_PROVEN`; Blöcke ohne Sensor bleiben `UNKNOWN`; vorher wird keine Route vergeben | Block bleibt `UNKNOWN`: Sensorpegel (Heartbeat) prüfen |  |
| 0cb | Sicheren Wartepunkt mit einem langen Zug anfahren, Haltetest wiederholen (Richtung, Zuglänge, Signalaufbau) | Zug steht komplett vor dem geschützten Bereich; erst dann `proven = true` setzen | Zug ragt in den Bereich: Länge (`length`) kleiner eintragen oder anderen Punkt wählen |  |
| 0cc | Zug aus einem Block fahren, dessen Endsensor weiter vorn liegt | Block bleibt belegt, bis der letzte Wagen den Endsensor passiert; kein Folgezug bekommt den Block früher | Block früher frei: `tail_sensors` zu weit vorn |  |
| 0cd | Zwei Züge auf Gegengleisen stehen und fordern gegenseitig ihre Blöcke an | Verklemmung wird gemeldet, keine Reservierung wird entzogen, nach Bewegung eines Zuges löst sich die Meldung | Meldung bleibt: Zyklus in `get_deadlocks()` ansehen |  |
| 0ce | Signal-Node mit 4, dann 6, dann 8 Signalen: jedes Signal mit `scripts/bind_signals.lua bind` einzeln binden, danach vom Master nacheinander jede ID auf Gruen und Rot stellen | jede ID schaltet genau das gebundene Signal; beim Binden geht nur das gesuchte Signal auf Rot | falsches Signal rot: Bindung loeschen (`unbind`) und neu binden |  |
| 0cf | Modem an der Signal-Node umstecken (Geraetenamen aendern sich), Node neu starten, `check` | Abweichung wird gemeldet, nichts umgebunden, die betroffenen Signale bleiben Rot und die Bloecke sind ausser Betrieb | Signal schaltet doch: Bindung pruefen |  |
| 0cg | `getSignalType`, `isForcedRed`, `listBlockingTrainNames` an einem echten Create-Signal in ATM10 8.1 aufrufen | Methoden und Rueckgaben notieren; was fehlt, bleibt "nicht verfuegbar" in `docs/CREATE_HARDWARE_ADAPTERS.md` | Methode fehlt: Bindungsfeld `ptype` entsprechend waehlen |  |
| 0ch | Signal-Node ausschalten (Chunk entladen) waehrend ein Signal Rot erzwungen war | Beobachten, ob das Create-Signal Rot behaelt oder auf Normalverhalten zurueckfaellt (R-01); Ergebnis eintragen | Signal faellt zurueck: Strecke physisch absichern oder Bereich von der Automatik ausnehmen |  |
| 0ci | Eine Linie mit Flottenpaar (zwei Computer) und einem Zug, Abfahrt in zwei Minuten; Zug steht im Startbahnhof | Auftrag entsteht, Fahrstrasse wird beim Master reserviert, erst nach der Bestaetigung beider Master wird der Fahrplan genau einmal uebergeben; Zug faehrt los; Abfahrt, Position und Ankunft erscheinen, am Ende `COMPLETE` | Zug faehrt nicht: Create-Station und `setSchedule` pruefen (`docs/CREATE_SCHEDULE_ADAPTER.md`) |  |
| 0cj | Waehrend der Fahrt den Partner der Flotte ausschalten; danach einen weiteren Auftrag zulassen | die laufende Fahrt wird zu Ende gefuehrt; neue automatische Auftraege dieses Paares werden nicht gestartet, andere Paare arbeiten | Neuer Auftrag startet doch: `pair_timeout_s` und Pruefsumme pruefen |  |
| 0ck | Flotten-Node der aktiven Seite hart ausschalten, nachdem der Fahrplan uebergeben wurde, und neu starten | dieselbe Fahrt geht weiter, der Fahrplan wird nicht noch einmal uebergeben; ein unklarer Ausgang zeigt UNCERTAIN und fragt den Master nach dem Zustand | Fahrplan wurde zweimal uebergeben: Journal der Flotte und `apply_schedule`-Befehls-ID pruefen |  |
| 0cl | Alle Zielgleise belegen, dann einen Zug zum Bahnhof schicken | der Zug wartet an einem sicheren Wartepunkt vor dem Bahnhof, kein Gleis ausserhalb des Plans wird belegt | Zug steht an falscher Stelle: Wartepunkte (`safe_stops`) und Haltetest pruefen |  |
| 0cm | Eine Gueterfahrt mit Mindestladung 600 von 1000, geladen 700, angekommen 650 | Anzeige: geliefert 650, offen 350, unklar 50 (nie 700 geliefert); Zeitablauf alleine verbucht keine Ware | falsche Zahlen: Quelle der Mengenmeldung und Qualitaetsstufe pruefen |  |
| 0cn | Panel mit `permission = "view"` beruehren auf der Seite Manuell | keine Aktion, Meldung im Log; am Master Audit `panel_denied` | Rechte im Plan und am Master pruefen |  |
| 0co | Panel mit `operate`: Freigabe eines Zuges antippen | erster Tipp sendet nichts, zweiter Tipp innerhalb 10 s wird am Master als `panel_denied` abgelehnt (Stufe admin noetig) | Stufen und `confirm` pruefen |  |
| 0cp | Master abschalten, Panel 15 s beobachten, Master wieder starten | Panel sendet in der Zeit keine Aktion, danach wieder; Anzeige nennt veraltet/keine Daten | Offline-Schwelle `offline_after_s`, Frischemarken |  |
| 0cq | Zwei Monitore am Panel-Computer: grosse Kennung anzeigen lassen, dann Monitor tauschen | Kennung erscheint auf dem richtigen Monitor, ersetzter Monitor erst nach Bestaetigung gebunden | Registry, Bindung |  |
| 0cr | Gleisbild-Vorschlag anzeigen, Entwurf verschieben, ohne Vorschau veroeffentlichen versuchen | Veroeffentlichen verweigert; mit Vorschau und Bestaetigung aktiv; Besetzt/Reserviert/Zug/Stoerung getrennt sichtbar | Entwurfsablauf, Ebenen |  |
| 0cs | Eine Stoerung quittieren, Ursache bleibt bestehen | Eintrag bleibt sichtbar (gesehen), Sperre bleibt, erst der Nachweis loest sie | Stoerungszentrale |  |
| 0ct | `ota_push` fuer einen Signal-Computer ohne Bestaetigung, danach mit `confirm`, aber ohne `update_release` | beide Male abgelehnt, Audit `ota_refused` nennt den Grund | Update-Steuerung, Rechte |  |
| 0cu | Zug faehrt, Update eines Signal-Computers mit Freigabe und Bestaetigung versuchen | abgelehnt (aktive Fahrt), Signal bleibt unberuehrt | `busy`-Pruefung |  |
| 0cv | Update auf einem Signal-Computer, Neustart waehrend des Tauschs (Chunk entladen / Computer abschalten) | nach dem Start gueltiger Slot (alt oder neu) oder Sperre; Bloecke des Knotens FAULT, nie frei ohne Nachweis | `ota_recovery`, `on_lock` |  |
| 0cw | Wartungssperre setzen, Master neu starten | Sperre besteht weiter, keine Fahrt startet | `state/maintenance.json` |  |
| 0cx | Signal-Computer tauschen (Assistent): neuer Computer, Fingerabdruck, Signale neu binden, Funktionstest | alter Schluessel ungueltig, Knoten bleibt bis zum bestandenen Test gehalten | Austauschassistent, Bindung |  |
| 0cy | `lua scripts/acceptance_report.lua --stage` nach jedem Abnahmelauf | zeigt die erreichte Freigabestufe; ohne Nachweise "NONE" | Matrix `tests/acceptance/matrix.lua`: Status, Nachweisfelder |  |
| 0cz | 300+ Signale im Zielnetz, danach 400 im Stresstest (J-01, J-02) | keine falsche Zuordnung, Queue-/Speichergrenzen laut vorher festgelegten Obergrenzen | Lastreserve in `signoff` eintragen; zusaetzliche Nodes (R-08) |  |
| 0da | Komplettneustart aller Computer mit mehreren Zuegen in der Welt (E2E-08) | alle Signale ROT, Reservierungen bleiben, nichts frei ohne Nachweis, keine alte Fahrt wird wiederholt | `dispatcher.restore`, Beweismodus an? |  |
| 0db | Zwei Monitore am Panel-Computer binden (`scripts/bind_monitors.lua bind A`, `bind B`), verschiedene Ansichten | jeder zeigt seine Ansicht, Touch wirkt auf den beruehrten Monitor; Monitor abziehen: der andere zeichnet weiter, Log nennt den fehlenden | Bindung, Ansicht, Skala |  |
| 0dc | Gleisbild-Ansicht nach einer Aenderung im Plan des Masters (Master neu gestartet) | das Panel holt die neue Topologie, alte Bloecke behalten ihren Platz, neue sind markiert; vor dem Neustart des Masters wird die neue nicht gezeichnet | `plan_get`, Versionsvergleich |  |
| 0dd | Fahrplaneditor: Takt aendern, Entwurf senden, veroeffentlichen; danach an einem zweiten Panel gleichzeitig dieselbe Linie | zweiter Tipp noetig; das zweite Panel meldet Konflikt, Neu laden/Stand uebernehmen waehlbar; Partner aus: keine Veroeffentlichung | `fleet_admin`, Basisversion |  |
| 0de | Ladestelle: Kiste neben dem Gleis, Zug belaedt, faehrt ab | Frachtansicht zeigt die gemessene Menge; Kiste abbauen vor der naechsten Ankunft: Fehlermeldung an der Fahrt, nichts gebucht | `platform.cargo`, Inventar lesbar? (Create-Verlader, Faesser) |  |
| 0df | Depotfahrt eines Zuges aus dem Zugdetail (`In Depot`), Depot voll, danach frei | freies Gleis gewaehlt, bei vollem Depot anderes Depot/Umlauf/Warten mit Meldung; Create faehrt den Namen des Depotgleises an | `fleet.depots`, Create-Name des Gleises |  |
| 0dg | Master-AUX auf eigenem Monitor, Seiten des Masters absichtlich stoppen (Seite mit Fehler) | die AUX-Ansicht zeichnet weiter und zeigt Zustand, Bloecke, Knoten, Sperren, Journal | `aux_monitor` |  |
| 0dh | Austausch eines Signal-Computers ueber die Wartungsseite mit Diskette im Laufwerk des Masters | Schluessel nur auf der Diskette, Pruefsumme stimmt, Signale neu gebunden, Test bestanden, dann wieder Betrieb | `replace_*`, Laufwerk |  |
| 0bx | Dauerbetrieb zwei Stunden bei hoher Serverlast (viele Chunks, TPS unter 15), beide Master und Schiedsrichter laufen | keine Doppelführung (`leader_gained` je Master im Audit prüfen, nie gleichzeitig), keine unnötigen Wechsel | häufige Wechsel: `election_lease_ms` / `election_beat_ms` erhöhen und messen | |
| 0by | Zwei Master laufen, ein Zug fordert eine Route an; danach Master B abschalten (Chunk entladen) und eine zweite Route anfordern | die erste Route wird gestellt, die zweite wird reserviert, aber das Signal bleibt rot und der Zug bekommt keine Abfahrt; Panel zeigt die wartenden Freigaben; nach Neustart von B geht alles in Reihenfolge hinaus (Weiche vor Signal) | Signal grün ohne B: sofort melden (Fehler in `barrier`/`guarded_adapters`) | |
| 0bz | Führenden Master A mitten in einer Fahrt hart ausschalten (Chunk entladen) | B führt nach 10 bis 20 s, stellt die Signale der bestätigten Reservierungen neu, vergibt erst nach Bestätigung im Panel neue Routen; kein Zug bekommt einen doppelten Abfahrtsbefehl | Zug steht ohne Signal: Reservierung im Dispatcher von B prüfen, `recovery.required` | |

## 1. Was macht ein Create-Signal, wenn sein Computer ausfällt? (offene Frage Nr. 1)

Das ist die wichtigste Frage: die Software setzt Signale neu (Start, rollend, Reconnect) und schaltet beim Stoppen des Masters alle auf ROT, aber sie
kann nicht wissen, ob der Zustand im Spiel erhalten bleibt.

| # | Versuch | Erwartet | Wenn anders | Ergebnis |
|---|---|---|---|---|
| 1a | Signal auf GRÜN stellen (`setForcedRed(false)`), Computer mit `shutdown` ausschalten | Signal bleibt GRÜN (Zustand liegt im Signal-Block) | springt auf ROT: gut, fail-safe; springt auf GRÜN/anderen Zustand: siehe 1d | |
| 1b | Signal auf ROT stellen, Computer ausschalten | bleibt ROT | wird GRÜN: **gefährlich** → Signale nur mit zusätzlichem Redstone-Latch/Hardware-Rückfallebene betreiben und melden | |
| 1c | Computer neu starten (`reboot`) | Signal behält Zustand, Signal-Node setzt beim Start ROT, Master schickt GRÜN nach (Log-Seite zeigt es) | Signal bleibt dauerhaft ROT: Master-Log und `node_reconnect` im Audit prüfen | |
| 1d | Chunk entladen (weit weglaufen, Computer + Signal im selben Chunk), nach 1-2 Minuten zurückkehren | Zustand wie vor dem Entladen, Node meldet sich neu (`node_reconnect`) | Zustand verloren: Dauer notieren, `signal_refresh_per_s` ggf. erhöhen | |
| 1e | Master mit Ctrl+T beenden | alle Signale gehen auf ROT, Züge halten vor den Signalen | Signal bleibt GRÜN: Peripheral-Name in der Hardware-Config prüfen; `signal_red_on_stop` | |
| 1f | Master hart beenden (Chunk entladen / Server-Neustart) | Signale bleiben im letzten Zustand (hier hilft die Software nicht) | – | |

Trage das Ergebnis in `docs/assumptions.md` unter „Not verified in the game" ein und passe `signal_red_on_stop` an, falls 1e/1f zeigen, dass es nichts nützt.

## 2. Master-Neustart

1. Zug wartet vor rotem Signal mit Fahrerlaubnis (Signal GRÜN), Master mit Ctrl+T beenden und neu starten.
2. Erwartet: Master meldet RECOVERY (Statusseite rot) und lehnt neue Anforderungen ab, bis im Panel `confirm_recovery` ausgelöst wird. Freie Blöcke
   haben ROT, der wartende Zug bekommt sein GRÜN zurück, die Weichen des fahrenden Zuges bleiben gesperrt (ein zweiter Zug, der dieselbe Weiche
   anders braucht, wartet), nichts wird doppelt vergeben. Nach der Bestätigung läuft alles normal weiter.
3. Wenn nicht: `state/master_state.json` und `.prev` ansehen, Trace-Datei (Abschnitt 8) an mich geben.

## 3. Node-Ausfall und Selbstheilung

| # | Versuch | Erwartet | Ergebnis |
|---|---|---|---|
| 3a | Sensor-Computer ausschalten (oder Chunk entladen), > 6 s warten | Block FAULT, Alerts-Seite rot, Audit `node_timeout` genau **einmal** | |
| 3b | Sensor wieder einschalten, Detektor frei | nach ca. 15-20 s Block wieder FREI, Audit `fault_auto_cleared`, Alert grün | |
| 3c | wie 3a, aber Zug steht beim Wiedereinschalten auf dem Detektor | Block bleibt FAULT, solange der Detektor „belegt" meldet; nach Abfahrt Selbstheilung | |
| 3d | wie 3a, Zug fährt währenddessen durch den Block und weiter | nach 3b ist der Zug-Eintrag weg, Strecke frei; kommt der Zug in den **nächsten** Block, entscheidet dessen Sensor | |
| 3e | wie 3a, aber ein zweiter Zug wartet in der Warteschlange | nach der Heilung wird er automatisch abgefertigt | |
| 3f | `auto_clear_faults = false` setzen und 3a/3b wiederholen | Block bleibt FAULT, `manual_control clear_fault` räumt ihn | |
| 3g | Signal-Computer ausschalten und wieder an | Block heilt erst, wenn auch die Sensoren „frei" melden; Signal bekommt vom Master seinen Zustand zurück | |

## 4. Stellwerk (Fahrstraßen)

1. Strecke mit Weiche: Zug anfordern → Gleisbild zeigt die Fahrstraße (`SET` grün), beim Einfahren `OCCU`, dann `DISS`, am Ende weg.
2. Zweiter Zug auf eine Fahrstraße, die dieselbe Weiche anders braucht → bleibt in der Warteschlange (`diag`: Grund), fährt nach dem ersten.
3. Gegenrichtung auf demselben Abschnitt → Warteschlange mit `opposite direction conflict`.
4. Optional: `flank_protection` in `interlocking_routes` für eine Nachbarweiche → wird gestellt (physisch!) und gesperrt, solange die Fahrstraße steht.
5. Optional: `overlap_block` hinter dem Ausfahrsignal → bleibt reserviert; Zug über das Halt-Signal hinaus → Block FAULT mit Alert.
6. Manuell `set_signal ... GREEN` ohne aktive Fahrstraße → Ablehnung mit „SICHERHEIT"; mit aktiver Fahrstraße → akzeptiert.

## 5. Updates (OTA)

| # | Versuch | Erwartet | Ergebnis |
|---|---|---|---|
| 5a | `lua scripts/ota_push.lua --node TESTNODE` | `QUEUED → … → DONE → CONFIRMED`, Node läuft mit neuer Version (`crn_version.txt`) | |
| 5b | Datei mit Syntaxfehler pushen (nur auf TESTNODE!) | Node startet nicht richtig, beim zweiten Boot ohne Bestätigung Rückfall auf die alte Version (`OTA recovery: …` beim Start) | |
| 5c | Computer während `COMMITTING` ausschalten / Chunk entladen | beim nächsten Start Rückfall oder vollständiges Update, nie ein Mischzustand | |
| 5d | Signal-Node updaten, während ein Zug wartet | Signal geht vor dem Tausch auf ROT, der Master schickt es nach dem Neustart wieder | |
| 5e | Node mit **altem** Stand: `lua scripts/ota_push.lua --legacy --node X` | Node meldet sich mit neuem Code (Status `CONFIRMED` im Master, `DONE` im Tool); danach normales `ota_push.lua` ohne `--legacy` | |
| 5f | Alten `startup.lua` auf dem Node lassen, einmal starten | Log „startup.lua got the OTA recovery block", `startup.lua.prev` vorhanden, nach dem nächsten Neustart ist die Wiederherstellung aktiv | |
| 5g | `fs.getFreeSpace("/")` vor und nach einem vollständigen Update auf einem kleinen Computer | genug Platz (der Legacy-Weg schreibt temporär doppelt: ca. 170 KB × 2) | |

## 6. Oberfläche

- Alle Seiten auf jeder verwendeten Monitorgröße durchblättern (linke/rechte Kante): kein Flackern, Texte nicht abgeschnitten, Touch-Zonen treffen.
- Statusseite: Lampe zeigt Rot bei Sensor-/Signal-/Weichen-Ausfall, Gelb bei einem anderen Node, Grün sonst; Alert antippen quittiert ihn.
- Logseite: Warnungen der Nodes erscheinen (z.B. defekter Sensor an einer Station).

## 7. Last und Größe

Das Netz darf wachsen; die Software begrenzt Listen, Retries und Logs. Prüfen, wenn es soweit ist:

- TPS und Rechner-Auslastung des Masters mit 10 / 30 / 60 Nodes (Heartbeats alle 2 s je Node); `diag`-Seite, Log „tick job failed".
- Ein OTA-Rollout an alle Nodes: `max_parallel` (4) Nodes gleichzeitig, der Rest wartet; keine Node-Timeouts während des Rollouts.
- Mehrere Züge gleichzeitig auf einer Strecke mit Weichen: keine Blockade, Warteschlange baut sich wieder ab.

## 8. Fehler festhalten

Wenn etwas Unerwartetes passiert ist (Block FAULT ohne erkennbaren Grund, Zug steht, falsches Signal): die Datei `traces/fault_1.json` (wird bei einem
Block-Fault selbst geschrieben) oder `trace_dump` im Panel auslösen, mit der Config auf einen PC kopieren und

    lua scripts/replay_trace.lua traces/fault_1.json configs/network.json

ausführen. Die Ausgabe zeigt, ob der Dispatcher dasselbe getan hätte und welche Sicherheitsregel gebrochen wurde. Trace + Config + Beschreibung
reichen, um den Fehler offline nachzustellen und als Test festzuhalten.
