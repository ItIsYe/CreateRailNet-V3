# Eine Version festhalten (Release)

`main` ändert sich mit jedem Push. Ein Computer, der heute installiert, und einer, der nächste Woche installiert, hätten verschiedene Stände. Für ein ganzes
Netz gehört deshalb ein **Tag** auf den Stand, der geprüft wurde (zum Beispiel `v1.0.0`), und alle Computer installieren mit `--ref v1.0.0`.
Der Installer warnt, wenn der Ref ein Branch ist (`docs/INSTALL.md`).

## Ablauf

1. Alles, was in die Version soll, ist gemergt; auf dem Entwicklungsrechner `git pull` auf dem Hauptzweig.
2. Die Prüfung laufen lassen (im Hauptordner des Repositorys, außerhalb des Spiels):

       lua scripts/release_check.lua --version v1.0.0

   Sie führt dieselben Prüfungen wie die CI aus (Syntax in Lua 5.4 und 5.1, Konfigurationen, Testregister, Manifest des Installers, CC-Parser-Wache, die ganze
   Testsuite in Lua 5.4 und 5.1) und fragt git: alles eingecheckt? Gibt es den Tag schon? Fehlt ein Programm (`lua5.1` liegt nicht im Pfad), sagt sie das und
   meldet einen Fehler; mit `--lua51 <Programm>` und `--lua <Programm>` gibst du den Weg an.
3. Ist **alles** grün, druckt sie die Befehle zum Taggen und den Installer-Befehl für die Computer. Sie führt sie **nicht** aus: ein Tag sagt „dieser Stand wurde geprüft und soll
   installiert werden", und das entscheidet ein Mensch. Ist etwas rot, druckt sie keine Befehle.
4. Was kein Programm prüfen kann, steht in `docs/INGAME_TESTS.md` (echte Geräte, Funkstrecke, Monitore, Create-Verhalten). Der Tag gehört erst darauf, wenn diese Liste für die
   verwendete Hardware durchgegangen ist.
5. Tag setzen und hochladen (die beiden gedruckten Befehle, zum Beispiel `git tag -a v1.0.0 -m "CreateRailNet v1.0.0" <Commit>` und `git push origin v1.0.0`).

## Auf den Computern

- Neue Computer: `wget run https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/v1.0.0/installer --ref v1.0.0`.
- Vorhandene Computer: erst ansehen, was sich ändern würde: `installer --preview --ref v1.0.0` (ändert nichts: neue / geänderte / entfernte Dateien, Platz).
  Dann ohne `--preview`.
- Per Funk (Master, `docs/OTA.md`): zuerst ein Computer, dann eine Rolle, dann alle:

       lua scripts/ota_push.lua --role signal --limit 1 --dry-run      wen würde es treffen?
       lua scripts/ota_push.lua --role signal --limit 1                einen Signal-Computer versuchen
       lua scripts/ota_push.lua --role signal                          alle Signal-Computer
       lua scripts/ota_push.lua                                        alle, die antworten

## Was die Prüfung nicht kann

Sie beweist nicht, dass das Spiel so reagiert, wie die Tests es annehmen: echte Peripherienamen, Modemreichweite, Monitorgrößen, das Verhalten von Create. Dafür gibt es
die Spieltests und, auf jedem Computer, `scripts/setup.lua --test`, `--linktest` und `--export` (`docs/INGAME_SETUP.md`).
