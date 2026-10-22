# Mehrere Signale an einem Computer (Gesamtkonzept Kap. 6)

Eine Signal-Node kann mehrere physische Signale steuern (4, 6, 8 und mehr). Jedes Signal hat eine **logische ID** (die der Netzplan in `blocks[].entry_signal` / `exit_signal` nennt); welche
Peripherie dahinter steckt, weiss nur der Computer vor Ort.

## Netzplan

```json
{ "signal_transport": "network",
  "nodes": [ { "id": "SIGN-1", "role": "signal", "signals": ["S-A", "S-B", "S-C", "S-D"] } ] }
```

- `signals` listet die logischen IDs, die dieser Computer steuert. Ohne Liste steuert eine Signal-Node das Signal ihrer eigenen ID (wie bisher).
- `signal_transport = "network"`: der Master schickt `set_aspect` (mit `signal_id`) an die Signal-Node. Standard `local`: der Master schaltet die Peripherie selbst (altes Verhalten). Mit `network` muss jedes Signal
  eines Blocks von einer Signal-Node gesteuert werden, sonst meldet `scripts/setup.lua --check` einen Fehler.

## Bindung (nur auf dem Computer, nur mit Bestaetigung)

`scripts/bind_signals.lua bind <ID>`: das Modem **eines** Signals anschliessen, Enter, das Werkzeug erkennt genau ein neues Signal-Geraet und stellt es auf **Rot** (nie auf Gruen: ein Signal wird nicht
durch Freigeben gesucht). Der Bediener bestaetigt, dass das richtige Signal rot ist, und gibt Gleis, Richtung, Signalart und Ort an. Die Zuordnung steht in `state/signal_bindings.json`. Weitere Befehle:
`check` (vergleicht Bindung, Geraete und Plan, aendert nichts), `list`, `replace <ID>` (Ersatzgeraet), `unbind <ID>`.

**Nichts wird von selbst umgebunden**, nicht nach einem Start, nicht nach dem Verschieben eines Modems, nicht nach einem Hardwaretausch. Ein fehlendes Geraet, ein anderer Typ, ein neues unbekanntes
Signal-Geraet oder ein gebundenes Signal, das der Master nicht kennt, wird gemeldet; das betroffene Signal wird nicht benutzt.

## Ablauf eines Befehls

Master: `net_signals` schickt den Befehl (zuverlaessig, mit Epoche und Befehls-ID). Node: prueft die Bindung und die Hardware bei jedem Befehl und stellt genau die gebundene Peripherie. Antwort:
`ack` mit `applied` (die Node hat es getan) oder `err` (die Node hat es verweigert: nicht gebunden, Geraet fehlt, anderer Typ, Master kennt das Signal nicht). Ein `err` oder ein Befehl ohne Antwort nach den
Wiederholungen nimmt die Bloecke dieses Signals ausser Betrieb (FAULT, nur der Bediener hebt das auf). **Empfang, Ausfuehrung und physische Wirkung sind drei verschiedene Dinge**: `applied` heisst nicht,
dass das Signal wirklich rot ist; ein Create-Signal laesst sich nicht zuruecklesen.

Der Heartbeat der Node traegt `signals` (OK, MISSING, TYPE, UNKNOWN, UNBOUND je Signal). Meldet die Node etwas anderes als OK, nimmt der fuehrende Master die Bloecke dieses Signals ausser Betrieb.
Beim Start und vor einem Update stellt die Node alle benutzbaren Signale auf Rot.

## Grenzen

- Vanilla Create kennt nur `setForcedRed`: Gruen und Gelb geben das Signal frei. `setForcedRed(true)` faellt bei verlorener Computerverbindung auf normales Create-Verhalten zurueck (Kap. 6): ein Ausfall der
  Signal-Node ist **kein** Haltenachweis. Die Strecke muss das physisch abfangen (R-01); die Software ersetzt das nicht.
- Eine Vertauschung zweier Signale gleichen Typs (zwei Modems getauscht) erkennt nur der Bediener beim Identifikationstest (`bind` / `replace` mit Rotstellen); `check` erkennt Namens- und Typaenderungen.
- Die genauen Create-Methoden in ATM10 8.1 (`getSignalType`, `listBlockingTrainNames`) sind Testpflicht (Spieltests 0ce bis 0ch).

# Bahnhoefe und Depots (Kap. 7)

Gleiswahl und Depotwahl liegen als reine Logik in `src/domain/track_choice.lua`: nur bestaetigte Gleise, Richtung, Laenge, Zugart, Vorzug, Konfliktgruppe, nur bewiesen freie Gleise. Sind alle passenden Gleise
belegt, wartet der Zug an einem sicheren Wartepunkt vor dem Bahnhof; ein volles Depot fuehrt zu einem anderen Depot, dann zu einer bestaetigten Umlaufroute, sonst zu einem sicheren Halt mit Stoerungsmeldung (nie
zu einer Blockade vor dem Depot). Die Anbindung an Fahrplaene und Auftraege kommt mit P7.
