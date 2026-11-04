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

Das Datenformat ist **2**. Bis Format 1 haben alle Aenderungen (zum Beispiel Reihenfolge der Signale, Wirkrichtung, Netzverzeichnis Version 2) nur Felder ergaenzt, die das Programm beim Laden mit einer Vorgabe fuellt. Belegt ist das durch `tests/fixtures/alte_staende.lua`: Datenstaende (Leitstelle, Signal-Node, Bahnhof), die zwei aelteren Programmfassungen aus Git geschrieben haben, starten im aktuellen Programm ohne Fehler, mit unveraenderter Einrichtung und mit angemeldeten Nodes (sie werden dabei einmal von Format 1 auf 2 angehoben).

| Schritt | Text | Was er tut |
|---|---|---|
| 1 -> 2 | Entwurf der Einrichtung verwerfen | Es gibt keinen Entwurf mehr (nur eine geprueft aktivierte Einrichtung wird gespeichert). Eine `config.lua` ohne Status "aktiv" wird geloescht (die Sicherung `sicherung_f1` behaelt sie); ihre Anforderungskennung (`node.claim`) wandert nach `anforderung.lua`, damit die Leitstelle keine zweite Node-Kennung vergibt, und eine stehengebliebene Testsperre (`pruefung.lauf`) nach `pruefmarke.lua`. Eine aktive Einrichtung bleibt unveraendert; steht in ihr eine Testsperre-Marke, zieht nur diese um. |

Neue Dateien seit Format 2: `/crn_data/anforderung.lua` (`{ claim = "c..." }`, die Anforderungskennung dieses Computers im Netzverzeichnis; bei einer eingerichteten Node gilt `config.node.claim`) und `/crn_data/pruefmarke.lua` (`{ device, name, t }`, nur waehrend einer Testsperre der Abschlusspruefung; der naechste Start hebt die Sperre auf und loescht die Datei).

## Regel fuer Aenderungen

1. **Nur ergaenzt** (neues Feld, das beim Laden eine Vorgabe bekommt): kein Schritt. `tests/test_integrator.lua` meldet die neue Form trotzdem; die Festlegung `tests/golden/datenform.txt` wird bewusst erneuert: `CRN_UPDATE_GOLDEN=1 lua tools/run_tests.lua integrator`, den Unterschied im Commit ansehen.
2. **Umbenannt, entfernt, Bedeutung geaendert, Pflichtfeld, Datei verschoben**: ein Schritt an `src/core/migrations.lua` (`STEPS[n] = { text = "...", run = function(ctx) ... end }`; das Format ist dann 1 + Anzahl der Schritte). Danach die Festlegung erneuern, und die Datenstaende der Vorfassung als weitere Fassung in `tests/fixtures/alte_staende.lua` aufnehmen, damit der Schritt an echten alten Dateien laeuft.
3. Ein Schritt nennt, wenn er nur wenige Dateien anfasst, deren Namen als `scope` (sonst wird alles gesichert und eine grosse Datei kann die Anpassung verhindern). Ein Schritt arbeitet nur auf Daten (`ctx.load`, `ctx.save`, `ctx.update`, `ctx.files`, `ctx.exists`, `ctx.delete`, Namen relativ zu `/crn_data`, auch `nodesich/N0001.lua`: die Sicherungen der Leitstelle gehoeren mit angepasst) und ruft keinen anderen Programmteil auf. Fehler oder `return false, "Grund"` nehmen alles zurueck.

## Grenzen

- Die Festlegung der Form deckt `config.lua` aller Rollen, `netz.lua`, `epoche.lua`, `umgebung.lua` und `nodesich/` ab. Die Zustandsdateien der Rollen (Zugregister, Auftraege, Sperren, Bahnhofszustand) haben noch keine Festlegung; fuer sie gilt dieselbe Regel, sie wird aber nicht automatisch geprueft.
- Eine Konfiguration, die ein Ersatzcomputer aus einer Sicherung der Leitstelle uebernimmt, wird nicht einzeln angepasst; die Sicherungen werden mit der Leitstelle angepasst. Wird die Leitstelle vor einer Node aktualisiert, kann bis zu deren Update eine Sicherung im alten Format eintreffen.
- Daten aus der Zeit vor dem Neustart (Netzplan als JSON in `configs/`) werden nicht uebernommen.
