# Schlüssel und Authentifizierung der Nachrichten

Nach dem Gesamtkonzept (Kap. 12) darf kein Computer einem anderen glauben, nur weil er dessen Namen trägt: Computer-IDs und Absenderangaben sind kein
Identitätsbeweis. Jede Nachricht trägt deshalb einen Prüfcode (HMAC-SHA-256, auf 16 Byte gekürzt), der nur mit dem Schlüssel des Computers stimmt.
Der Schlüssel kommt **nur durch Handübergabe** auf den Computer: von einem Master auf eine Diskette, von der Diskette in den Computer (oder abgetippt).

## Was das schützt und was nicht

Es schützt gegen:
- **Fremde Computer** (F-01): ohne Schlüssel kommt nur `pair_announce` / `pair_probe` / `plan_get` durch, sonst nichts.
- **Fremde Namen** (F-02): ein Computer, der sich SIG-1 nennt, aber den Schlüssel von SIG-1 nicht hat, wird nicht gehört.
- **Veränderte Nachrichten** (F-03): jedes Feld der Nachricht und der ganze Inhalt sind im Prüfcode.
- **Wiederholte Nachrichten** (F-04): eine mitgeschnittene Nachricht wird nicht noch einmal ausgeführt, auch nicht nach einem Neustart des Empfängers.
- **Gesperrte Schlüssel** (F-08): ein gesperrter oder ersetzter Schlüssel wird sofort nicht mehr gehört.
- **Überlast durch Fälschungen** (F-10): die Prüfarbeit ist begrenzt; ein Computer, dessen Name missbraucht wird, kommt nach dem Angriff wieder durch.

Es schützt nicht gegen einen **Computer, der einem Angreifer gehört**: wer an den Computer kommt, liest dessen Schlüssel (Lua kann keinen Schlüssel vor dem
eigenen Computer verstecken). Es ersetzt auch nicht die Absicherung des Peripherie-Netzes: ein fremder Computer, der per Kabel direkt an ein Signal
kommt, braucht keine Nachricht (F-09, Risiko R-04: Peripherie-Netze trennen und im Spiel prüfen).

## Aufbau

- Ein **Master-Schlüssel** gehört beiden Mastern (A und B) und sonst niemandem.
- Jeder andere Computer (Signal, Melder, Weiche, Bahnhof, Depot, Zug, Panel, später Schiedsrichter) hat einen **eigenen Schlüssel**. Er ist aus dem Master-Schlüssel,
  der ID und einer **Schlüsselnummer** abgeleitet. Die Master speichern ihn nicht, sie leiten ihn bei Bedarf ab.
