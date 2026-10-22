# Journal, Snapshots und Befehls-Buchführung

Nach dem Gesamtkonzept (Kap. 5.2, 5.4, 12.2, 15) braucht das System Zustandsänderungen mit **monoton geordneten Sequenzen, unveränderlichen Einträgen, Prüfsummen, expliziten
Commit-Indizes und periodischen Snapshots**. Unvollständige Journale und Schreibfehler sperren betroffene neue Freigaben. Dieses Paket (P2) liefert die Bausteine; der Master benutzt
sie ab Paket P4 für den Dual-Commit.

## Journal (`src/shared/journal.lua`)

- Eine Textdatei: Kopfzeile `#CRNJ1<TAB>Basis<TAB>Prüfsumme`, dann je Eintrag eine Zeile `Nummer<TAB>Art<TAB>JSON<TAB>Prüfsumme` (Adler-32 über alles davor). Nummern zählen lückenlos hoch.
- **Commit-Marken** sind Einträge der Art `commit` (`upto = n`): alles bis n ist festgeschrieben. `committed()` sagt, wie weit.
- **Snapshot** (`journal.snapshot(state)`): schreibt den Zustand in `<pfad>.snap` (`safe_write`, mit `.prev`), danach das Journal neu mit Basis = letzte Nummer. Ein Absturz dazwischen
  verliert nichts: beim Öffnen werden Einträge unterhalb des Snapshots übersprungen und die Verdichtung wird zu Ende geführt.
- **Wiederherstellung** (`journal.recovered()`): letzter Snapshot und alle Einträge danach, in Reihenfolge; offene (nicht festgeschriebene) Einträge liegen oberhalb von `committed`.
- **Beschädigung**: eine abgebrochene letzte Zeile (kein Zeilenende, falsche Prüfsumme) wird abgeschnitten (`tail_repaired`), der Rest bleibt. Eine beschädigte Zeile **mit Zeilen danach**, eine Lücke,
  ein falscher Kopf oder ein unlesbarer Snapshot machen das Journal `corrupt`: es verweigert Einträge und fasst die Datei nicht an (sie ist Beweismaterial). Ein Schreibfehler (Platte voll)
  macht es `failed`, bis `reopen()` die Dateien wieder intakt findet.
- **Grenzen** (J-07, J-09): mit `state_fn` verdichtet es sich selbst (`max_entries`, `max_bytes`); ohne oder wenn das nicht gelingt, stoppt es bei vier mal `max_bytes` mit „journal is full“.

## Buchführung für Befehle (`src/shared/idempotency.lua`)

`begin(id)` → `new` (jetzt ausführen), `done` (Ergebnis liegt vor, nicht noch einmal ausführen), `started` (läuft noch), `uncertain` (vor einem Neustart begonnen, Ausgang unbekannt: nie blind
wiederholen, erst den Zustand der Welt feststellen). `finish(id, ergebnis)` schließt ab. Mit angehängtem Journal wird jeder Schritt **vor** der Aktion geschrieben; kann er nicht geschrieben
werden, gibt `begin` einen Fehler zurück und der Befehl wird nicht ausgeführt (keine dauerhafte Spur, keine Aktion).

## Wo es schon wirkt

- **Nodes**: `set_schedule`, `depart_authorized` und `dispatch_train` laufen über die Buchführung (`state/node_commands.log`, `durable_commands`, im Spiel standardmäßig an). Wiederholt der Master einen
  Befehl nach dem Neustart des Nodes, antwortet der Node wie beim ersten Mal und führt nichts aus. Ein beschädigtes Journal lässt diese Befehle ablehnen, nicht den Rest.
- **Master**: der bisherige Zustandsspeicher (`state/master_state.json`) bleibt bis P4; dort wird das Journal der Reservierungen der Kern des Dual-Commit.

## Nur im Spiel prüfbar

Ob `fs.open(pfad, "a")` anhängt, wie die Fehlermeldung bei voller Platte lautet und wie lange Verdichtung dauert: `docs/INGAME_TESTS.md`, Zeilen 0bo bis 0br.
