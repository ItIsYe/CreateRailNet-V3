# Freigabe der Abfahrt allein ueber die Train Station

## Ausgangslage

Der Computer steht nicht an der Train Station; die Station haengt ueber ein Kabelmodem am Netz des Computers. Alle Methoden der Station (16, `docs/MESSWERTE.md` M03) lesen oder setzen Fahrplaene; **keine** gibt eine Abfahrt frei.

Bis Datenformat 2 geschah die Freigabe mit Redstone: jeder gesteuerte Aufenthalt im Fahrplan endete mit der Bedingung `create:powered`, und die Station-Rolle schaltete einen Ausgang (`dev/out.lua`). Das war unbrauchbar, sobald der Computer nicht am Bahnhof steht.

## Entscheidung des Betreibers und Stand

Freigabe **ohne Redstone**, allein ueber die Station. Umgesetzt auf `beta` (Datenformat 3): die Leitstelle fuehrt den Zug **abschnittsweise**, und die Station-Rolle gibt die Abfahrt frei, indem sie dem stehenden Zug den Fahrplan des naechsten Abschnitts setzt (`setSchedule`). Es gibt keinen Freigabeausgang mehr, weder im Assistenten noch im Betrieb.

## Gemessene Grundlage

`probe/crn_probe3.lua` und `probe/crn_alles.lua` haben die Annahmen H1 bis H5 am echten Modpack geprueft (`docs/MESSWERTE.md` M21 und M22, 2026-11-06):

| Nr | Annahme | Ergebnis |
|---|---|---|
| H1 | `setSchedule` mit geaendertem Inhalt wird geschrieben und genauso gelesen | bestaetigt |
| H2 | Ein Zug haelt am Ende eines nicht zyklischen Fahrplans | bestaetigt |
| H3 | `create:powered` mit leeren Daten wird angenommen und haelt ohne Strom | bestaetigt |
| H4 | Ein Fahrplan mit dem eigenen Bahnhof (kurze Wartezeit) als erstem und einem anderen Bahnhof als zweitem Eintrag schickt den stehenden Zug los | bestaetigt |
| H5 | Zeit von `setSchedule` bis `train_departure` | **1,2 s** |

Dazu M20: Create schickt einen Zug nicht direkt vom selben Bahnhof wieder dorthin; er muss erst zu einem anderen Bahnhof und kann von dort zurueck.

## Verfahren

- **Warteauftrag** (`schedule.waiting`): ein umlaufender Eintrag am eigenen Bahnhof, letzte Bedingung `create:powered`. Der Zug haelt, ohne dass Strom noetig ist (H3). So steht jeder Zug, bis ein Auftrag ihn abholt.
- **Auftrag annehmen** (Nachricht `fahrplan`): der Bahnhofs-Node prueft, dass der Zug im Warteauftrag steht (nie blind einen fremden Fahrplan ueberschreiben, Konzept 8.2), merkt sich den Auftrag und antwortet `uebergeben`. Gesetzt wird dabei kein Fahrplan.
- **Freigabe** (Nachricht `freigabe`): die Leitstelle baut den **Abschnittsfahrplan** der Etappe (`schedule.section`) und schickt ihn mit. Er hat genau zwei Eintraege:
  1. der **eigene Bahnhof** mit den Haltebedingungen des Aufenthalts: `create:delay` (mindestens 1 s, denn nur dieser Fall ist gemessen; eine leere Bedingungsgruppe wird nicht gebaut) und, wenn der Auftrag es verlangt, die Mengenbedingung (`create:item_threshold`);
  2. der **naechste Bahnhof** mit `create:powered` als Halt: dort steht der Zug, bis der Node dort den naechsten Fahrplan setzt.
  Der Node prueft den Abschnitt (`schedule.check_section`), dass er am eigenen Bahnhof beginnt und dass der Zug in bekannter Lage steht (Warteauftrag, oder der Abschnitt, mit dem er kam; die Leitstelle nennt dessen **Streckenkennung** `route_hash`). Die Wartezeit laeuft in Create erst ab dem Setzen, deshalb traegt der Node nur die **Restzeit** ein (`schedule.with_rest_wait`: Soll-Haltezeit minus bisher gewartet, mindestens 1 s). Er schreibt, liest zurueck und vergleicht; stimmt es nicht, gilt nichts als freigegeben. Antwort: `freigabe_gesetzt` (ein Sollzustand, keine bestaetigte Abfahrt).
- **Abfahrt**: bestaetigt wird sie wie bisher durch `train_departure` des Bahnhofs; der Auftrag wird erst dann `unterwegs`.
- **Ziel**: kommt der Zug an, weist die Leitstelle nach der Ankunftsmeldung den Bahnhofs-Node dort an, entweder den naechsten Abschnitt (Freigabe) oder am Ende den Warteauftrag zu setzen. Dass der Zug einen Abschnitt der Leitstelle traegt, erkennt der Node an der Streckenkennung, nicht an der (zeitabhaengigen) Wartezeit.
- **Zuruecknehmen**: solange der Zug noch steht, setzt der Node ihm wieder den Warteauftrag (Seite *Gleise*: "Freigabe zurueck", zweimal tippen). Einen schon abgefahrenen Zug stoppt das nicht (Konzept 8.5).

## Sicherheit und Grenzen

- **Zeitueberwachung:** steht der Zug nach Ende der Haltezeit plus 30 s noch am Gleis, geht der Auftrag in die Klaerung ("Der Zug ist nach der Freigabe nicht abgefahren"). Bei einer Mengenbedingung gibt es kein Zeitlimit; Create wartet auf die Ladung.
- **Neustart / Chunk entladen:** das Journal-Ereignis `freigabe.setzen` steht vor dem Schreiben des Fahrplans. Nach dem Wiederanlauf stimmt der gelesene Fahrplan mit dem Journal ueberein (Freigabe gilt) oder der Zug ist weg (die Leitstelle erfaehrt `zug_weg` und klaert). Es wird nie blind neu gesetzt.
- **Auftraege, die beim Update offen waren:** der Zug traegt noch den alten Gesamtfahrplan mit `create:powered`; der Node kennt ihn nicht, die Freigabe wird als "Ausgangslage unklar" abgelehnt und der Auftrag geht in die Klaerung.
- **Nicht gemessen:** die Mengenbedingung im ersten Eintrag eines Abschnitts (Spieltest 4.9/4.10 in `docs/GROSSER_TEST.md`). Sollte Create sie nicht wie erwartet auswerten, bleibt der Zug stehen und der Auftrag steht in "Abfahrt freigegeben".
- **Gleichnamige Zuege** (M14) bleiben ein offenes Problem und werden durch dieses Verfahren nicht groesser.
- Die Sicherheitsannahme "keine zweite Gruppe, die den Halt umgehen koennte" bleibt: jeder Eintrag hat genau eine Bedingungsgruppe (`check_section`). Signale und Reservierungen der Leitstelle sind nicht betroffen.

## Einrichtung

Gleise brauchen keinen Ausgang; der Assistent fragt nicht danach. Die Pruefung "Ausgang kurz schalten" gibt es nicht mehr. Einen Schreibtest auf dem Fahrplan eines Zuges bietet der Assistent bewusst nicht an, weil er den Fahrplan eines fremden Zuges ueberschreiben wuerde; der erste Auftrag liest nach dem Schreiben zurueck und geht bei Abweichung in die Klaerung. Alte Konfigurationen mit `tracks.*.release` werden beim ersten Start mit Datenformat 3 bereinigt (`docs/DATENFORMAT.md`).