- Ein Computer kann mit seinem Schlüssel nur mit den Mastern sprechen. Andere Computer kann er nicht prüfen (Nachrichten zwischen Nodes sind nie „authentifiziert").
- Die **Liste** (`state/crn_trust.json`) sagt, wer einen Schlüssel hat, welche Nummer er hat und ob er gesperrt ist. Ein neuer Schlüssel für dieselbe ID
  bekommt die nächste Nummer, der alte Schlüssel gilt sofort nicht mehr.
- Beim ersten Kontakt (und nach jedem Neustart eines Computers) läuft eine **Sitzung** an: der Empfänger schickt eine Aufforderung, der Sender wiederholt alles
  Offene mit deren Zahl. Das kostet einen Hin- und Rückweg. Alte Mitschnitte haben diese Zahl nicht und scheitern.

## Betriebsarten (`auth_mode` im Netzplan, gilt je Computer)

| Wert | Wirkung |
|---|---|
| `off` (Standard) | nichts wird signiert oder geprüft: wie bisher |
| `monitor` | alles wird signiert und geprüft, Fehler werden gezählt und gemeldet, **nichts wird abgelehnt**: für die ersten Stunden nach der Schlüsselausgabe |
| `enforce` | eine Nachricht ohne gültigen Prüfcode wird verworfen. Das ist der Betrieb nach dem Gesamtkonzept |

Ein unbekanntes Wort zählt als `enforce`. `masters` (Liste der Master-IDs, Standard: nur `master_id`) sagt, mit wem ein Computer sprechen darf.

## Ablauf

1. **Erster Master**: `scripts/keys.lua init`. Der Befehl fragt nach 20 beliebigen Zeichen (Zufall), erzeugt den Master-Schlüssel und nennt die **Prüfsumme** (zwölf
   Zeichen, z.B. `1a2b-3c4d-5e6f`). Sie verrät den Schlüssel nicht, man kann sie aber vergleichen. Ein vorhandener Schlüssel wird **nie** stillschweigend ersetzt
   (alle Schlüssel würden ungültig): nur mit `--force` und der Eingabe `JA`.
2. **Zweiter Master**: am ersten `scripts/keys.lua export-master` (Diskette im Laufwerk), am zweiten `scripts/keys.lua import-master`. Er nennt die Prüfsumme, du
   vergleichst, und sagst `j`. Danach die Dateien von der Diskette löschen (sie sind so geheim wie der Schlüssel).
3. **Jeder Computer**: am Master `scripts/keys.lua issue SIG-1 --role signal` (Diskette im Laufwerk: die Datei `crn_key_SIG-1.json` liegt danach darauf; ohne Laufwerk steht der
   Schlüssel am Bildschirm, nur dort ablesen). Am Computer, Diskette im Laufwerk: `scripts/keys.lua install --id SIG-1`. Er nennt die Prüfsumme des Schlüssels,
   sie muss mit der Meldung am Master übereinstimmen. Dann `j`; auf Wunsch löscht er die Datei von der Diskette. Neu starten.
4. Im Netzplan des Masters `"auth_mode": "monitor"`, Master neu starten. `scripts/setup.lua --doctor` an jedem Computer zeigt, ob der Schlüssel da ist. Wenn alle Computer
   ihre Schlüssel haben und im Master-Log keine Fehler der Authentifizierung stehen: `"auth_mode": "enforce"`.
5. **Sperren**: `scripts/keys.lua revoke SIG-1`. Ein Master, der läuft, übernimmt die Liste nach wenigen Sekunden. Der Computer wird nicht mehr gehört. Neuer Schlüssel
   (neue Nummer): `scripts/keys.lua issue SIG-1`, dann am Computer wieder `install`. `scripts/keys.lua list` zeigt alle Schlüssel (nie den Schlüssel selbst),
   `scripts/keys.lua status` zeigt, was dieser Computer hat.

Computer mit einem **neuen** Gehäuse oder Ersatz-Hardware bekommen eine neue Schlüsselnummer (Kap. 14): der alte Schlüssel wird gesperrt, der neue ausgegeben.

## Fehlerbilder

| Beobachtung | Ursache |
|---|---|
| Computer bleibt „nicht erreichbar" nach `enforce` | kein oder falscher Schlüssel (`--doctor`, `keys.lua status`); Schlüsselnummer stimmt nicht mehr (nach `issue` neu `install`) |
| Master-Log: „authentication: master key or trust list unusable" | `state/crn_master_key.json` oder `state/crn_trust.json` fehlt oder ist beschädigt; die Liste nie aus einer alten Kopie ersetzen, wenn dort ein Computer noch nicht gesperrt war |
| `ota_push.lua` erreicht im Modus `enforce` keinen Computer | das OTA-Werkzeug hat keinen Schlüssel für die Computer; Updates laufen im Modus `enforce` über den Master (siehe `docs/OTA.md`, Paket P9) |
| ein Computer meldet sich neu, wird aber nicht aufgenommen | Aufnahme (Pairing) und Schlüssel sind getrennt: erst `keys.lua issue`, dann `install`, dann gilt die Aufnahme im Master |

## Grenzen (für die Abnahme)

- Die Schlüssel entstehen aus dem, was ein CC-Computer an Zufall hat, plus deinen 20 Zeichen (Risiko R-05). Das ist kein Hardware-Zufall.
- Prüfcode und Sitzungen kosten Rechenzeit. `tools/` misst sie nicht von selbst: Zeit pro Nachricht bei vielen Nodes am Zielserver messen (Spieltest 0bj).
- Nachrichten an `broadcast` (z.B. die Suche des OTA-Werkzeugs) sind im Modus `enforce` nie angenommen.
