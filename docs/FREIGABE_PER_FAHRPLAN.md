# Freigabe der Abfahrt allein ueber die Train Station

## Ausgangslage

Der Computer steht nicht an der Train Station; die Station haengt ueber ein Kabelmodem am Netz des Computers. Alle Methoden der Station (16, `docs/MESSWERTE.md` M03) lesen oder setzen Fahrplaene; **keine** gibt eine Abfahrt frei.

Heute geschieht die Freigabe mit Redstone: jeder gesteuerte Aufenthalt im Fahrplan endet mit der Bedingung `create:powered` (Station bekommt Strom), und die Station-Rolle schaltet einen Ausgang (`dev/out.lua`, Computerseite oder Redstone Relay). Der Assistent verlangt dafuer im Schritt *Gleise* einen *Freigabeausgang* und bietet nur Computerseiten und erkannte Relais an. Steht der Computer nicht am Bahnhof, ist das nicht brauchbar.

## Entscheidung des Betreibers

Freigabe **ohne Redstone**, allein ueber die Station: die Leitstelle gibt die Abfahrt frei, indem sie den Fahrplan erst im Freigabemoment per Modem an die Station uebergibt (`setSchedule`).

## Was dafuer gemessen werden muss

`docs/MESSWERTE.md` M12 belegt nur `setSchedule` mit **unveraendertem** Fahrplan. Das neue Verfahren haengt an Annahmen ueber Create, die nicht gemessen sind. `probe/crn_probe3.lua` misst sie am echten Modpack (Anleitung: `docs/GROSSER_TEST.md` 3.88):

| Nr | Annahme | Probe | Folge, wenn falsch |
|---|---|---|---|
| H1 | `setSchedule` mit geaendertem Inhalt wird geschrieben und genauso gelesen | A | Das Verfahren entfaellt: ein Fahrplan liesse sich nur unveraendert zurueckschreiben |
| H2 | Ein Zug haelt am Ende eines nicht zyklischen Fahrplans (Haltefahrplan als Warteauftrag ohne Strom) | B | Ein anderes Mittel zum Halten waere noetig (zum Beispiel lange Wartebedingung) |
| H3 | `create:powered` mit leeren Daten wird angenommen und haelt ohne Strom (Annahme des heutigen Verfahrens, bisher nie im Spiel gesehen) | C | Auch das heutige Redstone-Verfahren waere falsch gebaut |
| H4 | Ein Fahrplan, dessen erster Eintrag der Bahnhof ist, an dem der Zug schon steht, und dessen zweiter Eintrag ein anderer Bahnhof ist, schickt den Zug nach kurzer Zeit los | D (mit `--ziel`) | Das Setzen des Fahrplans waere keine Freigabe |
| H5 | Zeit von `setSchedule` bis `train_departure` | D | Mindestaufenthalt und Zeitueberwachung der Leitstelle richten sich danach |

## Vorgesehenes Verfahren (wenn H1, H2 und H4 stimmen)

- Warteauftrag am Bahnhof: Haltefahrplan (ein Eintrag am eigenen Bahnhof, nicht zyklisch). Der Zug haelt, ohne dass Strom noetig ist.
- Auftrag: die Leitstelle uebergibt nicht mehr den ganzen Fahrplan mit `create:powered`, sondern fuehrt den Zug **abschnittsweise**: je Abschnitt ein Fahrplan aus dem Eintrag des aktuellen Bahnhofs (Aufenthaltsbedingungen wie Wartezeit und Fracht ohne `create:powered`) und einem Eintrag fuer den naechsten Bahnhof ohne weitere Bedingungen. Am Ziel haelt der Zug, weil der Fahrplan endet.
- Freigabe = das Setzen dieses Abschnittsfahrplans durch die Station-Rolle (Mindestaufenthalt, Zuordnung des Zuges und Aufenthalts, Rueckmeldung `freigabe_gesetzt` und bestaetigte Abfahrt durch `train_departure` bleiben wie heute).
- Gleise mit dieser Freigabe brauchen im Assistenten keinen Ausgang; die Pruefung "Ausgang kurz schalten" entfaellt, stattdessen zeigt der Assistent, dass der Fahrplan der Station gelesen und geschrieben werden kann.

Nicht unveraendert bleibt die Sicherheitsannahme "keine zweite Gruppe, die `create:powered` umgehen koennte": ohne Strom als letzte Bedingung haelt allein der Fahrplan des Zuges. Signale und Reservierungen der Leitstelle sind davon nicht betroffen.

## Bis dahin

Der Assistent verlangt weiter einen Freigabeausgang. Wer die Einrichtung vorab durchspielen will, waehlt eine beliebige Computerseite (sie wird nur im Betrieb gebraucht; ohne angeschlossene Leitung gibt sie nichts frei). Echte Fahrten brauchen das neue Verfahren oder ein Redstone Relay am Bahnhof, das als Ausgang erscheint, sobald es am Kabelnetz haengt.
