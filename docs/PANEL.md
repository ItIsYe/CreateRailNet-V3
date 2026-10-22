# Panel (V3, Paket P8)

Das Panel zeigt und bedient, es entscheidet nichts. Jede Aktion prueft der Master noch einmal; ein ausgeblendeter Knopf ist kein Schutz.

## Rechte
`permission` am Panel-Eintrag im Plan: `view` (nur lesen), `operate` (Fahrstrassen, Zuege, Depots, Stoerungen, vorbeugende Sperren), `admin` (zusaetzlich Wartung, Freigabe von Zuegen,
Stoerungen loeschen, Signale/Weichen setzen, Updates). Ohne Eintrag gilt `operate`, ein unbekanntes Wort gilt als `view`. Kritische Aktionen verlangen `confirm = true`: das Panel fragt dafuer
mit einem zweiten Tipp innerhalb `confirm_window_s`. Nicht erlaubte Aktionen landen im Audit als `panel_denied` und als gelber Alarm. Der Nothalt braucht keine zweite Bestaetigung.

## Monitore und Gruppen (`src/panel/monitor_registry.lua`)
Feste logische IDs, Zuordnung in `state/panel_monitors.json`. Erkennen: grosse Kennung auf dem Monitor. Ein ersetzter Monitor wird erst nach Bestaetigung des Bedieners gebunden.
Gruppen teilen nur Zug, Station und Abschnitt, keine Rechte und keine Seiten.

## Gleisbild (`src/panel/diagram.lua`)
Vorschlag aus dem Sicherheitsgraphen; der Editor veraendert nur Lage, Beschriftung, Ebene und Ausschnitt, nie Verbindungen oder Objekte. Entwurf -> Vorschau -> Veroeffentlichung mit Bestaetigung.
Rueckgabe nur auf einen Stand mit gleicher Topologie. Besetzt, reserviert, Zug, Stoerung, Signale und Gewissheit (aktuell/veraltet/keine) sind getrennte Ebenen.

## Offline (`src/panel/offline.lua`)
Ohne Wort des Masters (`offline_after_s`, Standard 10) ist das Panel OFFLINE: Entwuerfe gehen weiter, Veroeffentlichen, Befehle und Wartung nicht, alte Wuensche verfallen. Die Rueckkehr prueft
Identitaet, Versionen und Rechte und verlangt eine neue Bestaetigung. Alte Daten bleiben mit Frischemarke sichtbar und sind nie ein Nachweis.

## Stoerungszentrale (`src/panel/fault_center.lua`)
Quittieren heisst nur "gesehen". Der Eintrag bleibt sichtbar, die Sperre bleibt bestehen; nur ein Nachweis (Art und Quelle) beendet die Ursache.

## Mehrere Monitore (`src/panel/multi_display.lua`, `src/panel/views.lua`)
Ist mindestens ein Monitor gebunden (`state/panel_monitors.json`), zeichnet der Panel-Node jeden mit seiner eigenen Ansicht (13 Ansichten: Uebersicht, Gleisbild, Zuege, Zugdetail, Fahrtassistent, Stationen, Depots, Fahrplan, Fracht,
Stoerungen, Knoten, Wartung, Protokoll). Ohne Bindung zeichnet er wie frueher den einen Monitor des Plans. Ein Tipp auf die oberen drei Zeilen blaettert die Ansichten (nur die, die die Stufe erlaubt), ein Tipp auf eine Zeile einer
Liste waehlt den Eintrag. Eine Gruppe teilt die Auswahl von Zug, Station und Abschnitt, nie einen Befehl und nie die Ansicht; die gewaehlte Fahrplanlinie ist Sache des einzelnen Monitors. Faellt ein Monitor aus, werden die anderen
weiter gezeichnet (Meldung im Log mit dem Grund). Jede Ansicht endet mit einer Zeile "Daten: aktuell / veraltet / keine Daten".

Binden: `scripts/bind_monitors.lua bind <ID> [Ansicht] [Skala]` zeigt auf jedem freien Monitor eine grosse Nummer; man waehlt die Nummer des richtigen und bestaetigt. `check` meldet fehlende Monitore (nichts wird von selbst umgebunden), `replace <ID>`
bindet einen ersetzten Monitor neu, `group`/`ungroup`, `label`, `scale`, `view`, `unbind`.

## Gleisbild
Das Panel holt die Topologie vom Master (`plan_get` fuer die Rolle panel, in Teilen, waehrend es laeuft) und zeichnet sie nur, wenn sie die ist, die der Master gerade faehrt (Versionsvergleich); der Stand wird in `state/panel_topology.json` und
das bestaetigte Layout in `state/panel_layout.json` gehalten. Eine neue Topologie behaelt die Plaetze der unveraenderten Bloecke. Buchstaben: `.` frei bewiesen, `?` unklar, `R` reserviert, `O` besetzt, `T` Zug (nur wo bewiesen), `X` Stoerung, `f` veraltet.

## Fahrplaneditor (Ansicht Fahrplan, Recht admin)
Eine Linie antippen oeffnet sie als Entwurf auf diesem Panel. Knoepfe: Takt, Haltezeit, Fenster von/bis, alle Abfahrten verschieben. Aenderungen werden aufgelistet und geprueft. `Entwurf senden` schickt den Entwurf ueber den Master an den
aktiven Knoten des Flottenpaars (neue Version, laeuft noch nicht); `Veroeffentlichen` (zweiter Tipp noetig) gilt gegen die Basisversion: hat sich die Linie inzwischen geaendert, ist es ein Konflikt, und der Flottenknoten veroeffentlicht erst, wenn das
Paar gesund ist und der Partner den Entwurf dauerhaft hat. Der Entwurf liegt in `state/panel_timetable_draft.json` und ueberlebt einen Neustart; offline wird weiter bearbeitet, aber nichts gesendet. Bei einem Konflikt entscheidet eine Person:
`Neu laden` oder `Stand uebernehmen` (die Aenderungen auf die neue Version legen).

## Wartung und Austausch
Die Wartungsseite zeigt die Sperre, die Sperren der Updates und den Austausch eines Computers: `Computer ersetzen` sperrt den Knoten und widerruft den alten Schluessel, `Schluessel ausgeben` schreibt den neuen auf die Diskette im Laufwerk des Masters
(nie in eine Nachricht) und zeigt die Pruefsumme, `Pruefsumme stimmt` / `stimmt NICHT`, `Signale pruefen` (liest die Meldung des neuen Computers), `Test bestanden`. Alle Schritte brauchen admin und die zweite Bestaetigung.

## Zugdetail
Knoepfe nach Stufe: Halten, NOTHALT, Freigeben (admin, zweite Bestaetigung) und fuer Zuege eines Flottenpaars `In Depot <ID>`.

## Master-AUX
`aux_monitor = "monitor_3"` im Plan des Masters: ein eigener Monitor mit einer reduzierten Fehlersicht (Betriebszustand, Bloecke, Knoten, Sperren, Journal, Platz, rote ungesehene Meldungen), direkt aus dem Zustand gelesen und unabhaengig von den Seiten.
Eine Quelle, die ausfaellt, zeigt `?`; der Rest bleibt.

## Stand
Fertig und offline getestet: alles oben. Zu pruefen im Spiel: Spieltests `docs/INGAME_TESTS.md` 0cn bis 0cs und 0db bis 0dh.
