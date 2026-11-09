# Datenformat und Integrator (alte Staende im neuen Programm)

Ein Update ersetzt nur das Programm (`/crn`). Die Dateien des Computers liegen getrennt in `/crn_data` (Einrichtung `config.lua`, bei der Leitstelle zusaetzlich Netzverzeichnis `netz.lua`, Sicherungen der anderen Nodes `nodesich/`, Zustand der Rollen) und bleiben dabei unberuehrt. Damit ein neues Programm die Dateien eines aelteren Programms versteht, gibt es den **Integrator**: `src/core/dataformat.lua` (Ablauf) und `src/core/migrations.lua` (die Anpassungsschritte).

## Was beim Start geschieht

Vor dem Laden jeder Datei vergleicht der Node das Datenformat des Computers (`/crn_data/format.lua`) mit dem Format, das das Programm kennt (`dataformat.FORMAT`):

| Lage | Folge |
|---|---|
| gleich | nichts zu tun |
| Daten aelter | alles unter `/crn_data` wird nach `/crn_data/sicherung_fN` gesichert (Abschlussmerker `fertig.lua`), die Schritte laufen der Reihe nach, danach pruefen sie sich selbst (jede Datei muss lesbar sein), dann wird der neue Stand eingetragen. Meldung: *Daten an das neue Programm angepasst* |
| Schritt scheitert, Platz fehlt, Datei zu gross fuer die Sicherung | **alles kommt zurueck**, der alte Stand bleibt, die Automatik bleibt aus (Uebersicht: *Datenanpassung gescheitert* mit Grund); der naechste Start versucht es erneut |
| Computer faellt mitten in der Anpassung aus | der naechste Start spielt zuerst die Sicherung zurueck (Merker `migration.lua`) und fuehrt die Anpassung dann von vorn aus; ein Schritt laeuft also nie auf halb angepassten Daten |
| Daten neuer als das Programm (nach `installer --rollback`) | nichts wird veraendert, die Automatik bleibt aus (*Datenformat zu neu*); `crn/app/main datenstand` zeigt die Sicherungen, `crn/app/main daten-zurueck N` spielt sie zurueck |

Gesichert werden alle Dateien bis 60 000 Byte je Datei und 150 000 Byte zusammen (ohne Journal, `.tmp`, `.prev`). Nennt ein Schritt die Dateien, die er aendert (`scope = { "config.lua" }`), und tun das alle Schritte, die laufen, werden nur diese gesichert: so scheitert eine kleine Anpassung nicht an der Groesse der Netzdaten und Sicherungen einer grossen Leitstelle. Der Schritt 1 -> 2 sichert nur `config.lua`. Passt etwas nicht hinein oder fehlt der Platz, wird **nichts** angepasst, statt ohne Sicherung zu arbeiten.

Bei der Selbstaktualisierung (`docs/AKTUALISIERUNG.md`) gehoert die Sicherung zur Probe: scheitert der neue Stand, spielt die Startdatei die Daten aus der Sicherung zurueck.

## Stand heute

Das Datenformat ist **5**. Bis Format 1 haben alle Aenderungen (zum Beispiel Reihenfolge der Signale, Wirkrichtung, Netzverzeichnis Version 2) nur Felder ergaenzt, die das Programm beim Laden mit einer Vorgabe fuellt. Belegt ist das durch `tests/fixtures/alte_staende.lua`: Datenstaende (Leitstelle, Signal-Node, Bahnhof), die zwei aelteren Programmfassungen aus Git geschrieben haben, starten im aktuellen Programm ohne Fehler, mit unveraenderter Einrichtung und mit angemeldeten Nodes (sie werden dabei einmal von Format 1 auf 2 angehoben).

| Schritt | Text | Was er tut |
|---|---|---|
| 1 -> 2 | Entwurf der Einrichtung verwerfen | Es gibt keinen Entwurf mehr (nur eine geprueft aktivierte Einrichtung wird gespeichert). Eine `config.lua` ohne Status "aktiv" wird geloescht (die Sicherung `sicherung_f1` behaelt sie); ihre Anforderungskennung (`node.claim`) wandert nach `anforderung.lua`, damit die Leitstelle keine zweite Node-Kennung vergibt, und eine stehengebliebene Testsperre (`pruefung.lauf`) nach `pruefmarke.lua`. Eine aktive Einrichtung bleibt unveraendert; steht in ihr eine Testsperre-Marke, zieht nur diese um. |
| 2 -> 3 | Freigabeausgang der Gleise entfernen (Freigabe laeuft ueber den Fahrplan) | Die Abfahrt wird ueber den Abschnittsfahrplan der Train Station freigegeben (`docs/FREIGABE_PER_FAHRPLAN.md`), nicht mehr ueber Redstone. `tracks.*.release` in `config.lua` wird geloescht. In `station.lua` wird eine beim Update offene Freigabe (`release_set`) als verbraucht gesetzt (sie gehoerte dem Zug von damals; das Programm laeuft bei offener Freigabe nicht neu an). Betroffene Dateien: `config.lua`, `station.lua`. |
| 3 -> 4 | Rollen Signal und Knoten entfernen (Create regelt die Strecke) | Es gibt keine Signal- und keine Knoten-Node mehr (`docs/NETZVERZEICHNIS.md`). Die Zustandsdateien `signal.lua`, `knoten.lua` und `pruefmarke.lua` (Testsperre eines Signals) werden geloescht. In `config.lua` fallen die Rollen `signal` und `knoten` aus `node.roles`, ausserdem alle Geraete der Art Signal, `junction`, `node.junction`, `node.junction_rev` und je Gleis `signals`, `junction` und `order_ok`; die Pruefergebnisse (`tests`) gelten neu. Hatte die Node nur diese Rollen, wird `config.lua` geloescht: der Computer beginnt die Einrichtung neu (die Sicherung `sicherung_f3` behaelt die alte). Bahnhof, Depot und Anmeldung bleiben unveraendert. Betroffene Dateien: `config.lua`, `signal.lua`, `knoten.lua`, `pruefmarke.lua`. |
| 4 -> 5 | Bahnhofsrollen zusammenfassen, Beobachter und Gleisrichtung entfernen | Passagierbahnhof, Gueterbahnhof und Depot sind eine Rolle (Bahnhof); in `config.lua` werden die Rollennamen ersetzt (doppelte entfallen). Beobachter (Geraete der Art observer, `tracks.*.observers`) und die Gleisrichtung (`tracks.*.direction`) fallen weg, nichts wertete sie aus. Betroffen ist nur `config.lua`; das Verzeichnis der Leitstelle (`netz.lua`, Version 4) stellt sich beim Laden selbst um (Rollen, Name und Label wie `N0017 \| BHF`), ohne Sicherung. Die Installer-Pakete `passagierbahnhof`, `gueterbahnhof` und `depot` bleiben als gleiche Aliase des Pakets `bahnhof`. |

