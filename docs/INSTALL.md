# Installation mit dem Installer

Ein Befehl auf einem frischen CC:Tweaked-Computer lädt die Dateien der gewählten Rolle von GitHub, prüft sie und startet danach den
Einrichtungs-Assistenten (`scripts/setup.lua`). Dasselbe Programm aktualisiert und repariert später.

## Schnellstart

Voraussetzung: HTTP ist in der ComputerCraft-Konfiguration erlaubt (`computercraft-server.toml`, `raw.githubusercontent.com` darf nicht
gesperrt sein).

```
wget run https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/main/installer
```

oder in zwei Schritten (der Installer bleibt dann auf dem Computer und kann später wieder benutzt werden):

```
wget https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/main/installer installer
installer
```

Solange eine Änderung noch nicht in `main` ist, den Zweig angeben: in der URL **und** als Option

```
wget https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/<zweig>/installer installer
installer --ref <zweig>
```

Der Installer fragt die Rolle (Menü), lädt, prüft, schreibt, und übergibt an den Einrichtungs-Assistenten: Netzplan, Name, Hardware, eine Zusammenfassung zum
Bestätigen, dann `startup.lua` und Neustart. Was der Assistent fragt und schreibt: `docs/INGAME_SETUP.md`.

## Optionen

| Option | Wirkung |
|---|---|
| `--ref <zweig-oder-tag>` | Quelle (Standard `main`). Ein Lauf benutzt genau einen Ref für das Manifest und alle Dateien |
| `--role <rolle>` | `master signal sensor switch station depot train panel`; ohne Angabe: die installierte Rolle (wird bestätigt) oder das Menü |
| `--yes` | keine Fragen; behält die installierte Rolle (ein neuer Computer braucht dann `--role`) |
| `--resume` | eine abgebrochene Installation zu Ende führen (`startup.lua` ruft das selbst auf) |

## Was passiert

1. Rolle bestimmen (installierte `startup.lua` lesen, sonst Menü oder `--role`).
2. `install/manifest.lua` des Refs laden: Liste der Dateien dieser Rolle mit Größe und Adler-32.
3. Mit der Platte vergleichen: nur **fehlende oder abweichende** Dateien werden geladen. Ein Lauf ohne Änderungen lädt nur das Manifest.
4. **Platzprüfung, bevor irgendetwas angefasst wird.** Reicht der Speicher nicht, bleibt der Computer unverändert und die Meldung nennt, wie viel fehlt.
   Danach legt der Installer eine Kopie von sich als `installer` ab (auch bei `wget run`), damit `startup.lua` eine abgebrochene Installation ohne URL fortsetzen kann.
5. Journal `crn_install_journal.lua` anlegen. Solange es existiert, startet `startup.lua` die Rolle nicht, sondern ruft `installer --resume` auf.
6. Jede Datei: laden, Größe, Adler-32 und Lua-Syntax prüfen (bei Abweichung neuer Versuch mit neuer URL: der CDN von GitHub liefert nach einem
   Push einige Minuten lang manchmal die alte Fassung), in `<datei>.tmp` schreiben, zurücklesen, über die alte Datei schieben.
   Zu jedem Zeitpunkt ist die alte oder die neue Fassung vollständig da.
7. Dateien der vorigen Installation, die der neue Stand nicht mehr braucht, entfernen (Liste in `crn_install.lua`).
8. `crn_version.txt` (`<ref>-<id>`) und `crn_install.lua` schreiben, Journal löschen = fertig.
9. Neuer Computer: Assistent (`scripts/setup.lua --role <rolle>`, die Rollenfrage entfällt). Vorhandene Installation: `startup.lua` bekommt, falls nötig, die
   Wiederherstellung (alte Fassung als `startup.lua.prev`), danach Neustart.

Stürzt der Computer ab oder bricht das Netz weg, bleibt das Journal liegen. Beim nächsten Start setzt `startup.lua` die Installation fort
(`installer --resume`); bereits passende Dateien werden übersprungen. Ein Computer, der noch keine `startup.lua` hat, startet in die Shell:
`installer --resume --role <rolle>` bzw. der Schnellstart-Befehl macht weiter.

## Was installiert wird

Die Dateien einer Rolle sind der Abschluss der `require`-Abhängigkeiten ihres Einstiegs (aus dem Quelltext gelesen) plus die Konfigurationsvorlagen.
`configs/install/runtime_manifest.json` bleibt die Instanz dafür, was den Rechner überhaupt erreichen darf: nichts aus `tests/`, `docs/`, `src/sim/`,
`src/tools/`, `.github/` und keine Entwicklungsskripte.

| Rolle | Dateien | Größe |
|---|---|---|
| master | ca. 75 + Vorlagen | ca. 430 KB |
| signal, sensor, switch | ca. 28 | ca. 125 KB |
| train, station, depot, panel | ca. 27-28 | ca. 130 KB |

