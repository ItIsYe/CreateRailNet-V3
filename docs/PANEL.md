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

## Stand
Fertig und offline getestet: Rechte (mit Master-Pruefung), Registry, Gleisbildmodell, Offline-Zustand, Stoerungszentrale, Seitentabelle, Panel-Node mit Rechten/Offline/Bestaetigung.
Noch nicht angeschlossen: Zeichnen auf mehreren Monitoren, Bindewerkzeug, Fahrplaneditor. Spieltests `docs/INGAME_TESTS.md` 0cn bis 0cs.