**Netzverzeichnis der Leitstelle (`netz.lua`, Version 3):** Bereiche, Gleise, Knoten, Fahrwege, Konflikte und die Gleisbeziehungen der Betriebsstellen entfallen. Die Datei bereinigt sich beim Laden selbst (kein Integrator-Schritt, damit eine grosse alte Datei die Anpassung nicht ueber die Sicherungsgrenze bringt): `areas`, `tracks`, `junctions`, `tokens` und die `links` der Betriebsstellen werden entfernt, bei jeder Node `area`, `junction` und `tracks`. Nodes, Betriebsstellen und Standorte bleiben mit ihren Kennungen und Zaehlern (eine Kennung wird nie neu vergeben); aus den Rollenlisten faellt `signal` und `knoten`, eine nie aktivierte Anforderung ohne verbleibende Rolle gilt als verworfen. Beim ersten Speichern steht die Version 3 in der Datei; ein aelteres Programm (`installer --rollback`) liest sie dann nur noch (`blocked`).

Neue Datei seit Format 2: `/crn_data/anforderung.lua` (`{ claim = "c..." }`, die Anforderungskennung dieses Computers im Node-Verzeichnis; bei einer eingerichteten Node gilt `config.node.claim`). Die Datei `pruefmarke.lua` aus der Zeit der Signal-Testsperre gibt es seit Format 4 nicht mehr.

Neues Feld ohne Format-Aenderung: `devices[id].text_scale` (`config.lua`, nur bei Monitoren, 1 oder 0,5; Taste auf der Seite Geraete). Fehlt es, bleibt der Monitor, wie er ist; ein neues Programm liest alte Dateien ohne Anpassungsschritt, ein altes Programm ignoriert das Feld.

## Regel fuer Aenderungen

1. **Nur ergaenzt** (neues Feld, das beim Laden eine Vorgabe bekommt): kein Schritt. `tests/test_integrator.lua` meldet die neue Form trotzdem; die Festlegung `tests/golden/datenform.txt` wird bewusst erneuert: `CRN_UPDATE_GOLDEN=1 lua tools/run_tests.lua integrator`, den Unterschied im Commit ansehen.
2. **Umbenannt, entfernt, Bedeutung geaendert, Pflichtfeld, Datei verschoben**: ein Schritt an `src/core/migrations.lua` (`STEPS[n] = { text = "...", run = function(ctx) ... end }`; das Format ist dann 1 + Anzahl der Schritte). Danach die Festlegung erneuern, und die Datenstaende der Vorfassung als weitere Fassung in `tests/fixtures/alte_staende.lua` aufnehmen, damit der Schritt an echten alten Dateien laeuft.
3. Ein Schritt nennt, wenn er nur wenige Dateien anfasst, deren Namen als `scope` (sonst wird alles gesichert und eine grosse Datei kann die Anpassung verhindern). Ein Schritt arbeitet nur auf Daten (`ctx.load`, `ctx.save`, `ctx.update`, `ctx.files`, `ctx.exists`, `ctx.delete`, Namen relativ zu `/crn_data`, auch `nodesich/N0001.lua`: die Sicherungen der Leitstelle gehoeren mit angepasst) und ruft keinen anderen Programmteil auf. Fehler oder `return false, "Grund"` nehmen alles zurueck.

## Grenzen

- Die Festlegung der Form deckt `config.lua` aller Rollen, `netz.lua`, `epoche.lua`, `umgebung.lua` und `nodesich/` ab. Die Zustandsdateien der Rollen (Zugregister, Auftraege, Sperren, Bahnhofszustand) haben noch keine Festlegung; fuer sie gilt dieselbe Regel, sie wird aber nicht automatisch geprueft.
- Eine Konfiguration, die ein Ersatzcomputer aus einer Sicherung der Leitstelle uebernimmt, wird nicht einzeln angepasst; die Sicherungen werden mit der Leitstelle angepasst. Wird die Leitstelle vor einer Node aktualisiert, kann bis zu deren Update eine Sicherung im alten Format eintreffen.
- Daten aus der Zeit vor dem Neustart (Netzplan als JSON in `configs/`) werden nicht uebernommen.