Die genaue Liste steht in `install/manifest.lua` (erzeugt, nicht von Hand ändern).

**Eigene Dateien bleiben.** Konfigurationsvorlagen (`configs/templates/*.json`, dort liegt die Welt-Konfiguration) und `scripts/start_*.lua`
sind „Seed"-Dateien: sie werden nur angelegt, wenn sie fehlen, und nie ersetzt oder gelöscht. Ebenso unberührt: `configs/network.json` und alles, was der
Assistent oder du selbst angelegt hast, `startup.lua` (außer dem Einfügen der Wiederherstellung), `state/`, `traces/`.

## Konfiguration verteilen

Der Installer legt die Vorlagen an (`configs/templates/`), damit der Assistent sie als Beispiele anbieten kann. Der Netzplan deiner Welt liegt als
`configs/network.json` auf dem Master: der Assistent kopiert dort ein Beispiel hin oder legt einen leeren Plan an, du baust ihn aus und prüfst ihn mit
`scripts/setup.lua --check`. Die anderen Computer brauchen nur einen **Kurzplan** (ihren eigenen Eintrag und den Master), den der Assistent selbst anlegt;
den Eintrag für den Master zeigt er am Ende. Das Verteilen größerer Pläne per OTA (`scripts/ota_push.lua`) gilt weiter für Dateien unter `configs/templates/`.

## Aktualisieren, reparieren, Rolle wechseln

- **Aktualisieren / reparieren**: `installer` (oder `installer --yes`) noch einmal ausführen. Fehlende, abgeschnittene oder veränderte Dateien werden
  ersetzt, der Rest bleibt. Auch der **Master** wird so aktualisiert.
- **Rolle wechseln**: `installer --role <neue-rolle>`: die Dateien der alten Rolle, die die neue nicht braucht, werden entfernt; der Assistent richtet neu ein.
- **Nodes im Betrieb**: bequemer per OTA vom Master (`docs/OTA.md`). Nodes, die vor dem Installer eingerichtet wurden, bekommen die neuen Dateien entweder
  mit dem Installer (braucht HTTP) oder mit `ota_push.lua --legacy`.

## Wenn etwas schiefgeht

| Meldung | Bedeutung / Abhilfe |
|---|---|
| `HTTP ist nicht verfuegbar` | HTTP in `computercraft-server.toml` aktivieren, Domain `raw.githubusercontent.com` freigeben |
| `install/http.lua konnte nicht geladen werden (Ref ...)` | Zweig oder Tag gibt es nicht (Tippfehler?) oder GitHub ist nicht erreichbar |
| `Ungueltiger Ref` | Zweignamen dürfen nur Buchstaben, Ziffern und `. _ - /` enthalten |
| `Manifest ungueltig` | der Ref enthält kein passendes `install/manifest.lua` (zu alter Stand) |
| `Der Speicher dieses Computers reicht nicht` | nichts wurde verändert; `computer_space_limit` erhöhen oder einen größeren Computer nehmen |
| `Installation abgebrochen bei <datei>` | Download oder Prüfung ist mehrfach gescheitert; `installer --resume` setzt fort |
| `Installation unvollstaendig.` beim Start | das Journal einer abgebrochenen Installation liegt noch da; `startup.lua` führt `installer --resume` aus |
| `Die Rolle dieses Computers ist unbekannt` | mit `--yes` ohne installierte Rolle: `--role <rolle>` angeben |

## Für Entwickler

- Nach jeder Änderung an einer installierten Datei: `lua scripts/manifest_sync.lua --write` und mit committen. Die CI (`--check`) und
  `tests/test_installer_manifest.lua` schlagen sonst fehl: der Installer würde Dateien als beschädigt ablehnen.
- Die Dateilisten entstehen in `src/tools/manifest_builder.lua` (Rollen und deren Einstiege stehen in `ROLES`). Eine neue Rolle braucht dort einen Eintrag, einen Eintrag in
  `install/plan.lua` (Menü) und in `src/shared/startup_template.lua`.
- Der Installer lädt seine eigenen Module (`install/*.lua`) und drei Dateien aus `src/shared/` bei jedem Lauf frisch vom selben Ref. Es gibt keine zweite
  Kopie der Logik, die nachgeführt werden müsste.
- `tests/test_installer_flow.lua` führt die echte Datei `installer` auf einem simulierten Computer aus (Speicher im RAM, simuliertes GitHub), darunter ein
  Absturz an **jeder** Dateioperation mit anschließendem `--resume`.
- Sicherheit: Größe und Adler-32 erkennen beschädigte oder abgeschnittene Downloads, keine Fälschung. Vertraut wird dem Repository (Ref) auf GitHub.
